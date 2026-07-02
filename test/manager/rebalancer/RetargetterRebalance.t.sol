// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {RetargetterBaseTest} from "./RetargetterBase.t.sol";
import {IRetargetter} from "src/interfaces/manager/rebalancer/IRetargetter.sol";
import {LibRetargetterErrors} from "src/libs/manager/rebalancer/LibRetargetterErrors.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";
import {Offer} from "src/interfaces/request/IOfferReceiver.sol";
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {WithdrawalStrategy} from "src/interfaces/manager/base/IPositionManagerAdmin.sol";
import {MarketParams} from "lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {OracleMock} from "lib/morpho-blue/src/mocks/OracleMock.sol";

/// @title RetargetterRebalanceTest
/// @notice Tests for the Retargetter rebalance step and guardrail G2 (spec Section 6.5):
///         the direction rule truth table (aggregate and per position), bad-debt reverts,
///         full-balance sentinel resolution, the emptied-book zero-LTV snapshot convention,
///         approval scrubbing, event fidelity, principal-cap self-correction, and the
///         position manager guardrails that keep applying underneath.
/// @dev Rebalancing inside a flash-loan window is covered by the SYNC test suite; every test
///      here drives the step through an active ASYNC operation. With no time warps the Morpho
///      share price stays exactly 1e6 shares per asset, so all LTV values below are exact.
contract RetargetterRebalanceTest is RetargetterBaseTest {
  using MarketParamsLib for MarketParams;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HELPERS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Builds rebalancing data with zero amounts and no operation legs.
  function _emptyData() internal pure returns (RebalancingData memory data) {
    data.operations = new RebalancingOperation[](0);
  }

  /// @dev Builds rebalancing data with two operation legs against arbitrary positions.
  function _dataOn2(
    uint256 collateral,
    uint256 debt,
    address firstPosition,
    RebalancingOperationType firstType,
    uint256 firstAmount,
    address secondPosition,
    RebalancingOperationType secondType,
    uint256 secondAmount
  ) internal pure returns (RebalancingData memory data) {
    data.collateral = collateral;
    data.debt = debt;
    data.operations = new RebalancingOperation[](2);
    data.operations[0] = RebalancingOperation({position: firstPosition, operationType: firstType, amount: firstAmount});
    data.operations[1] =
      RebalancingOperation({position: secondPosition, operationType: secondType, amount: secondAmount});
  }

  /// @dev Raises the position manager's rebalance loss tolerance (owner action). Naked BORROW
  ///      and WITHDRAW legs sweep value out to the Retargetter, which the position manager
  ///      accounts as a rebalance loss, so the fixture's one-basis-point default blocks them.
  function _setMaxRebalanceLoss(uint16 maxLossBps) internal {
    vm.prank(owner);
    positionManager.setRebalanceConfig(maxLossBps, 0);
  }

  /// @dev Deploys a third borrow module on its own oracle, funds it through the rebalancer
  ///      path (a fresh leg landing at or below target passes G2), then zeroes its oracle so
  ///      the module reads debt against zero quoted collateral (the max-sentinel module LTV)
  ///      while the aggregate keeps borrowPosition1's quoted collateral.
  function _setupBadDebtModule() internal returns (address module) {
    OracleMock badOracle = new OracleMock();
    badOracle.setPrice(DEFAULT_ORACLE_PRICE);
    MarketParams memory params = MarketParams({
      loanToken: address(debtToken),
      collateralToken: address(collateralToken),
      oracle: address(badOracle),
      irm: address(0),
      lltv: DEFAULT_LLTV
    });
    morpho.createMarket(params);
    _supplyLiquidity(params, 10_000e18);
    module = borrowPositionFactory.createBorrowPosition(
      params.id(), address(positionManager), BP_SAFE_LTV, BP_LIQUIDATION_LTV
    );
    vm.prank(owner);
    positionManager.addBorrowModule(module);

    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);

    _mintCollateral(address(retargetter), 1_000e18);
    vm.prank(rebalancer);
    retargetter.rebalance(
      _dataOn2(
        1_000e18, 0, module, RebalancingOperationType.SUPPLY, 1_000e18, module, RebalancingOperationType.BORROW, 500e18
      )
    );

    badOracle.setPrice(0);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         LIFECYCLE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_revertsWhenIdle() public {
    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.NoActiveOperation.selector);
    retargetter.rebalance(_emptyData());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   DIRECTION RULE (G2)                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev (a) Below target staying below: LTV 0.50 to 0.54 against a 0.70 target passes.
  function test_rebalance_belowTargetStayingBelow_passes() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _setMaxRebalanceLoss(1000);

    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(0, 0, RebalancingOperationType.BORROW, 400e18));

    assertEq(_currentLtv(), 0.54e18, "ltv moved up but stayed below target");
    assertEq(debtToken.balanceOf(address(retargetter)), 400e18, "borrowed debt swept back to the retargetter");
  }

  /// @dev (b) Below target ending exactly at target: supply 6000 and borrow 6200 lands the
  ///      book at 11200/16000, exactly the 0.70 target, and passes.
  function test_rebalance_belowTargetLandingExactlyAtTarget_passes() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _setMaxRebalanceLoss(1000);
    _mintCollateral(address(retargetter), 6_000e18);

    vm.prank(rebalancer);
    retargetter.rebalance(
      _rebalancingData2(
        6_000e18, 0, RebalancingOperationType.SUPPLY, 6_000e18, RebalancingOperationType.BORROW, 6_200e18
      )
    );

    assertEq(_currentLtv(), POSITION_MANAGER_LTV, "landed exactly at the target ltv");
  }

  /// @dev (c) Below target ending above target: borrowing 100 more than case (b) lands at
  ///      11300/16000 = 0.70625, above the 0.70 target, and reverts.
  function test_rebalance_belowTargetEndingAboveTarget_reverts() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _setMaxRebalanceLoss(1000);
    _mintCollateral(address(retargetter), 6_000e18);

    vm.prank(rebalancer);
    vm.expectRevert(
      abi.encodeWithSelector(LibRetargetterErrors.AboveTargetLtv.selector, 0.70625e18, 0.5e18, POSITION_MANAGER_LTV)
    );
    retargetter.rebalance(
      _rebalancingData2(
        6_000e18, 0, RebalancingOperationType.SUPPLY, 6_000e18, RebalancingOperationType.BORROW, 6_300e18
      )
    );
  }

  /// @dev (d) Above target improving but still above: with the target lowered to 0.30, a
  ///      repayment moving the book from 0.50 to 0.49 strictly improves and passes.
  function test_rebalance_aboveTargetImproving_passes() public {
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);
    _startAsync(1_000e18, 100);
    _mintDebt(address(retargetter), 100e18);

    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(0, 100e18, RebalancingOperationType.REPAY, 100e18));

    assertEq(_currentLtv(), 0.49e18, "improved while still above the lowered target");
  }

  /// @dev (e) Above target worsening: borrowing while at 0.50 against a 0.30 target reverts.
  function test_rebalance_aboveTargetWorsening_reverts() public {
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);
    _startAsync(1_000e18, 100);
    _setMaxRebalanceLoss(1000);

    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.AboveTargetLtv.selector, 0.51e18, 0.5e18, 0.3e18));
    retargetter.rebalance(_rebalancingData(0, 0, RebalancingOperationType.BORROW, 100e18));
  }

  /// @dev (f) Above target unchanged: a rebalance with no legs leaves the LTV equal to its
  ///      snapshot; above target without strict improvement reverts.
  function test_rebalance_aboveTargetUnchanged_reverts() public {
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);
    _startAsync(1_000e18, 100);

    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.AboveTargetLtv.selector, 0.5e18, 0.5e18, 0.3e18));
    retargetter.rebalance(_emptyData());
  }

  /// @dev (g) Per position: worsening one module above target reverts even while the
  ///      aggregate stays far below target.
  function test_rebalance_perPositionWorsenedAboveTarget_reverts() public {
    _seedPosition(10_000e18, 690e18);
    _startAsync(1_000e18, 100);

    // Owner-driven shaping (direction checks skipped): concentrate the debt on
    // borrowPosition1 with a thin collateral slice and park the remaining collateral idle
    // on borrowPosition2. borrowPosition1 ends at 690/1000 = 0.69, just below target.
    vm.prank(owner);
    retargetter.rebalance(
      _dataOn2(
        0,
        0,
        address(borrowPosition1),
        RebalancingOperationType.WITHDRAW,
        9_000e18,
        address(borrowPosition2),
        RebalancingOperationType.SUPPLY,
        9_000e18
      )
    );
    _setMaxRebalanceLoss(1000);

    // Borrowing 20 pushes borrowPosition1 to 0.71 (above the 0.70 target and worse than its
    // 0.69 snapshot) while the aggregate lands at 710/10000 = 0.071, far below target
    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.PositionAboveTarget.selector, address(borrowPosition1)));
    retargetter.rebalance(_rebalancingData(0, 0, RebalancingOperationType.BORROW, 20e18));
  }

  /// @dev (h) Fresh above-target leg: an idle module compares against a before snapshot of
  ///      zero, so creating a new position above target reverts even though the aggregate
  ///      stays below target (a below-target book cannot skew into a new above-target leg).
  function test_rebalance_freshLegAboveTarget_reverts() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _mintCollateral(address(retargetter), 100e18);

    // The new borrowPosition2 leg lands at 71/100 = 0.71, above the 0.70 target but below
    // the 0.72 module safe LTV; the aggregate lands at 5071/10100, well below target
    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.PositionAboveTarget.selector, address(borrowPosition2)));
    retargetter.rebalance(
      _dataOn2(
        100e18,
        0,
        address(borrowPosition2),
        RebalancingOperationType.SUPPLY,
        100e18,
        address(borrowPosition2),
        RebalancingOperationType.BORROW,
        71e18
      )
    );
  }

  /// @dev (i) Owner bypass: the exact worsening call rejected in case (e) passes when the
  ///      owner sends it directly (position manager guardrails still apply underneath).
  function test_rebalance_ownerBypassesDirectionChecks() public {
    _seedPosition(10_000e18, 5_000e18);
    _setTargetLtv(0.3e18);
    _startAsync(1_000e18, 100);
    _setMaxRebalanceLoss(1000);

    vm.prank(owner);
    retargetter.rebalance(_rebalancingData(0, 0, RebalancingOperationType.BORROW, 100e18));

    assertEq(_currentLtv(), 0.51e18, "owner may worsen an above-target book");
    assertEq(debtToken.balanceOf(address(retargetter)), 100e18, "borrowed debt swept back to the retargetter");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          BAD DEBT                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev A module holding debt against zero quoted collateral reverts BadDebtPosition for
  ///      the rebalancer, even when the aggregate passes the global gate.
  function test_rebalance_badDebtModule_reverts() public {
    address badModule = _setupBadDebtModule();

    // Aggregate reads 5500/10000 = 0.55 (below target, global gate passes); the bad module
    // reads the max-sentinel LTV both before and after and still reverts
    vm.prank(rebalancer);
    vm.expectRevert(abi.encodeWithSelector(LibRetargetterErrors.BadDebtPosition.selector, badModule));
    retargetter.rebalance(_emptyData());
  }

  /// @dev The owner bypass skips the per-module bad-debt gate.
  function test_rebalance_ownerBypassesBadDebtCheck() public {
    _setupBadDebtModule();

    vm.prank(owner);
    retargetter.rebalance(_emptyData());
  }

  /// @dev With the shared oracle at zero the whole book is bad debt: the aggregate itself
  ///      reads the max-sentinel LTV, so the global gate fires first (spec 6.5 evaluates the
  ///      global check before the per-module loop) and the revert is AboveTargetLtv rather
  ///      than BadDebtPosition. The owner bypass skips both gates.
  function test_rebalance_wholeBookBadDebt_revertsAboveTargetLtv() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    oracle.setPrice(0);

    vm.prank(rebalancer);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibRetargetterErrors.AboveTargetLtv.selector, type(uint256).max, type(uint256).max, POSITION_MANAGER_LTV
      )
    );
    retargetter.rebalance(_emptyData());

    vm.prank(owner);
    retargetter.rebalance(_emptyData());
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                    SENTINEL RESOLUTION                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev data.collateral and a SUPPLY leg at the sentinel both resolve to the Retargetter's
  ///      full collateral balance (the smoke-test pattern).
  function test_rebalance_collateralAndSupplySentinelsResolveToFullBalance() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _mintCollateral(address(retargetter), 500e18);

    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(MAX_SENTINEL, 0, RebalancingOperationType.SUPPLY, MAX_SENTINEL));

    assertEq(positionManager.collateralAmount(), 10_500e18, "collateral grew by the full balance");
    assertEq(collateralToken.balanceOf(address(retargetter)), 0, "retargetter collateral fully supplied");
  }

  /// @dev data.debt and a REPAY leg at the sentinel both resolve to the Retargetter's full
  ///      debt balance.
  function test_rebalance_debtAndRepaySentinelsResolveToFullBalance() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _mintDebt(address(retargetter), 500e18);

    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(0, MAX_SENTINEL, RebalancingOperationType.REPAY, MAX_SENTINEL));

    assertEq(positionManager.debtAmount(), 4_500e18, "debt shrank by the full balance");
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "retargetter debt fully repaid");
  }

  /// @dev The sentinel is rejected on BORROW legs (outputs, not inputs).
  function test_rebalance_sentinelOnBorrowLeg_reverts() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.InvalidSentinel.selector);
    retargetter.rebalance(_rebalancingData(0, 0, RebalancingOperationType.BORROW, MAX_SENTINEL));
  }

  /// @dev The sentinel is rejected on WITHDRAW legs (outputs, not inputs).
  function test_rebalance_sentinelOnWithdrawLeg_reverts() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);

    vm.prank(rebalancer);
    vm.expectRevert(LibRetargetterErrors.InvalidSentinel.selector);
    retargetter.rebalance(_rebalancingData(0, 0, RebalancingOperationType.WITHDRAW, MAX_SENTINEL));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        FULL UNWIND                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Repaying the entire debt lands the book at LTV zero, which the convention reads as
  ///      at-or-below target: no panic, no revert.
  function test_rebalance_fullDebtRepaymentLandsAtZeroLtv() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _mintDebt(address(retargetter), 5_000e18);

    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(0, MAX_SENTINEL, RebalancingOperationType.REPAY, MAX_SENTINEL));

    assertEq(positionManager.debtAmount(), 0, "debt fully repaid");
    assertEq(_currentLtv(), 0, "zero-debt book reads ltv zero");
  }

  /// @dev NOTE(agent): a one-call full unwind (REPAY all + WITHDRAW all) sweeps the whole
  ///      book out to the Retargetter, which the position manager accounts as a 100%
  ///      rebalance loss; maxRebalanceLoss is capped at 10% (MAX_REBALANCE_LOSS = 1000 bps),
  ///      so the position manager reverts for every caller, including the owner, before any
  ///      Retargetter snapshot math runs. This documents the guardrail underneath rather
  ///      than a Retargetter behavior; the zero-LTV snapshot convention itself is covered by
  ///      the repayment test above and the emptied-book test below.
  function test_rebalance_fullUnwind_blockedByPositionManagerLossGuard() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _setMaxRebalanceLoss(1000);
    _mintDebt(address(retargetter), 5_000e18);

    vm.prank(owner);
    vm.expectRevert(LibManagerErrors.RebalanceLossExceedsMax.selector);
    retargetter.rebalance(
      _rebalancingData2(
        0, MAX_SENTINEL, RebalancingOperationType.REPAY, MAX_SENTINEL, RebalancingOperationType.WITHDRAW, 10_000e18
      )
    );
  }

  /// @dev A rebalance on an emptied position manager snapshots 0/0 as LTV zero (the step-3
  ///      convention) and passes without panicking.
  function test_rebalance_onEmptiedPositionManager_snapshotsZeroAndPasses() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);

    // Empty the position manager through the LP surface (the rebalance surface cannot: see
    // the loss-guard test above); the minter holds the seeded debt tokens from the deposit
    vm.prank(minter);
    positionManager.withdraw(10_000e18, 5_000e18, WithdrawalStrategy.SEQUENTIAL);
    assertEq(positionManager.collateralAmount(), 0, "collateral emptied");
    assertEq(positionManager.debtAmount(), 0, "debt emptied");

    _mintCollateral(address(retargetter), 100e18);
    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(100e18, 0, RebalancingOperationType.SUPPLY, 100e18));

    assertEq(positionManager.collateralAmount(), 100e18, "collateral supplied on the emptied book");
    assertEq(_currentLtv(), 0, "ltv snapshots and stays at zero");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   APPROVALS AND EVENTS                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_rebalance_scrubsApprovals() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _mintCollateral(address(retargetter), 100e18);
    _mintDebt(address(retargetter), 50e18);

    vm.prank(rebalancer);
    retargetter.rebalance(
      _rebalancingData2(100e18, 50e18, RebalancingOperationType.SUPPLY, 100e18, RebalancingOperationType.REPAY, 50e18)
    );

    assertEq(collateralToken.allowance(address(retargetter), address(positionManager)), 0, "collateral scrubbed");
    assertEq(debtToken.allowance(address(retargetter), address(positionManager)), 0, "debt scrubbed");
  }

  function test_rebalance_emitsRebalancedWithResolvedSentinels() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    _mintCollateral(address(retargetter), 300e18);
    _mintDebt(address(retargetter), 40e18);

    // Both fields and both legs use the sentinel; the event must carry the resolved balances
    vm.prank(rebalancer);
    vm.expectEmit(true, false, false, true, address(retargetter));
    emit IRetargetter.Rebalanced(address(positionManager), 300e18, 40e18);
    retargetter.rebalance(
      _rebalancingData2(
        MAX_SENTINEL,
        MAX_SENTINEL,
        RebalancingOperationType.SUPPLY,
        MAX_SENTINEL,
        RebalancingOperationType.REPAY,
        MAX_SENTINEL
      )
    );
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*               PRINCIPAL CAP SELF-CORRECTION                */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Once a rebalance moves the book to target, the live-recomputed principal cap
  ///      collapses to zero and further consumption is blocked (spec 6.2, test plan item 2).
  function test_rebalance_principalCapSelfCorrects() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(6_000e18, 100);
    _setMaxRebalanceLoss(1000);
    _mintCollateral(address(retargetter), 6_000e18);

    assertGt(retargetter.maxPrincipal(address(positionManager)), 6_000e18, "cap covers the announced principal");

    vm.prank(rebalancer);
    retargetter.rebalance(
      _rebalancingData2(
        6_000e18, 0, RebalancingOperationType.SUPPLY, 6_000e18, RebalancingOperationType.BORROW, 6_200e18
      )
    );

    assertEq(retargetter.maxPrincipal(address(positionManager)), 0, "cap collapsed at target");

    // The principal gate rejects any further consume before the signature is even checked
    Offer memory offer = _createOffer(1_000e18, 0);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.consume(offer, "", 1_000e18);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*          POSITION MANAGER GUARDRAILS UNDERNEATH            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev The position manager's rebalance cooldown is not re-implemented and keeps applying
  ///      underneath the Retargetter: a second rebalance in the same block reverts.
  function test_rebalance_pmCooldownAppliesUnderneath() public {
    _seedPosition(10_000e18, 5_000e18);
    _startAsync(1_000e18, 100);
    vm.prank(owner);
    positionManager.setRebalanceConfig(1, 1 hours);
    _mintCollateral(address(retargetter), 200e18);

    vm.prank(rebalancer);
    retargetter.rebalance(_rebalancingData(100e18, 0, RebalancingOperationType.SUPPLY, 100e18));

    vm.prank(rebalancer);
    vm.expectRevert(LibManagerErrors.RebalanceCooldownNotElapsed.selector);
    retargetter.rebalance(_rebalancingData(100e18, 0, RebalancingOperationType.SUPPLY, 100e18));
  }
}
