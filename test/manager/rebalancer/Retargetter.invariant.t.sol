// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {RetargetterBaseTest} from "./RetargetterBase.t.sol";
import {RetargetterHandler} from "test/mock/manager/rebalancer/RetargetterHandler.sol";
import {ITokenController} from "src/interfaces/request/ITokenController.sol";

/// @title RetargetterInvariantTest
/// @notice Stateful invariant tests for the Retargetter. A handler drives bounded, fuzz-driven
///         actions across the whole surface (ASYNC lifecycle, fund order lifecycle, guarded
///         rebalances, SYNC windows, owner overrides and environment drift) and the invariants
///         assert the settlement and guardrail properties after every call sequence.
/// @dev Run with: FOUNDRY_PROFILE=full forge test --match-path test/manager/rebalancer/Retargetter.invariant.t.sol
///      forge-std's Test already inherits StdInvariant, so the fixture chain provides
///      targetContract/targetSelector directly.
contract RetargetterInvariantTest is RetargetterBaseTest {
  RetargetterHandler public handler;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public override {
    super.setUp();

    // Aggregate LTV 0.5 against the 0.7 target: the campaign starts in the LTV-up direction;
    // warps (interest accrual) and act_setTargetLtv expose the LTV-down direction too
    _seedPosition(10_000e18, 5_000e18);

    handler = new RetargetterHandler();
    handler.initialize(
      retargetter,
      positionManager,
      borrowPosition1,
      fund,
      address(flashLoanAdapter),
      collateralToken,
      debtToken,
      owner,
      rebalancer,
      consumer
    );

    targetContract(address(handler));

    bytes4[] memory selectors = new bytes4[](20);
    selectors[0] = RetargetterHandler.act_startAsync.selector;
    selectors[1] = RetargetterHandler.act_consume.selector;
    selectors[2] = RetargetterHandler.act_pull.selector;
    selectors[3] = RetargetterHandler.act_repay.selector;
    selectors[4] = RetargetterHandler.act_resolve.selector;
    selectors[5] = RetargetterHandler.act_forceRepay.selector;
    selectors[6] = RetargetterHandler.act_createOrder.selector;
    selectors[7] = RetargetterHandler.act_commit.selector;
    selectors[8] = RetargetterHandler.act_settle.selector;
    selectors[9] = RetargetterHandler.act_unlock.selector;
    selectors[10] = RetargetterHandler.act_cancel.selector;
    selectors[11] = RetargetterHandler.act_failAndRecover.selector;
    selectors[12] = RetargetterHandler.act_rebalance.selector;
    selectors[13] = RetargetterHandler.act_syncRetarget.selector;
    selectors[14] = RetargetterHandler.act_warp.selector;
    selectors[15] = RetargetterHandler.act_setSharePrice.selector;
    selectors[16] = RetargetterHandler.act_setEstimates.selector;
    selectors[17] = RetargetterHandler.act_setTargetLtv.selector;
    selectors[18] = RetargetterHandler.act_authorizeMinting.selector;
    selectors[19] = RetargetterHandler.act_mintAuthorized.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    vm.label(address(handler), "RetargetterHandler");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INVARIANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice RT-1: One operation at a time with a consistent shape, for every state
  ///         observable across transaction boundaries: an active operation is necessarily
  ///         ASYNC and carries a Request and a whitelisted fund (setFund reverts while the
  ///         fund is bound). SYNC windows intentionally run active with a zero Request
  ///         inside their own transaction (that absence gates the ASYNC-only steps, see
  ///         LibStorage), but they are transaction-scoped, cleared before
  ///         startSyncRetargetting returns or rolled back by its revert, so this invariant,
  ///         evaluated between handler calls, never observes one; RT-9 asserts that
  ///         transaction scoping and a RetargetterSync unit test probes the in-window shape.
  function invariant_oneOperationAtATime() public view {
    if (!retargetter.isActive()) return;
    (, address request, address operationFund,,,,,,,,) = retargetter.operation();
    assertTrue(request != address(0), "RT-1: active operation without a Request");
    assertTrue(operationFund != address(0), "RT-1: active operation without a fund");
    assertTrue(retargetter.isFund(operationFund), "RT-1: active operation's fund not whitelisted");
  }

  /// @notice RT-2: No value at rest. Whenever no operation is active the Retargetter holds
  ///         exactly zero of both bound assets and stores no order: every inflow happens
  ///         inside an operation or window and resolve/window-close gate on zero residual.
  ///         The handler never donates outside operations, so this is exact.
  function invariant_noValueAtRest_afterResolve() public view {
    assertFalse(handler.residualAtSettlementViolated(), "RT-2: resolve left a residual balance behind");
    if (retargetter.isActive()) return;
    assertEq(collateralToken.balanceOf(address(retargetter)), 0, "RT-2: collateral at rest while inactive");
    assertEq(debtToken.balanceOf(address(retargetter)), 0, "RT-2: debt at rest while inactive");
    (,,,,,,,,,, bool orderLive) = retargetter.operation();
    assertFalse(orderLive, "RT-2: stored order survived while inactive");
  }

  /// @notice RT-3: The PT supply never exceeds the live principal cap at consume time. The
  ///         handler re-reads maxPrincipal right after every successful consume and flags any
  ///         excess (the position manager state cannot move during consume).
  function invariant_ptSupplyNeverExceedsCapAtConsumeTime() public view {
    assertFalse(handler.capViolatedAtConsume(), "RT-3: consume admitted PT supply above the live cap");
  }

  /// @notice RT-4: The owed amount is hard-capped at pt + yt: the min(paidDuration, horizon)
  ///         cap means a delayed repayment can never draw more than the approved yield.
  function invariant_owedNeverExceedsPtPlusYt() public view {
    if (!retargetter.isActive()) return;
    (, address request,,,,,,,,,) = retargetter.operation();
    (uint128 ptSupply, uint128 ytSupply) = ITokenController(request).totalSupplies();
    assertLe(retargetter.owed(), uint256(ptSupply) + uint256(ytSupply), "RT-4: owed exceeds pt + yt");
  }

  /// @notice RT-5: The loan clock origin is stable while a loan is outstanding: once nonzero
  ///         it never moves to a different nonzero value (later consumes accrue from the same
  ///         origin), and it rewinds to zero only when the operation is economically empty
  ///         (no PT, no YT, no pending authorization), reopening the consumption window.
  function invariant_startedAtStableOrRewound() public view {
    assertFalse(handler.startedAtMutated(), "RT-5: startedAt moved while a loan was outstanding");
  }

  /// @notice RT-6: A live stored order implies an active ASYNC operation: flash-loan windows
  ///         are transaction-scoped and never leak a live order across transactions.
  function invariant_orderLiveImpliesActive_orWindow() public view {
    (,,,,,,,,,, bool orderLive) = retargetter.operation();
    if (orderLive) assertTrue(retargetter.isActive(), "RT-6: live order without an active operation");
  }

  /// @notice RT-7: Every successful resolve happened on a repaid Request (the syncRepaidStatus
  ///         gate), recorded as a ghost right after each resolve.
  function invariant_requestRepaidBeforeResolveGhost() public view {
    if (handler.sawResolve()) {
      assertFalse(handler.resolvedRequestUnrepaid(), "RT-7: resolve succeeded on an unrepaid Request");
    }
  }

  /// @notice RT-8: Direction safety for the semi-trusted rebalancer: a successful rebalance
  ///         ending above target must have strictly improved on its before snapshot (recorded
  ///         by the handler around every act_rebalance).
  function invariant_targetDirectionSafety() public view {
    assertFalse(handler.directionViolated(), "RT-8: rebalance ended above target without improving");
  }

  /// @notice RT-9: SYNC windows persist nothing: after every attempt (landed or reverted) no
  ///         operation is active and no order is stored.
  function invariant_syncLeavesNoState() public view {
    assertFalse(handler.syncStatePersisted(), "RT-9: a SYNC window left persistent state behind");
  }

  /// @notice RT-10: The committed principal (PT supply plus outstanding mint authorizations)
  ///         never exceeds the live cap at the moment an authorization is granted.
  function invariant_authorizeRespectsLiveCap() public view {
    assertFalse(handler.capViolatedAtAuthorize(), "RT-10: authorize admitted committed principal above the live cap");
  }

  /// @notice RT-11: Bridge value conservation: no successful rebalance grew the position
  ///         manager's totalAssets while the operation's Request was unrepaid and short of
  ///         its deadline (recorded by the handler around every act_rebalance).
  function invariant_bridgeValueConservation() public view {
    assertFalse(
      handler.valueConservationViolated(), "RT-11: rebalance grew totalAssets while the bridge was outstanding"
    );
  }
}
