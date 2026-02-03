// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {IPositionManager, SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {IMorpho, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @title PositionManagerHandler
/// @notice Foundry invariant-test handler that drives PositionManager + MorphoBorrowPosition
///         through a series of bounded, fuzz-driven actions. Each action is prefixed with `act_`
///         and uses early-return (never revert) when preconditions are not met, so the fuzzer
///         can freely explore the state space without wasting runs on reverts.
contract PositionManagerHandler is Test {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       EXTERNAL REFS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  PositionManager public positionManager;
  MockERC20 public collateralToken;
  MockERC20 public debtToken;
  address public owner;
  IMorpho public morpho;
  MarketParams[] public marketParamsArray;

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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  bool public initialized;

  /// @notice One-time setup. Called by the invariant test's setUp().
  /// @param positionManager_ The PositionManager under test.
  /// @param collateralToken_ The MockERC20 used as collateral.
  /// @param debtToken_ The MockERC20 used as debt.
  /// @param owner_ The owner address of the PositionManager (for admin calls).
  function initialize(
    PositionManager positionManager_,
    MockERC20 collateralToken_,
    MockERC20 debtToken_,
    address owner_,
    IMorpho morpho_,
    MarketParams[] memory marketParams_
  ) external {
    require(!initialized, "already initialized");
    initialized = true;

    positionManager = positionManager_;
    collateralToken = collateralToken_;
    debtToken = debtToken_;
    owner = owner_;
    morpho = morpho_;
    for (uint256 i = 0; i < marketParams_.length; i++) {
      marketParamsArray.push(marketParams_[i]);
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
  function act_deposit(uint256 collateral, uint256 debt) external {
    // Early-return when supply queue is empty (deposit would revert).
    SupplyQueueEntry[] memory sq = positionManager.supplyQueue();
    if (sq.length == 0) return;

    collateral = _bound(collateral, 1e18, 50_000e18);

    // Cap debt at 64% of collateral to stay within safe LTV (65%) with margin.
    uint256 maxDebt = (collateral * 64) / 100;
    debt = _bound(debt, 0, maxDebt);

    // Mint tokens to this handler.
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
  function act_withdraw(uint256 collateral, uint256 debt) external {
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

    try positionManager.withdraw(collateral, debt) {
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
  function act_burn(uint256 shares) external {
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

    try positionManager.burn(shares) {
      // PM-3: Verify aggregate LTV did not increase after burn.
      // LTV = debt / quotedCollateral. Cross-multiply to avoid division:
      // debtAfter * collBefore > debtBefore * collAfter → LTV increased.
      uint256 collAfter = positionManager.collateralAmountQuoted();
      uint256 debtAfter = positionManager.debtAmount();
      if (collBefore > 0 && collAfter > 0) {
        if (debtAfter * collBefore > debtBefore * collAfter) {
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
  function act_rebalance(uint256 fromIdx, uint256 toIdx, uint256 amount) external {
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
    (uint256 lltv,,) = positionManager.config();
    uint256 available = IBorrowPosition(fromPos).availableCollateral(lltv);
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
        (, uint16 maxLoss,) = positionManager.config();
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
  function act_warpTime(uint256 seconds_) external {
    seconds_ = _bound(seconds_, 1, 365 days);
    vm.warp(block.timestamp + seconds_);
  }

  /// @notice Sets fee parameters on the PositionManager.
  /// @dev Bounds management and performance fees to [0, 5000] (MAX_MANAGEMENT_FEE / MAX_PERFORMANCE_FEE).
  ///      Sets a fee recipient if one is not already configured.
  /// @param mgmt Raw fuzz input for management fee (basis points).
  /// @param perf Raw fuzz input for performance fee (basis points).
  function act_setFees(uint256 mgmt, uint256 perf) external {
    mgmt = _bound(mgmt, 0, 5000);
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
}
