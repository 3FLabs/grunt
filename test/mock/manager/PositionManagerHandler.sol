// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {IPositionManager, SupplyQueueEntry, WithdrawalStrategy} from "src/interfaces/manager/IPositionManager.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {IMorpho, Id, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {WrappedAsset} from "src/funds/WrappedAsset.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title PositionManagerHandler
/// @notice Foundry invariant-test handler that drives PositionManager + MorphoBorrowPosition
///         through a series of bounded, fuzz-driven actions. Each action is prefixed with `act_`
///         and uses early-return (never revert) when preconditions are not met, so the fuzzer
///         can freely explore the state space without wasting runs on reverts.
contract PositionManagerHandler is Test {
  using MarketParamsLib for MarketParams;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       EXTERNAL REFS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  PositionManager public positionManager;
  WrappedAsset public collateralToken;
  MockERC20 public underlyingToken;
  MockERC20 public debtToken;
  address public owner;
  IMorpho public morpho;
  MarketParams[] public marketParamsArray;
  OracleMock public oracle;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      GHOST VARIABLES                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Running total of collateral deposited (gross, not net of withdrawals).
  uint256 public totalDeposited;

  /// @notice Running total of shares minted across all successful deposit calls.
  uint256 public totalSharesMinted;

  /// @notice PM-3: Set to true if burn causes aggregate LTV to increase.
  bool public burnLtvIncreased;

  /// @notice PM-5: Set to true if rebalance loss exceeds maxRebalanceLoss.
  bool public rebalanceLossExceeded;

  /// @notice PM-10: Set to true if a pre-liquidation occurred during the run.
  bool public preLiquidationOccurred;

  /// @notice PM-10: Set to true if a Morpho native liquidation occurred during the run.
  bool public morphoLiquidationOccurred;

  /// @notice PM-9: Set to true if a liquidation zeroed collateral and collateral has not been restored.
  bool public fullLiquidationOccurred;

  /// @notice PM-11a: Set to true if an unauthorized WrappedAsset transfer succeeded.
  bool public unauthorizedTransferSucceeded;

  /// @notice PM-11b: Set to true if an unauthorized Morpho collateral supply succeeded.
  bool public unauthorizedCollateralSupplySucceeded;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  bool public initialized;

  /// @notice One-time setup. Called by the invariant test's setUp().
  /// @param positionManager_ The PositionManager under test.
  /// @param collateralToken_ The WrappedAsset used as collateral.
  /// @param underlyingToken_ The MockERC20 underlying the WrappedAsset.
  /// @param debtToken_ The MockERC20 used as debt.
  /// @param owner_ The owner address of the PositionManager (for admin calls).
  function initialize(
    PositionManager positionManager_,
    WrappedAsset collateralToken_,
    MockERC20 underlyingToken_,
    MockERC20 debtToken_,
    address owner_,
    IMorpho morpho_,
    MarketParams[] memory marketParams_,
    OracleMock oracle_
  ) external {
    require(!initialized, "already initialized");
    initialized = true;

    positionManager = positionManager_;
    collateralToken = collateralToken_;
    underlyingToken = underlyingToken_;
    debtToken = debtToken_;
    owner = owner_;
    morpho = morpho_;
    oracle = oracle_;
    for (uint256 i = 0; i < marketParams_.length; i++) {
      marketParamsArray.push(marketParams_[i]);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 LIQUIDATION TRACKING                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  modifier refreshFullLiquidation() {
    _refreshFullLiquidationFlag();
    _;
    _refreshFullLiquidationFlag();
  }

  function _refreshFullLiquidationFlag() internal {
    if (!initialized) return;
    if (fullLiquidationOccurred && positionManager.collateralAmount() > 0) {
      fullLiquidationOccurred = false;
    }
  }

  function _recordFullLiquidationIfZero() internal {
    if (!initialized) return;
    if (positionManager.collateralAmount() == 0) {
      fullLiquidationOccurred = true;
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      HANDLER ACTIONS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deposits collateral (and optionally borrows debt) into the PositionManager.
  /// @dev Bounds collateral to [1e18, 50_000e18]. If debt > 0, bounds it proportionally
  ///      to stay well within the safe LTV (64% of collateral at 1:1 oracle price).
  ///      Early-returns if the supply queue is empty.
  /// @param collateral Raw fuzz input for collateral amount.
  /// @param debt Raw fuzz input for debt amount.
  function act_deposit(uint256 collateral, uint256 debt) external refreshFullLiquidation {
    // Early-return when supply queue is empty (deposit would revert).
    SupplyQueueEntry[] memory sq = positionManager.supplyQueue();
    if (sq.length == 0) return;

    collateral = _bound(collateral, 1e18, 50_000e18);

    // Cap debt at 64% of collateral to stay within safe LTV (65%) with margin.
    uint256 maxDebt = (collateral * 64) / 100;
    debt = _bound(debt, 0, maxDebt);

    // Wrap underlying into WrappedAsset: mint underlying → approve → wrap.
    underlyingToken.mint(address(this), collateral);
    underlyingToken.approve(address(collateralToken), collateral);
    collateralToken.mint(address(this), collateral);
    collateralToken.approve(address(positionManager), collateral);

    // The handler has MINTER_ROLE, so it can call deposit directly.
    try positionManager.deposit(collateral, debt) returns (int256 shares) {
      totalDeposited += collateral;
      if (shares > 0) {
        totalSharesMinted += uint256(shares);
      }
    } catch {
      // Operation failed (e.g. insufficient liquidity, LTV constraints) -- silently skip.
    }
  }

  /// @notice Withdraws collateral (and optionally repays debt) from the PositionManager.
  /// @dev Bounds within available amounts. Mints debt tokens if repaying.
  ///      Early-returns if there is nothing to withdraw.
  /// @param collateral Raw fuzz input for collateral amount.
  /// @param debt Raw fuzz input for debt amount.
  function act_withdraw(uint256 collateral, uint256 debt) external refreshFullLiquidation {
    uint256 totalCollateral = positionManager.collateralAmount();
    uint256 totalDebt = positionManager.debtAmount();

    // Nothing to withdraw or repay.
    if (totalCollateral == 0 && totalDebt == 0) return;

    // Bound debt repayment to actual outstanding debt.
    debt = _bound(debt, 0, totalDebt);

    // Bound collateral withdrawal. Use a conservative fraction so we stay within LLTV.
    // After repaying `debt`, the remaining debt is (totalDebt - debt).
    // Max collateral withdrawable is roughly: totalCollateral - remainingDebt / LLTV.
    // We use 50% of totalCollateral as a conservative upper bound to avoid edge cases.
    uint256 maxCollateral = totalCollateral / 2;
    if (maxCollateral == 0 && debt > 0) {
      // Can only repay debt, no collateral to withdraw.
      collateral = 0;
    } else if (maxCollateral == 0) {
      return; // Nothing useful to do.
    } else {
      collateral = _bound(collateral, 0, maxCollateral);
    }

    if (collateral == 0 && debt == 0) return;

    // Mint debt tokens for repayment.
    if (debt > 0) {
      debtToken.mint(address(this), debt);
      debtToken.approve(address(positionManager), debt);
    }

    try positionManager.withdraw(collateral, debt, WithdrawalStrategy.SEQUENTIAL) {
    // Success -- no ghost tracking needed for withdrawals.
    }
      catch {
      // Silently skip on failure.
    }
  }

  /// @notice Burns shares proportionally, receiving collateral and repaying debt.
  /// @dev Bounds shares to [1, handler's balance]. Calculates proportional debt needed,
  ///      mints debt tokens, and calls burn. Early-returns if handler has no shares.
  /// @param shares Raw fuzz input for share amount.
  function act_burn(uint256 shares) external refreshFullLiquidation {
    uint256 balance = positionManager.balanceOf(address(this));
    if (balance == 0) return;

    shares = _bound(shares, 1, balance);

    // Force-accrue interest on all markets so that debtAmount() reflects
    // current debt including interest. Without this, burn() would accrue
    // interest internally and the "after" snapshot would include interest
    // that the "before" snapshot did not, causing a false LTV increase.
    for (uint256 i = 0; i < marketParamsArray.length; i++) {
      morpho.accrueInterest(marketParamsArray[i]);
    }

    // Pre-calculate how much debt the handler will need to repay.
    // debt = totalDebt * shares / totalSupply (rounded up by the contract).
    uint256 totalDebt = positionManager.debtAmount();
    uint256 totalSupply = positionManager.totalSupply();

    // Round up to ensure we have enough tokens.
    uint256 debtNeeded = totalSupply > 0 ? (totalDebt * shares + totalSupply - 1) / totalSupply : 0;

    if (debtNeeded > 0) {
      debtToken.mint(address(this), debtNeeded);
      debtToken.approve(address(positionManager), debtNeeded);
    }

    // PM-3: Capture collateral/debt before burn for LTV comparison.
    // Interest has already been accrued above, so this is the true current state.
    uint256 collBefore = positionManager.collateralAmountQuoted();
    uint256 debtBefore = positionManager.debtAmount();

    try positionManager.burn(shares, WithdrawalStrategy.PROPORTIONAL) {
      // PM-3: Verify aggregate LTV did not increase after burn.
      // LTV = debt / quotedCollateral. Cross-multiply to avoid division:
      // debtAfter * collBefore > debtBefore * collAfter → LTV increased.
      uint256 collAfter = positionManager.collateralAmountQuoted();
      uint256 debtAfter = positionManager.debtAmount();
      if (collBefore > 0 && collAfter > 0) {
        // Allow 1-wei rounding per division in the proportional split: the
        // collateral division error contributes `debtBefore` and the debt
        // division error contributes `collBefore` in the cross-multiplication.
        if (debtAfter * collBefore > debtBefore * collAfter + collBefore + debtBefore) {
          burnLtvIncreased = true;
        }
      }
    } catch {
      // Silently skip on failure.
    }
  }

  /// @notice Moves collateral between borrow positions via rebalance.
  /// @dev Builds a withdraw-from-one / supply-to-another operation.
  ///      Early-returns if only one (or zero) borrow modules exist.
  /// @param fromIdx Raw fuzz input for source position index.
  /// @param toIdx Raw fuzz input for destination position index.
  /// @param amount Raw fuzz input for the amount to move.
  function act_rebalance(uint256 fromIdx, uint256 toIdx, uint256 amount) external refreshFullLiquidation {
    address[] memory modules = positionManager.borrowModules();
    if (modules.length < 2) return;

    fromIdx = _bound(fromIdx, 0, modules.length - 1);
    toIdx = _bound(toIdx, 0, modules.length - 1);

    // Must be different positions.
    if (fromIdx == toIdx) {
      toIdx = (fromIdx + 1) % modules.length;
    }

    address fromPos = modules[fromIdx];
    address toPos = modules[toIdx];

    // Determine the max amount of available collateral to move.
    (uint256 ltv,) = positionManager.config();
    uint256 available = IBorrowPosition(fromPos).availableCollateral(ltv);
    if (available == 0) return;

    amount = _bound(amount, 1, available);

    // Build rebalance operations: WITHDRAW from source, SUPPLY to destination.
    RebalancingOperation[] memory ops = new RebalancingOperation[](2);
    ops[0] = RebalancingOperation({position: fromPos, operationType: RebalancingOperationType.WITHDRAW, amount: amount});
    ops[1] = RebalancingOperation({position: toPos, operationType: RebalancingOperationType.SUPPLY, amount: amount});

    RebalancingData memory data = RebalancingData({collateral: 0, debt: 0, operations: ops});

    // The handler needs REBALANCER_ROLE. The collateral withdrawn from one position
    // ends up in the PositionManager, which then supplies it to the other position.
    // We need to approve the collateral token for the position manager in case it
    // pulls tokens from us. But rebalance pulls data.collateral from caller, which is 0,
    // so no approval needed. The excess collateral goes to receiver (this handler).

    // PM-5: Capture totalAssets before rebalance.
    uint256 totalAssetsBefore = positionManager.totalAssets();

    try positionManager.rebalance(data, address(this)) {
      // PM-5: Verify loss is within maxRebalanceLoss bounds.
      uint256 totalAssetsAfter = positionManager.totalAssets();
      if (totalAssetsAfter < totalAssetsBefore && totalAssetsBefore > 0) {
        uint256 loss = totalAssetsBefore - totalAssetsAfter;
        (uint16 maxLoss,,) = positionManager.rebalanceConfig();
        // loss * BPS > maxLoss * totalAssetsBefore → loss exceeded
        if (loss * 10_000 > uint256(maxLoss) * totalAssetsBefore) {
          rebalanceLossExceeded = true;
        }
      }
    } catch {
      // Silently skip on failure.
    }
  }

  /// @notice Warps block.timestamp forward to allow fee accrual over time.
  /// @dev Bounds seconds to [1, 365 days]. This is crucial for management fee testing.
  /// @param seconds_ Raw fuzz input for seconds to warp.
  function act_warpTime(uint256 seconds_) external refreshFullLiquidation {
    seconds_ = _bound(seconds_, 1, 365 days);
    vm.warp(block.timestamp + seconds_);
  }

  /// @notice Sets fee parameters on the PositionManager.
  /// @dev Bounds management fee to [0, 200] (MAX_MANAGEMENT_FEE = 2%) and performance fee to [0, 5000].
  ///      Sets a fee recipient if one is not already configured.
  /// @param mgmt Raw fuzz input for management fee (basis points).
  /// @param perf Raw fuzz input for performance fee (basis points).
  function act_setFees(uint256 mgmt, uint256 perf) external refreshFullLiquidation {
    mgmt = _bound(mgmt, 0, 200);
    perf = _bound(perf, 0, 5000);

    (address currentRecipient,,,,) = positionManager.feeData();
    address recipient = currentRecipient;
    if (recipient == address(0)) {
      recipient = address(0xFEE);
    }

    vm.prank(owner);
    try positionManager.setFeeData(recipient, uint24(mgmt), uint24(perf)) {
    // Success.
    }
      catch {
      // Silently skip on failure.
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                 DEPENDENCY-GRAPH ACTIONS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Changes the oracle price, affecting collateral valuation, LTV, and position health.
  /// @dev Bounds price to [0.1e36, 10e36] (10x drop to 10x increase from 1e36 default).
  ///      OracleMock.setPrice is permissionless.
  /// @param priceSeed Raw fuzz input for the new price.
  function act_setOraclePrice(uint256 priceSeed) external refreshFullLiquidation {
    uint256 newPrice = _bound(priceSeed, 0.1e36, 10e36);
    oracle.setPrice(newPrice);
  }

  /// @notice Pre-liquidates an unhealthy borrow position via the protocol's custom mechanism.
  /// @dev Finds a borrow module that is unhealthy at its liquidationLtv, mints debtToken
  ///      for repayment, and calls preLiquidate. Sets preLiquidationOccurred on success.
  /// @param posIdx Seed for selecting among borrow modules.
  /// @param amountSeed Raw fuzz input for the amount of collateral to seize.
  function act_preLiquidate(uint256 posIdx, uint256 amountSeed) external refreshFullLiquidation {
    address[] memory modules = positionManager.borrowModules();
    if (modules.length == 0) return;

    for (uint256 i = 0; i < modules.length; i++) {
      uint256 idx = (posIdx + i) % modules.length;
      MorphoBorrowPosition bp = MorphoBorrowPosition(modules[idx]);
      (, uint128 liquidationLtv) = bp.ltvs();

      if (bp.totalCollateral() == 0 || bp.isHealthy(liquidationLtv)) continue;

      uint256 collateral = bp.totalCollateral();
      uint256 seizedAssets = _bound(amountSeed, 1, collateral);

      // Over-provision debtToken for repayment
      uint256 maxDebtNeeded = bp.totalBorrowed() + 1e18;
      debtToken.mint(address(this), maxDebtNeeded);
      debtToken.approve(address(bp), maxDebtNeeded);
      debtToken.approve(address(morpho), maxDebtNeeded);

      bp.preLiquidate(address(bp), seizedAssets, 0, "");
      preLiquidationOccurred = true;
      _recordFullLiquidationIfZero();
      return;
    }
  }

  /// @notice Liquidates a borrow position via Morpho's native liquidation mechanism.
  /// @dev Finds a borrow module unhealthy at the market LLTV, matches it to the correct
  ///      MarketParams, and calls morpho.liquidate. Sets morphoLiquidationOccurred on success.
  /// @param posIdx Seed for selecting among borrow modules.
  /// @param amountSeed Raw fuzz input for the amount of collateral to seize.
  function act_morphoLiquidate(uint256 posIdx, uint256 amountSeed) external refreshFullLiquidation {
    _doMorphoLiquidate(posIdx, amountSeed);
  }

  /// @notice Explicitly accrues interest on all Morpho markets.
  /// @dev This is an independent action separate from the interest accrual in act_burn.
  ///      Combined with act_warpTime, this makes debt grow and pushes LTV higher.
  function act_accrueInterest() external refreshFullLiquidation {
    for (uint256 i = 0; i < marketParamsArray.length; i++) {
      morpho.accrueInterest(marketParamsArray[i]);
    }
  }

  /// @notice Changes the PositionManager's LTV parameter.
  /// @dev Bounds to [0.1e18, 0.95e18]. Affects available collateral calculations.
  /// @param ltvSeed Raw fuzz input for the new LTV.
  function act_setLtv(uint256 ltvSeed) external refreshFullLiquidation {
    uint256 newLtv = _bound(ltvSeed, 0.1e18, 0.95e18);
    vm.prank(owner);
    try positionManager.setLtv(newLtv) {} catch {}
  }

  /// @notice Changes the rebalance config (maxRebalanceLoss only, cooldown stays at 0).
  /// @dev Bounds to [0, 500] (0% to 5% in basis points).
  /// @param lossSeed Raw fuzz input for the new maxRebalanceLoss.
  function act_setRebalanceConfig(uint256 lossSeed) external refreshFullLiquidation {
    uint16 newLoss = uint16(_bound(lossSeed, 0, 500));
    vm.prank(owner);
    try positionManager.setRebalanceConfig(newLoss, 0) {} catch {}
  }

  /// @notice Supplies additional liquidity to a Morpho market (simulates external actor).
  /// @dev Changes available borrow liquidity which can affect deposit/borrow outcomes.
  /// @param amountSeed Raw fuzz input for the supply amount.
  /// @param marketIdx Seed for selecting which market to supply to.
  function act_supplyMorphoLiquidity(uint256 amountSeed, uint256 marketIdx) external refreshFullLiquidation {
    if (marketParamsArray.length == 0) return;
    uint256 idx = marketIdx % marketParamsArray.length;
    uint256 amount = _bound(amountSeed, 1e18, 100_000e18);

    debtToken.mint(address(this), amount);
    debtToken.approve(address(morpho), amount);
    try morpho.supply(marketParamsArray[idx], amount, 0, address(this), "") {} catch {}
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  WRAPPED ASSET ACTIONS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Mints WrappedAsset to the handler (underlying → wrap).
  /// @param amountSeed Raw fuzz input for the amount to wrap.
  function act_wrapped_asset_mint(uint256 amountSeed) external refreshFullLiquidation {
    uint256 amount = _bound(amountSeed, 1e18, 50_000e18);
    underlyingToken.mint(address(this), amount);
    underlyingToken.approve(address(collateralToken), amount);
    collateralToken.mint(address(this), amount);
  }

  /// @notice Burns (unwraps) WrappedAsset held by the handler back to underlying.
  /// @param amountSeed Raw fuzz input for the amount to unwrap.
  function act_wrapped_asset_burn(uint256 amountSeed) external refreshFullLiquidation {
    uint256 balance = collateralToken.balanceOf(address(this));
    if (balance == 0) return;
    uint256 amount = _bound(amountSeed, 1, balance);
    collateralToken.burn(address(this), address(this), amount);
  }

  /// @notice Transfers WrappedAsset from handler (has SENDER_ROLE) to another address.
  /// @dev Should succeed because the handler has SENDER_ROLE.
  /// @param toSeed Seed for selecting a destination (owner or positionManager).
  /// @param amountSeed Raw fuzz input for the amount to transfer.
  function act_wrapped_asset_transfer(uint256 toSeed, uint256 amountSeed) external refreshFullLiquidation {
    uint256 balance = collateralToken.balanceOf(address(this));
    if (balance == 0) return;
    uint256 amount = _bound(amountSeed, 1, balance);
    address to = toSeed % 2 == 0 ? address(positionManager) : owner;
    collateralToken.transfer(to, amount);
  }

  /// @notice Approves an address for WrappedAsset spending.
  /// @param toSeed Seed for selecting a spender.
  /// @param amountSeed Raw fuzz input for approval amount.
  function act_wrapped_asset_approve(uint256 toSeed, uint256 amountSeed) external refreshFullLiquidation {
    address spender = toSeed % 2 == 0 ? address(positionManager) : address(morpho);
    uint256 amount = _bound(amountSeed, 0, type(uint128).max);
    collateralToken.approve(spender, amount);
  }

  /// @notice Attempts a WrappedAsset transfer from an unauthorized external actor.
  /// @dev Pranks as an address without SENDER_ROLE. The transfer should fail.
  ///      If it succeeds, sets unauthorizedTransferSucceeded.
  /// @param amountSeed Raw fuzz input for the amount to transfer.
  function act_wrapped_asset_unauthorized_transfer(uint256 amountSeed) external refreshFullLiquidation {
    address externalActor = makeAddr("externalActor");
    uint256 balance = collateralToken.balanceOf(externalActor);
    if (balance == 0) {
      // Give the actor some tokens via handler (has SENDER_ROLE): mint underlying → wrap → transfer.
      uint256 seedAmount = _bound(amountSeed, 1e18, 10_000e18);
      underlyingToken.mint(address(this), seedAmount);
      underlyingToken.approve(address(collateralToken), seedAmount);
      collateralToken.mint(address(this), seedAmount);
      collateralToken.transfer(externalActor, seedAmount);
      balance = seedAmount;
    }
    uint256 amount = _bound(amountSeed, 1, balance);

    // External actor (no SENDER_ROLE) tries to transfer to another external address (no RECEIVER_ROLE).
    address receiver = makeAddr("externalReceiver");
    vm.prank(externalActor);
    try collateralToken.transfer(receiver, amount) {
      unauthorizedTransferSucceeded = true;
    } catch {
      // Expected: should fail without SENDER_ROLE
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  MORPHO DIRECT OPERATIONS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Withdraws debt-token liquidity from a Morpho market (handler is supplier).
  /// @dev Reduces available borrow liquidity, which can affect future deposit/borrow outcomes.
  /// @param amountSeed Raw fuzz input for the withdrawal amount.
  /// @param marketIdx Seed for selecting which market to withdraw from.
  function act_morpho_withdraw(uint256 amountSeed, uint256 marketIdx) external refreshFullLiquidation {
    if (marketParamsArray.length == 0) return;
    uint256 idx = marketIdx % marketParamsArray.length;
    Id id = marketParamsArray[idx].id();

    // Check handler's supply position in this market.
    uint256 supplyShares = morpho.position(id, address(this)).supplyShares;
    if (supplyShares == 0) return;

    uint256 amount = _bound(amountSeed, 1, supplyShares);
    try morpho.withdraw(marketParamsArray[idx], 0, amount, address(this), address(this)) {} catch {}
  }

  /// @notice Repays debt on behalf of a borrow position via Morpho.
  /// @dev Reduces the BP's debt, improving its health.
  /// @param posIdx Seed for selecting a borrow module.
  /// @param amountSeed Raw fuzz input for the repayment amount.
  function act_morpho_repay(uint256 posIdx, uint256 amountSeed) external refreshFullLiquidation {
    address[] memory modules = positionManager.borrowModules();
    if (modules.length == 0) return;

    uint256 idx = posIdx % modules.length;
    MorphoBorrowPosition bp = MorphoBorrowPosition(modules[idx]);
    uint256 borrowed = bp.totalBorrowed();
    if (borrowed == 0) return;

    uint256 amount = _bound(amountSeed, 1, borrowed);
    debtToken.mint(address(this), amount);
    debtToken.approve(address(morpho), amount);

    // Match borrow position to its MarketParams
    Id bpMarketId = bp.marketId();
    for (uint256 j = 0; j < marketParamsArray.length; j++) {
      if (Id.unwrap(marketParamsArray[j].id()) == Id.unwrap(bpMarketId)) {
        try morpho.repay(marketParamsArray[j], amount, 0, address(bp), "") {} catch {}
        return;
      }
    }
  }

  /// @notice Attempts to supply WrappedAsset as collateral to Morpho from an unauthorized actor.
  /// @dev An external actor without SENDER_ROLE tries to supplyCollateral. Morpho calls
  ///      safeTransferFrom(actor, morpho, amount) on the WrappedAsset which should fail
  ///      because the actor lacks SENDER_ROLE and Morpho lacks RECEIVER_ROLE.
  /// @param amountSeed Raw fuzz input for the amount.
  /// @param marketIdx Seed for selecting which market.
  function act_morpho_supplyCollateral(uint256 amountSeed, uint256 marketIdx) external refreshFullLiquidation {
    if (marketParamsArray.length == 0) return;
    uint256 idx = marketIdx % marketParamsArray.length;
    uint256 amount = _bound(amountSeed, 1e18, 10_000e18);

    address externalActor = makeAddr("morphoExternalActor");

    // Give the actor WrappedAsset via handler (which has SENDER_ROLE).
    underlyingToken.mint(address(this), amount);
    underlyingToken.approve(address(collateralToken), amount);
    collateralToken.mint(address(this), amount);
    collateralToken.transfer(externalActor, amount);

    // External actor tries to supply collateral to Morpho.
    vm.startPrank(externalActor);
    collateralToken.approve(address(morpho), amount);
    try morpho.supplyCollateral(marketParamsArray[idx], amount, externalActor, "") {
      unauthorizedCollateralSupplySucceeded = true;
    } catch {
      // Expected: transfer from actor to Morpho should fail
    }
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                      INTERNAL HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Internal implementation of Morpho native liquidation to manage stack depth.
  function _doMorphoLiquidate(uint256 posIdx, uint256 amountSeed) internal {
    address[] memory modules = positionManager.borrowModules();
    if (modules.length == 0) return;

    for (uint256 i = 0; i < modules.length; i++) {
      uint256 idx = (posIdx + i) % modules.length;
      MorphoBorrowPosition bp = MorphoBorrowPosition(modules[idx]);

      if (bp.totalCollateral() == 0 || bp.totalBorrowed() == 0) continue;

      // Match borrow position to its MarketParams
      Id bpMarketId = bp.marketId();
      MarketParams memory mp;
      bool found;
      for (uint256 j = 0; j < marketParamsArray.length; j++) {
        if (Id.unwrap(marketParamsArray[j].id()) == Id.unwrap(bpMarketId)) {
          mp = marketParamsArray[j];
          found = true;
          break;
        }
      }
      if (!found) continue;

      uint256 collateral = bp.totalCollateral();
      uint256 seizedAssets = _bound(amountSeed, 1, collateral);

      uint256 maxDebtNeeded = bp.totalBorrowed() + 1e18;
      debtToken.mint(address(this), maxDebtNeeded);
      debtToken.approve(address(morpho), maxDebtNeeded);

      morpho.liquidate(mp, address(bp), seizedAssets, 0, "");
      morphoLiquidationOccurred = true;
      _recordFullLiquidationIfZero();
      return;
    }
  }
}
