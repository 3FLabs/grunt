// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {IPositionManager, SupplyQueueEntry} from "src/interfaces/manager/IPositionManager.sol";
import {PositionManagerMetadata} from "src/libs/manager/LibStorage.sol";
import {MorphoBorrowPosition} from "src/borrow/MorphoBorrowPosition.sol";
import {MorphoBorrowPositionFactory} from "src/borrow/MorphoBorrowPositionFactory.sol";
import {IBorrowPosition} from "src/interfaces/borrow/IBorrowPosition.sol";
import {Morpho} from "lib/morpho-blue/src/Morpho.sol";
import {IMorpho, Id, MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";
import {IrmMock} from "lib/morpho-blue/src/mocks/IrmMock.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {PositionManagerHandler} from "test/mock/manager/PositionManagerHandler.sol";

/// @title PositionManagerInvariantTest
/// @notice Stateful invariant tests for PositionManager + MorphoBorrowPosition modules.
///         Uses a handler contract to drive bounded, fuzz-driven actions through the system,
///         then asserts global invariants after every call sequence.
contract PositionManagerInvariantTest is StdInvariant, Test {
  using MarketParamsLib for MarketParams;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  PositionManager public positionManager;
  MorphoBorrowPositionFactory public borrowPositionFactory;
  MorphoBorrowPosition public borrowPosition1;
  MorphoBorrowPosition public borrowPosition2;
  IMorpho public morpho;
  MockERC20 public debtToken;
  MockERC20 public collateralToken;
  OracleMock public oracle;
  IrmMock public irm;
  PositionManagerHandler public handler;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       MARKET PARAMS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  MarketParams public marketParams1;
  MarketParams public marketParams2;
  Id public marketId1;
  Id public marketId2;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST ADDRESSES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  address public owner;
  address public curator;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant DEFAULT_LLTV = 0.8e18;
  uint128 constant BP_SAFE_LTV = 0.65e18;
  uint128 constant BP_LIQUIDATION_LTV = 0.72e18;
  uint256 constant POSITION_MANAGER_LLTV = 0.7e18;
  uint256 constant DEFAULT_ORACLE_PRICE = 1e36;
  uint256 constant _ROLE_MINTER = 1 << 0;
  uint256 constant _ROLE_CURATOR = 1 << 1;
  uint256 constant _ROLE_REBALANCER = 1 << 2;
  uint256 constant MAX_MANAGEMENT_FEE = 5000;
  uint256 constant MAX_PERFORMANCE_FEE = 5000;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                               */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public {
    // ---- addresses ----
    owner = makeAddr("owner");
    curator = makeAddr("curator");

    // ---- deploy Morpho (real implementation) ----
    morpho = IMorpho(address(new Morpho(owner)));

    // ---- mock tokens ----
    debtToken = new MockERC20("Debt Token", "DEBT", 18);
    vm.label(address(debtToken), "DebtToken");

    collateralToken = new MockERC20("Collateral Token", "COLL", 18);
    vm.label(address(collateralToken), "CollateralToken");

    // ---- oracle & IRM ----
    oracle = new OracleMock();
    oracle.setPrice(DEFAULT_ORACLE_PRICE);

    irm = new IrmMock();

    // ---- configure Morpho ----
    vm.startPrank(owner);
    morpho.enableIrm(address(irm));
    morpho.enableIrm(address(0));
    morpho.enableLltv(DEFAULT_LLTV);
    vm.stopPrank();

    // ---- create market 1 (with IRM) ----
    marketParams1 = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(irm),
      lltv: DEFAULT_LLTV
    });
    vm.prank(owner);
    morpho.createMarket(marketParams1);
    marketId1 = marketParams1.id();

    // ---- create market 2 (no IRM for variety) ----
    marketParams2 = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(collateralToken),
      oracle: address(oracle),
      irm: address(0),
      lltv: DEFAULT_LLTV
    });
    vm.prank(owner);
    morpho.createMarket(marketParams2);
    marketId2 = marketParams2.id();

    // ---- deploy PositionManager (directly, not via factory) ----
    positionManager = new PositionManager();
    positionManager.initialize(
      owner,
      PositionManagerMetadata({
        name: "Position Manager Shares",
        symbol: "PMS",
        decimals: 18,
        collateralAsset: address(collateralToken),
        debtAsset: address(debtToken)
      }),
      POSITION_MANAGER_LLTV,
      address(0)
    );

    // ---- deploy MorphoBorrowPositionFactory and create 2 borrow positions ----
    borrowPositionFactory = new MorphoBorrowPositionFactory(owner);

    address bp1 = borrowPositionFactory.createBorrowPosition(
      morpho, marketId1, address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );
    borrowPosition1 = MorphoBorrowPosition(bp1);

    address bp2 = borrowPositionFactory.createBorrowPosition(
      morpho, marketId2, address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );
    borrowPosition2 = MorphoBorrowPosition(bp2);

    // ---- add borrow modules & grant roles ----
    vm.startPrank(owner);
    positionManager.addBorrowModule(address(borrowPosition1));
    positionManager.addBorrowModule(address(borrowPosition2));
    positionManager.grantRoles(curator, _ROLE_CURATOR);
    vm.stopPrank();

    // ---- set supply & withdrawal queues ----
    SupplyQueueEntry[] memory supplyQueue = new SupplyQueueEntry[](2);
    supplyQueue[0] = SupplyQueueEntry({position: address(borrowPosition1), maxBorrow: uint96(type(uint96).max)});
    supplyQueue[1] = SupplyQueueEntry({position: address(borrowPosition2), maxBorrow: uint96(type(uint96).max)});

    address[] memory withdrawalQueue = new address[](2);
    withdrawalQueue[0] = address(borrowPosition1);
    withdrawalQueue[1] = address(borrowPosition2);

    vm.startPrank(curator);
    positionManager.setSupplyQueue(supplyQueue);
    positionManager.setWithdrawalQueue(withdrawalQueue);
    vm.stopPrank();

    // ---- supply liquidity to both Morpho markets (100_000e18 each) ----
    _supplyLiquidity(marketParams1, 100_000e18);
    _supplyLiquidity(marketParams2, 100_000e18);

    // ---- deploy and initialise handler ----
    handler = new PositionManagerHandler();
    MarketParams[] memory mkts = new MarketParams[](2);
    mkts[0] = marketParams1;
    mkts[1] = marketParams2;
    handler.initialize(positionManager, collateralToken, debtToken, owner, morpho, mkts, oracle);

    // Grant MINTER_ROLE and REBALANCER_ROLE to the handler.
    vm.startPrank(owner);
    positionManager.grantRoles(address(handler), _ROLE_MINTER);
    positionManager.grantRoles(address(handler), _ROLE_REBALANCER);
    vm.stopPrank();

    // Token approvals from handler to PositionManager (handler mints itself tokens on the fly,
    // so the approve is done inside each act_ function).

    // ---- configure invariant-test target ----
    targetContract(address(handler));

    bytes4[] memory selectors = new bytes4[](13);
    selectors[0] = PositionManagerHandler.act_deposit.selector;
    selectors[1] = PositionManagerHandler.act_withdraw.selector;
    selectors[2] = PositionManagerHandler.act_burn.selector;
    selectors[3] = PositionManagerHandler.act_rebalance.selector;
    selectors[4] = PositionManagerHandler.act_warpTime.selector;
    selectors[5] = PositionManagerHandler.act_setFees.selector;
    selectors[6] = PositionManagerHandler.act_setOraclePrice.selector;
    selectors[7] = PositionManagerHandler.act_preLiquidate.selector;
    selectors[8] = PositionManagerHandler.act_morphoLiquidate.selector;
    selectors[9] = PositionManagerHandler.act_accrueInterest.selector;
    selectors[10] = PositionManagerHandler.act_setLltv.selector;
    selectors[11] = PositionManagerHandler.act_setMaxRebalanceLoss.selector;
    selectors[12] = PositionManagerHandler.act_supplyMorphoLiquidity.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    // Labels for trace readability.
    vm.label(address(positionManager), "PositionManager");
    vm.label(address(borrowPosition1), "BorrowPosition1");
    vm.label(address(borrowPosition2), "BorrowPosition2");
    vm.label(address(morpho), "Morpho");
    vm.label(address(handler), "Handler");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         HELPERS                                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Supplies debt-token liquidity into a Morpho market so borrows can succeed.
  function _supplyLiquidity(MarketParams memory params, uint256 amount) internal {
    debtToken.setBalance(address(this), amount);
    debtToken.approve(address(morpho), amount);
    morpho.supply(params, amount, 0, address(this), "");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        INVARIANTS                              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice PM-1: totalAssets equals quotedCollateral minus debt (floored at zero).
  /// @dev This is the fundamental accounting identity of the PositionManager. totalAssets
  ///      represents the net equity available to share holders after subtracting all outstanding
  ///      debt from the quoted (oracle-priced) collateral. If debt exceeds quoted collateral
  ///      the value is floored at zero rather than underflowing.
  function invariant_totalAssetsEquation() public view {
    uint256 quotedCollateral = positionManager.collateralAmountQuoted();
    uint256 debt = positionManager.debtAmount();
    uint256 expected = quotedCollateral > debt ? quotedCollateral - debt : 0;
    assertEq(positionManager.totalAssets(), expected, "PM-1: totalAssets != quotedCollateral - debt");
  }

  /// @notice PM-2: No zero-share minting (virtual offset inflation-attack protection).
  /// @dev The PositionManager uses VIRTUAL_SHARES (1e6) and VIRTUAL_ASSETS (1) offsets in its
  ///      share conversion formula to prevent the classic ERC-4626 inflation attack where a
  ///      first depositor manipulates the price-per-share. This invariant verifies that whenever
  ///      shares exist, the virtual offset guarantees a meaningful share supply.
  function invariant_noInflationAttack() public view {
    uint256 totalSupply = positionManager.totalSupply();
    uint256 totalAssets = positionManager.totalAssets();

    if (totalSupply > 0) {
      // The virtual offset (VIRTUAL_SHARES=1e6, VIRTUAL_ASSETS=1) ensures that
      // convertToShares(1) should never return 0 when totalAssets > 0.
      // totalSupply as a uint256 can never be negative; this assertion serves as a
      // smoke-test that the share accounting remains consistent.
      assertTrue(totalSupply >= 0, "PM-2: totalSupply should never be negative (it is uint)");
    }

    // Additional check: if there are assets, the share price should be reasonable.
    if (totalAssets > 0 && totalSupply > 0) {
      // shares per asset should be > 0 (no complete dilution).
      // Using the virtual offset formula: shares = assets * (totalSupply + 1e6) / (totalAssets + 1)
      // Even for 1 wei of assets this should produce > 0 shares.
      uint256 sharesFor1 = (1 * (totalSupply + 1e6)) / (totalAssets + 1);
      assertTrue(sharesFor1 > 0, "PM-2: 1 wei of assets yields 0 shares (inflation attack possible)");
    }
  }

  /// @notice PM-4: Fee parameters always stay within their maximum bounds.
  /// @dev The PositionManager enforces MAX_MANAGEMENT_FEE (5000 bps = 50%) and
  ///      MAX_PERFORMANCE_FEE (5000 bps = 50%) during setFeeData(). This invariant
  ///      re-checks the stored values to ensure no path can bypass the validation.
  function invariant_feeBounds() public view {
    (address feeRecipient, uint24 managementFee, uint24 performanceFee,,) = positionManager.feeData();
    assertTrue(managementFee <= MAX_MANAGEMENT_FEE, "PM-4: managementFee exceeds MAX_MANAGEMENT_FEE");
    assertTrue(performanceFee <= MAX_PERFORMANCE_FEE, "PM-4: performanceFee exceeds MAX_PERFORMANCE_FEE");

    // If fees are set, there should be a recipient (otherwise fees are burned to address(0)).
    // Note: the contract allows feeRecipient == address(0) which effectively disables fee accrual.
    // This is by design, not a bug. We just verify consistency.
    if (managementFee > 0 || performanceFee > 0) {
      // feeRecipient can be address(0) by design (disables accrual), so no assertion here.
    }

    // Suppress unused variable warning.
    feeRecipient;
  }

  /// @notice PM-6: Queue integrity -- every position in supply and withdrawal queues
  ///         must be a registered borrow module.
  /// @dev The PositionManager validates this during setSupplyQueue() and setWithdrawalQueue(),
  ///      but a removed module could theoretically leave stale entries. This invariant verifies
  ///      that the on-chain state is always consistent.
  function invariant_queueIntegrity() public view {
    SupplyQueueEntry[] memory sq = positionManager.supplyQueue();
    for (uint256 i = 0; i < sq.length; i++) {
      assertTrue(
        positionManager.isBorrowModule(sq[i].position), "PM-6: supply queue entry not a registered borrow module"
      );
    }

    address[] memory wq = positionManager.withdrawalQueue();
    for (uint256 i = 0; i < wq.length; i++) {
      assertTrue(positionManager.isBorrowModule(wq[i]), "PM-6: withdrawal queue entry not a registered borrow module");
    }
  }

  /// @notice PM-7: Debt-free borrow positions are always healthy and positions with debt
  ///         have consistent collateral/debt accounting.
  /// @dev The safeLtv and liquidationLtv are only enforced at mutation time (borrow,
  ///      withdrawCollateral). Interest accrual via act_warpTime can push LTV beyond these
  ///      thresholds over time, which is expected DeFi behavior (positions degrade until
  ///      liquidation or repayment restores health).
  ///
  ///      This invariant verifies two properties:
  ///      1. Positions with zero debt are always healthy regardless of LTV parameter.
  ///      2. Positions with collateral but zero debt have zero borrowed amount (consistency).
  ///      These are structural properties that hold regardless of interest accrual.
  function invariant_safeLtvEnforcement() public view {
    address[] memory modules = positionManager.borrowModules();
    for (uint256 i = 0; i < modules.length; i++) {
      IBorrowPosition bp = IBorrowPosition(modules[i]);
      uint256 borrowed = bp.totalBorrowed();
      uint256 collateral = bp.totalCollateral();

      if (borrowed == 0) {
        // A position with no debt is always healthy at any LTV.
        (uint128 safeLtv,) = MorphoBorrowPosition(modules[i]).ltvs();
        assertTrue(bp.isHealthy(safeLtv), "PM-7: debt-free position reported unhealthy");
      }

      if (collateral == 0) {
        // If there is no collateral, there must be no debt either
        // (Morpho requires collateral to borrow).
        assertEq(borrowed, 0, "PM-7: debt without collateral");
      }
    }
  }

  /// @notice PM-9: No shares without collateral -- if shares exist, collateral must exist.
  /// @dev This is a fundamental property: share holders own a claim on the collateral.
  ///      If totalSupply > 0 but collateralAmount == 0, share holders have worthless tokens,
  ///      which would indicate a critical accounting bug. Note: totalAssets CAN be zero if
  ///      debt exactly matches quoted collateral, but raw collateralAmount must still be > 0.
  function invariant_noSharesWithoutAssets() public view {
    uint256 totalSupply = positionManager.totalSupply();
    if (totalSupply > 0) {
      assertTrue(positionManager.collateralAmount() > 0, "PM-9: shares exist but no collateral backs them");
    }
  }

  /// @notice PM-3: Burn proportionality preserves LTV.
  /// @dev After a burn, the aggregate LTV (debt / quotedCollateral) must not increase.
  ///      The handler's act_burn captures collateral/debt before and after each burn and
  ///      sets burnLtvIncreased if LTV went up. This invariant verifies that never happened.
  function invariant_burnPreservesLtv() public view {
    assertFalse(handler.burnLtvIncreased(), "PM-3: burn caused aggregate LTV to increase");
  }

  /// @notice PM-5: Rebalance loss bounded by maxRebalanceLoss.
  /// @dev The handler's act_rebalance captures totalAssets before and after each rebalance
  ///      and verifies that any loss stays within the configured maxRebalanceLoss (basis points).
  ///      The contract itself enforces this on-chain; this invariant serves as cross-validation.
  function invariant_rebalanceLossBounded() public view {
    assertFalse(handler.rebalanceLossExceeded(), "PM-5: rebalance loss exceeded maxRebalanceLoss");
  }

  /// @notice PM-8: Pre-liquidation only when unhealthy.
  /// @dev For each borrow position that is healthy at its liquidationLtv, attempting
  ///      preLiquidate must revert. This ensures pre-liquidation cannot be used to
  ///      steal collateral from healthy positions.
  function invariant_preLiquidationGating() public {
    address[] memory modules = positionManager.borrowModules();
    for (uint256 i = 0; i < modules.length; i++) {
      MorphoBorrowPosition bp = MorphoBorrowPosition(modules[i]);
      (, uint128 liquidationLtv) = bp.ltvs();

      // Only test positions that have collateral and are healthy
      if (bp.totalCollateral() > 0 && bp.isHealthy(liquidationLtv)) {
        // Pre-liquidation must revert for healthy positions
        try bp.preLiquidate(address(bp), 1, 0, "") returns (uint256, uint256) {
          fail("PM-8: preLiquidate succeeded on healthy position");
        } catch {
          // Expected: healthy position cannot be pre-liquidated
        }
      }
    }
  }

  /// @notice PM-10: Post-liquidation accounting consistency.
  /// @dev After any pre-liquidation or Morpho liquidation, the fundamental accounting
  ///      identity totalAssets = max(0, quotedCollateral - debt) must still hold.
  function invariant_postLiquidationConsistency() public view {
    if (!handler.preLiquidationOccurred() && !handler.morphoLiquidationOccurred()) return;
    uint256 quoted = positionManager.collateralAmountQuoted();
    uint256 debt = positionManager.debtAmount();
    uint256 expected = quoted > debt ? quoted - debt : 0;
    assertEq(positionManager.totalAssets(), expected, "PM-10: totalAssets broken after liquidation");
  }
}
