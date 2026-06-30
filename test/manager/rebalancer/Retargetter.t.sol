// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {PositionManagerBaseTest} from "../PositionManagerBase.t.sol";

// --- Retargetter under test ---------------------------------------------------------------------
import {Retargetter, RetargetterInitParams} from "src/manager/rebalancer/Retargetter.sol";
import {RetargetterConfig} from "src/libs/manager/rebalancer/LibRetargetter.sol";
import {IRetargetter} from "src/interfaces/manager/rebalancer/IRetargetter.sol";
import {BatchEntryInput, BatchEntryView} from "src/interfaces/manager/rebalancer/IRetargetterBatch.sol";
import {Action, ActionKind, Proposal} from "src/libs/manager/rebalancer/Action.sol";
import {REBALANCER_ROLE, CONSUMER_ROLE, PAUSER_ROLE} from "src/libs/manager/rebalancer/LibRetargetterConstants.sol";
import {LibRetargetterErrors} from "src/libs/manager/rebalancer/LibRetargetterErrors.sol";

// --- Auction (Request) + Fund collaborators ------------------------------------------------------
import {RequestFactory} from "src/request/RequestFactory.sol";
import {IRequest} from "src/interfaces/request/IRequest.sol";
import {MockFund} from "test/mock/facility/MockFund.sol";
import {Order, Mode, State} from "src/libs/funds/Order.sol";

// --- PositionManager rebalancing payloads --------------------------------------------------------
import {
  RebalancingData,
  RebalancingOperation,
  RebalancingOperationType
} from "src/interfaces/manager/base/IPositionManagerRebalancing.sol";
import {LibManagerErrors} from "src/libs/manager/LibManagerErrors.sol";

import {LibClone} from "lib/solady/src/utils/LibClone.sol";

/// @title RetargetterTest
/// @notice Worked-example + pessimistic-NAV-drop scaffold for the {Retargetter} deleverage flow.
/// @dev SCAFFOLD ONLY. Tests are stubs with arrange/act/assert outlines and TODOs; they are NOT
///      expected to pass as-is. Numbers track the lender-facing explainer worked example:
///      pair = (wUSCC collateral, USDC debt), assumed 1:1 price, deleverage 60% -> 50% LTV.
///
///      Reuses {PositionManagerBaseTest}: real Morpho + PositionManager + MorphoBorrowPosition
///      stack, `collateralToken` = wUSCC stand-in, `debtToken` = USDC stand-in, 1e36 (1:1) oracle.
///      The Retargetter is deployed behind a clone (its constructor disables initializers) and
///      `initialize`d; it holds REBALANCER_ROLE on the PositionManager so proposal REBALANCE actions
///      can drive `rebalance(...)`. Auction Requests are real (deployed by `openBatch` through the
///      real {RequestFactory}); the redemption leg uses {MockFund} so the test controls how many
///      USDC the collateral redeems into (this is the knob the pessimistic cascade turns).
contract RetargetterTest is PositionManagerBaseTest {
  using LibClone for address;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        TEST CONTRACTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  Retargetter public retargetter;
  RequestFactory public requestFactory;
  MockFund public fund;

  // Actors specific to the Retargetter lifecycle.
  address public operator; // REBALANCER_ROLE: opens batch, proposes, executes
  address public consumer; // CONSUMER_ROLE: consumes offers / authorizes minting
  address public maker; // auction maker who deposits USDC principal into the Request

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                  WORKED-EXAMPLE CONSTANTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  uint256 constant SCALE = 1e18; // tokens are 18-dp; oracle is 1:1

  // Start / goal (ideal, ignoring cost).
  uint256 constant START_COLL = 10_000_000 * SCALE; // wUSCC
  uint256 constant START_DEBT = 6_000_000 * SCALE; // USDC  => LTV 60%
  uint256 constant START_EQUITY = 4_000_000 * SCALE;

  // Auction sizing.
  uint256 constant RAISE_TOTAL = 2_000_000 * SCALE; // PT principal raised across the batch
  uint256 constant YIELD_TOTAL = 548 * SCALE; // 10% annualized * 2,000,000 * 1/365 ≈ 548 USDC
  uint256 constant SAFETY_BUFFER_BPS = 100; // 1% redemption safety buffer

  // Single-batch (scenario A) checkpoints.
  // WITHDRAW = (RAISE_TOTAL + YIELD_TOTAL) * 1.01 ≈ 2,020,553
  uint256 constant A_WITHDRAW = 2_020_553 * SCALE;
  uint256 constant A_END_COLL = 7_979_447 * SCALE;
  uint256 constant A_END_DEBT = 4_000_000 * SCALE; // intermediate (Proposal A), LTV ≈ 50.1%
  uint256 constant B_REPAY = 2_000_548 * SCALE; // principal + yield owed to the auction
  uint256 constant B_SWEEP = 20_005 * SCALE; // leftover redemption proceeds swept into debt
  uint256 constant FINAL_DEBT = 3_979_995 * SCALE; // after Proposal B, LTV ≈ 49.9%

  // The single REBALANCE call in Proposal A drops PM NAV from 4,000,000 -> 3,979,447 by giving up
  // (A_WITHDRAW - RAISE_TOTAL) = 20,553 collateral against a 2,000,000 funded repayment, i.e.
  // 20,553 / 4,000,000 = ~51.38 bps. maxRebalanceLoss must be >= this for Proposal A to land.
  uint16 constant A_LOSS_BPS_FAIL = 50; // 50 bps  -> Proposal A REBALANCE reverts (too tight)
  uint16 constant A_LOSS_BPS_PASS = 60; // 60 bps  -> Proposal A REBALANCE allowed

  // Two-round variant (scenario B) checkpoints.
  uint256 constant R1_RAISE = 1_200_000 * SCALE;
  uint256 constant R1_END_COLL = 8_787_668 * SCALE;
  uint256 constant R1_END_DEBT = 4_787_997 * SCALE; // LTV ≈ 54.5%
  uint256 constant R2_RAISE = 800_000 * SCALE;

  // Policy timelocks (kept small so warps are cheap).
  uint40 constant CONSUME_TIMELOCK = 1 hours;
  uint40 constant PROPOSAL_TIMELOCK = 1 hours;
  uint40 constant HORIZON = 1 days; // BF loan tenor
  uint40 constant TICK_DURATION = 1 days;
  uint40 constant TICK_THRESHOLD = 12 hours;
  uint40 constant MINT_TO_REPAID_DELAY = 0;
  uint16 constant MAX_YIELD_BPS = 1_000; // 10% over horizon (matches "10% annualized, 1-day loan")

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public override {
    super.setUp(); // real Morpho + PositionManager + bp1/bp2, 1:1 oracle, deep market liquidity

    operator = makeAddr("operator");
    consumer = makeAddr("rt_consumer");
    maker = makeAddr("maker");

    // --- Auction factory + redemption fund -------------------------------------------------------
    requestFactory = new RequestFactory(owner);
    // Fund orientation MUST mirror the batch's expectation: asset == debt (USDC), share == collateral.
    fund = new MockFund(address(debtToken), address(collateralToken));

    // --- Deploy + initialize Retargetter behind a clone -----------------------------------------
    // (constructor disables initializers on the implementation, exactly like PositionManager)
    retargetter = Retargetter(address(new Retargetter()).clone());

    address[] memory rebalancers = new address[](1);
    rebalancers[0] = operator;
    address[] memory consumers = new address[](1);
    consumers[0] = consumer;
    address[] memory pausers = new address[](0);
    address[] memory modulesInit = new address[](0); // no flash-loan module: actions run inline

    retargetter.initialize(
      RetargetterInitParams({
        config: RetargetterConfig({
          collateralAsset: address(collateralToken),
          debtAsset: address(debtToken),
          requestFactory: address(requestFactory),
          consumeTimelock: CONSUME_TIMELOCK,
          proposalTimelock: PROPOSAL_TIMELOCK,
          mintToRepaidDelay: MINT_TO_REPAID_DELAY,
          horizon: HORIZON,
          tickDuration: TICK_DURATION,
          tickThreshold: TICK_THRESHOLD,
          maxYieldBps: MAX_YIELD_BPS
        }),
        owner: owner,
        rebalancers: rebalancers,
        consumers: consumers,
        pausers: pausers,
        modulesInit: modulesInit
      })
    );

    // The Retargetter must be able to drive the PM's rebalance() from inside proposal actions.
    vm.prank(owner);
    positionManager.grantRoles(address(retargetter), _ROLE_REBALANCER);

    // Default: generous loss budget; scenario A overrides this to assert the band.
    vm.prank(owner);
    positionManager.setRebalanceConfig(1000, 0); // 10%

    vm.label(address(retargetter), "Retargetter");
    vm.label(address(requestFactory), "RequestFactory");
    vm.label(address(fund), "RedemptionFund");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Establishes the 10,000,000 wUSCC / 6,000,000 USDC (60% LTV) opening position on the PM,
  ///      routed through bp1 (first in the supply queue).
  function _seedStartingPosition() internal {
    _mintCollateral(minter, START_COLL);
    vm.prank(minter);
    positionManager.deposit(START_COLL, START_DEBT);
    // TODO assert: _pmCollateral() == START_COLL, _pmDebt() == START_DEBT, _pmLtvBps() == 6000
  }

  /// @dev Opens a single-PM batch with a USDC auction Request (maxPrincipal/maxYieldBps) and the
  ///      redemption fund attached. Returns the deployed Request.
  function _openBatch(uint96 maxPrincipal, uint16 maxYieldBps) internal returns (address request) {
    BatchEntryInput[] memory entries = new BatchEntryInput[](1);
    entries[0] = BatchEntryInput({
      positionManager: address(positionManager),
      maxPrincipal: maxPrincipal,
      maxYieldBps: maxYieldBps
    });

    uint64 deadline = uint64(block.timestamp) + 30 days; // backstop, well past consume window
    vm.prank(operator);
    retargetter.openBatch(entries, deadline, address(fund), "Retarget USDC", "rtUSDC");

    request = retargetter.batchEntry(address(positionManager)).request;
    // TODO assert: request != address(0); retargetter.isBatchRequest(request)
  }

  /// @dev Brings `principal` USDC into `request` so PULL_REQUEST can later draw it out. Models the
  ///      auction maker funding the loan: CONSUMER authorizes minting, then the maker mints,
  ///      depositing `principal` USDC and accepting PT. `consumed` on the batch entry advances by
  ///      `principal`. Warps past `consumeAvailableAt` first.
  /// @return ytExpected The YT (yield) leg the maker is owed; bounded by maxYieldBps over horizon.
  function _fundAuction(address request, uint256 principal) internal returns (uint256 ytExpected) {
    // Warp into the consume window.
    (, , uint40 consumeAvailableAt, , , ) = retargetter.batchInfo();
    if (block.timestamp < consumeAvailableAt) vm.warp(consumeAvailableAt);

    // YT cap ramps with paidDuration; for a >=1 tick elapsed batch the cap is ~maxYieldBps.
    // ytExpected = principal * maxYieldBps / BPS (the most the maker may be promised). TODO refine.
    ytExpected = (principal * MAX_YIELD_BPS) / 10_000;

    // CONSUMER authorizes the maker, then the maker mints (deposits USDC principal).
    vm.prank(consumer);
    retargetter.authorizeMinting(address(positionManager), maker, uint128(principal), uint128(ytExpected));

    _mintDebt(maker, principal);
    vm.startPrank(maker);
    debtToken.approve(request, type(uint256).max);
    IRequest(request).mint(uint128(principal), uint128(ytExpected));
    vm.stopPrank();

    // TODO assert: debtToken.balanceOf(request) >= principal;
    //              retargetter.batchEntry(address(positionManager)).consumed advanced by principal
  }

  /// @dev Configures the redemption fund so a committed REDEEM order returns `unlockProceeds` USDC
  ///      on unlock (the lever the pessimistic cascade lowers below B_REPAY).
  function _setFundRedemption(uint256 unlockProceeds) internal {
    fund.setNextCommitState(State.PROCESSING);
    fund.setNextUnlockState(State.ENDED);
    fund.setUnlockAmount(unlockProceeds);
    _mintDebt(address(fund), unlockProceeds); // fund must hold the USDC it pays out on unlock
  }

  // --- Action builders ---------------------------------------------------------------------------

  function _rebalanceAction(RebalancingData memory data) internal view returns (Action memory) {
    return Action({kind: ActionKind.REBALANCE, payload: abi.encode(address(positionManager), data)});
  }

  function _pullRequestAction(address request, uint256 amount) internal pure returns (Action memory) {
    return Action({kind: ActionKind.PULL_REQUEST, payload: abi.encode(request, amount)});
  }

  function _repayRequestAction(address request, uint256 amount, uint256 minBal, uint256 maxBal)
    internal
    pure
    returns (Action memory)
  {
    return Action({kind: ActionKind.REPAY_REQUEST, payload: abi.encode(request, amount, minBal, maxBal)});
  }

  function _fundCreateAction(Order memory order) internal pure returns (Action memory) {
    return Action({kind: ActionKind.FUND_CREATE, payload: abi.encode(order)});
  }

  function _fundCommitAction(uint256 approveAmount) internal pure returns (Action memory) {
    return Action({kind: ActionKind.FUND_COMMIT, payload: abi.encode(approveAmount)});
  }

  function _fundUnlockAction() internal pure returns (Action memory) {
    return Action({kind: ActionKind.FUND_UNLOCK, payload: bytes("")});
  }

  /// @dev REPAY operation that reduces bp1 debt by `repay`, then WITHDRAW that pulls `withdraw`
  ///      collateral out to the Retargetter. `debt` is the USDC injected to fund the repay.
  function _deleverRebalanceData(uint256 repay, uint256 withdraw, uint256 debt)
    internal
    view
    returns (RebalancingData memory data)
  {
    RebalancingOperation[] memory ops = new RebalancingOperation[](2);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: repay
    });
    ops[1] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.WITHDRAW, amount: withdraw
    });
    data = RebalancingData({collateral: 0, debt: debt, operations: ops});
  }

  /// @dev REPAY-only sweep: pushes `sweep` USDC into bp1 debt (Proposal B leftover -> debt).
  function _sweepRebalanceData(uint256 sweep) internal view returns (RebalancingData memory data) {
    RebalancingOperation[] memory ops = new RebalancingOperation[](1);
    ops[0] = RebalancingOperation({
      position: address(borrowPosition1), operationType: RebalancingOperationType.REPAY, amount: sweep
    });
    data = RebalancingData({collateral: 0, debt: sweep, operations: ops});
  }

  function _redeemOrder(uint256 collateralIn, uint256 usdcOut) internal view returns (Order memory) {
    return Order({
      mode: Mode.REDEEM,
      owner: address(retargetter),
      receiver: address(retargetter),
      input: collateralIn,
      output: usdcOut,
      salt: bytes32(0)
    });
  }

  // --- Proposal builders -------------------------------------------------------------------------

  /// @dev Proposal A: pull principal, delever the PM, open + commit the redemption order.
  function _buildProposalA(address request, uint256 raise, uint256 withdraw) internal view returns (Proposal memory) {
    Action[] memory actions = new Action[](4);
    actions[0] = _pullRequestAction(request, raise);
    actions[1] = _rebalanceAction(_deleverRebalanceData(raise, withdraw, raise));
    actions[2] = _fundCreateAction(_redeemOrder(withdraw, withdraw)); // expect ~1:1 USDC out
    actions[3] = _fundCommitAction(withdraw);
    return Proposal({module: address(0), moduleData: bytes(""), actions: actions, receiver: address(retargetter), salt: bytes32(uint256(0xA))});
  }

  /// @dev Proposal B: unlock redemption, repay the auction within a tight band, sweep leftover.
  function _buildProposalB(address request, uint256 repay, uint256 sweep) internal view returns (Proposal memory) {
    Action[] memory actions = new Action[](3);
    actions[0] = _fundUnlockAction();
    // Tight band: balance must land exactly on `repay`; a shortfall or overshoot reverts loudly.
    actions[1] = _repayRequestAction(request, repay, repay, repay);
    actions[2] = _rebalanceAction(_sweepRebalanceData(sweep));
    return Proposal({module: address(0), moduleData: bytes(""), actions: actions, receiver: address(retargetter), salt: bytes32(uint256(0xB))});
  }

  /// @dev Commit + warp + execute a proposal as the operator.
  function _proposeAndExecute(Proposal memory proposal) internal {
    bytes32 hash = keccak256(abi.encode(proposal));
    vm.prank(operator);
    retargetter.propose(hash);
    vm.warp(block.timestamp + PROPOSAL_TIMELOCK);
    vm.prank(operator);
    retargetter.executeProposal(proposal);
  }

  /// @dev Same as {_proposeAndExecute} but expects the execute leg to revert with `selector`.
  function _proposeAndExpectRevert(Proposal memory proposal, bytes4 selector) internal {
    bytes32 hash = keccak256(abi.encode(proposal));
    vm.prank(operator);
    retargetter.propose(hash);
    vm.warp(block.timestamp + PROPOSAL_TIMELOCK);
    vm.prank(operator);
    vm.expectRevert(selector);
    retargetter.executeProposal(proposal);
  }

  // --- PM state views (TODO: wire to the exact borrow-position / PM getters) ----------------------

  function _pmCollateral() internal view returns (uint256) {
    return borrowPosition1.totalCollateral();
  }

  function _pmDebt() internal view returns (uint256) {
    return borrowPosition1.totalBorrowed();
  }

  function _pmLtvBps() internal view returns (uint256) {
    uint256 coll = _pmCollateral();
    if (coll == 0) return 0;
    return (_pmDebt() * 10_000) / coll; // 1:1 oracle, so value == amount
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*           SCENARIO A: SINGLE-BATCH 60% -> 50%              */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Full single-batch deleverage reaches ~7,979,447 / ~3,979,995 at ~49.9% LTV, cost ≈ $548.
  function test_A_singleBatch_deleverage_reachesTarget() public {
    // Arrange
    vm.prank(owner);
    positionManager.setRebalanceConfig(A_LOSS_BPS_PASS, 0);
    _seedStartingPosition();
    address request = _openBatch(uint96(RAISE_TOTAL), MAX_YIELD_BPS);
    _fundAuction(request, RAISE_TOTAL);
    _setFundRedemption(A_WITHDRAW); // ~1:1, full proceeds available next day

    // Act — Proposal A (deleverage + open redemption)
    _proposeAndExecute(_buildProposalA(request, RAISE_TOTAL, A_WITHDRAW));
    // TODO assert intermediate: _pmCollateral() ≈ A_END_COLL, _pmDebt() ≈ A_END_DEBT, LTV ≈ 5010 bps

    // Act — Proposal B (settle auction + sweep leftover), ~1 day later
    vm.warp(block.timestamp + HORIZON);
    _proposeAndExecute(_buildProposalB(request, B_REPAY, B_SWEEP));

    // Assert end state
    assertApproxEqRel(_pmCollateral(), A_END_COLL, 0.001e18, "end collateral ~7,979,447");
    assertApproxEqRel(_pmDebt(), FINAL_DEBT, 0.001e18, "end debt ~3,979,995");
    // LTV ≈ 49.9%
    assertApproxEqAbs(_pmLtvBps(), 4990, 5, "end LTV ~49.9%");
    // True economic cost ≈ YIELD_TOTAL: equity dropped from 4,000,000 by ~548.
    // TODO assert: START_EQUITY - (_pmCollateral() - _pmDebt()) ≈ YIELD_TOTAL (±rounding)

    // Batch can close: the Request is repaid within band.
    vm.prank(operator);
    retargetter.closeBatch();
    // TODO assert: !retargetter.batchInfo().active
  }

  /// @notice Proposal A's single REBALANCE shows a ~51 bps intermediate NAV dip; it LANDS when
  ///         maxRebalanceLoss is set above the dip.
  function test_A_intermediateLoss_withinBand_succeeds() public {
    // Arrange — 60 bps budget > 51.38 bps dip
    vm.prank(owner);
    positionManager.setRebalanceConfig(A_LOSS_BPS_PASS, 0);
    _seedStartingPosition();
    address request = _openBatch(uint96(RAISE_TOTAL), MAX_YIELD_BPS);
    _fundAuction(request, RAISE_TOTAL);
    _setFundRedemption(A_WITHDRAW);

    // Act + Assert — executes without reverting
    _proposeAndExecute(_buildProposalA(request, RAISE_TOTAL, A_WITHDRAW));
    // TODO assert: _pmCollateral() ≈ A_END_COLL && _pmDebt() ≈ A_END_DEBT
  }

  /// @notice The SAME Proposal A REVERTS when maxRebalanceLoss is set below the ~51 bps dip:
  ///         the bound is load-bearing, not cosmetic.
  function test_A_intermediateLoss_tooTight_reverts() public {
    // Arrange — 50 bps budget < 51.38 bps dip
    vm.prank(owner);
    positionManager.setRebalanceConfig(A_LOSS_BPS_FAIL, 0);
    _seedStartingPosition();
    address request = _openBatch(uint96(RAISE_TOTAL), MAX_YIELD_BPS);
    _fundAuction(request, RAISE_TOTAL);
    _setFundRedemption(A_WITHDRAW);

    // Act + Assert — the PM's loss guard bubbles up through executeProposal
    _proposeAndExpectRevert(
      _buildProposalA(request, RAISE_TOTAL, A_WITHDRAW), LibManagerErrors.RebalanceLossExceedsMax.selector
    );
  }

  /// @notice Boundary scan around the ~51.38 bps dip: revert just below, pass just above.
  /// @dev TODO: parametrize maxRebalanceLoss ∈ {51, 52} and assert the flip at the computed edge.
  function test_A_intermediateLoss_boundaryIsExact() public {
    // TODO: arrange identical to above, sweep the loss-cap by 1 bp across the edge, assert flip.
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*        SCENARIO B: TWO ROUNDS (1,200,000 + 800,000)        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Two consume+proposal rounds within ONE batch reach the same end state; `consumed`
  ///         accumulates 1,200,000 -> 2,000,000 (<= maxPrincipal) and maxYieldBps carries across.
  function test_B_twoRounds_reachSameEndState() public {
    // Arrange — one batch, full 2,000,000 principal cap, generous loss budget.
    vm.prank(owner);
    positionManager.setRebalanceConfig(A_LOSS_BPS_PASS, 0);
    _seedStartingPosition();
    address request = _openBatch(uint96(RAISE_TOTAL), MAX_YIELD_BPS);

    // --- Round 1: raise 1,200,000 -> 8,787,668 / 4,787,997 / 54.5% ---
    _fundAuction(request, R1_RAISE);
    assertEq(retargetter.batchEntry(address(positionManager)).consumed, R1_RAISE, "consumed after R1");
    uint256 r1Withdraw = ((R1_RAISE + ((R1_RAISE * 1000) / 10_000 / 365)) * (10_000 + SAFETY_BUFFER_BPS)) / 10_000;
    _setFundRedemption(r1Withdraw);
    _proposeAndExecute(_buildProposalA(request, R1_RAISE, r1Withdraw));
    vm.warp(block.timestamp + HORIZON);
    // TODO: Round-1 settle proposal (unlock + repay R1 band + sweep) mirroring Proposal B.
    // TODO assert: _pmCollateral() ≈ R1_END_COLL && _pmDebt() ≈ R1_END_DEBT && LTV ≈ 5450 bps

    // --- Round 2: raise 800,000 -> 7,979,447 / 3,979,995 / 49.9% ---
    _fundAuction(request, R2_RAISE);
    assertEq(retargetter.batchEntry(address(positionManager)).consumed, RAISE_TOTAL, "consumed after R2 == cap");
    uint256 r2Withdraw = ((R2_RAISE + ((R2_RAISE * 1000) / 10_000 / 365)) * (10_000 + SAFETY_BUFFER_BPS)) / 10_000;
    _setFundRedemption(r2Withdraw);
    _proposeAndExecute(_buildProposalA(request, R2_RAISE, r2Withdraw));
    vm.warp(block.timestamp + HORIZON);
    // TODO: Round-2 settle proposal.

    // Assert convergence to the single-batch end state.
    assertApproxEqRel(_pmCollateral(), A_END_COLL, 0.001e18, "end collateral matches single-batch");
    assertApproxEqRel(_pmDebt(), FINAL_DEBT, 0.001e18, "end debt matches single-batch");
  }

  /// @notice The cumulative `consumed` cap is enforced across rounds: a third tranche that would
  ///         push consumed past maxPrincipal reverts with PrincipalCapExceeded.
  function test_B_consumedCap_enforcedAcrossRounds() public {
    _seedStartingPosition();
    address request = _openBatch(uint96(RAISE_TOTAL), MAX_YIELD_BPS);
    _fundAuction(request, R1_RAISE);
    _fundAuction(request, R2_RAISE); // consumed == 2,000,000 == cap
    // Act + Assert — one more wei over the cap must revert.
    vm.warp(block.timestamp + CONSUME_TIMELOCK);
    vm.prank(consumer);
    vm.expectRevert(LibRetargetterErrors.PrincipalCapExceeded.selector);
    retargetter.authorizeMinting(address(positionManager), maker, 1, 0);
  }

  /// @notice maxYieldBps ramps with paidDuration across rounds (tick-rounded); an offer/auth whose
  ///         implied yield exceeds the current cap reverts with YieldTooHigh.
  function test_B_yieldCap_rampsWithPaidDuration() public {
    // TODO: open batch, attempt authorizeMinting with ytAmount above the tick-rounded cap at t≈0,
    //       assert YieldTooHigh; warp a full tick and assert the same authorization now succeeds.
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*            SCENARIO C: PESSIMISTIC NAV-DROP CASCADE        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Collateral drops ~5% during the redemption day, so unlock proceeds (~1,919,525) fall
  ///         short of B_REPAY (2,000,548). Proposal B's REPAY_REQUEST band catches it and reverts.
  function test_C_redemptionShortfall_repayBandReverts() public {
    // Arrange — Proposal A lands at the day-0 price.
    vm.prank(owner);
    positionManager.setRebalanceConfig(A_LOSS_BPS_PASS, 0);
    _seedStartingPosition();
    address request = _openBatch(uint96(RAISE_TOTAL), MAX_YIELD_BPS);
    _fundAuction(request, RAISE_TOTAL);
    _setFundRedemption(A_WITHDRAW); // optimistic; will be overwritten before unlock
    _proposeAndExecute(_buildProposalA(request, RAISE_TOTAL, A_WITHDRAW));

    // Act — 1 day passes and collateral price drops ~5%: the fund now returns less USDC.
    vm.warp(block.timestamp + HORIZON);
    uint256 shortfallProceeds = (A_WITHDRAW * 95) / 100; // ≈ 1,919,525 USDC
    _setFundRedemption(shortfallProceeds);

    // Assert — REPAY_REQUEST cannot meet its band; execute reverts (RepayBalanceOutOfRange).
    _proposeAndExpectRevert(
      _buildProposalB(request, B_REPAY, B_SWEEP), LibRetargetterErrors.RepayBalanceOutOfRange.selector
    );
  }

  /// @notice Recovery option 1: borrow more from the SAME PM (up to safeLtv) to top up the repay.
  ///         A settle proposal that adds a BORROW within safe LTV succeeds.
  function test_C_recovery_borrowMoreWithinSafeLtv_succeeds() public {
    // TODO arrange: as in test_C_redemptionShortfall, then build a settle proposal whose REBALANCE
    //      BORROWs the (B_REPAY - shortfallProceeds) gap from bp1 BEFORE REPAY_REQUEST, keeping LTV
    //      <= BP_SAFE_LTV. Assert execute succeeds and the Request is repaid in-band.
  }

  /// @notice Recovery option 1 boundary: if topping up would push LTV past safeLtv, the BORROW leg
  ///         reverts (borrow-position safe-LTV guard), so this recovery path is unavailable.
  function test_C_recovery_borrowBeyondSafeLtv_reverts() public {
    // TODO arrange a deeper shortfall so the required top-up borrow breaches BP_SAFE_LTV.
    // TODO act+assert: executeProposal reverts on the BORROW op (borrow-position LTV guard selector).
  }

  /// @notice Recovery option 2: roll the loan — open a SECOND batch/Request, raise fresh USDC, and
  ///         use it to settle the first auction. The original batch then closes repaid.
  function test_C_recovery_secondBfLoan_rollsTheAuction() public {
    // TODO: after the shortfall, close path is blocked; open a second batch, fund it, and settle
    //       the first Request from the new proceeds. Assert both batches eventually close repaid.
  }

  /// @notice Recovery option 3: default the BF — let the Request hit its repaymentDeadline; the
  ///         auto-expire path resolves it so the batch can still close (PT/YT holders bear the loss).
  function test_C_recovery_defaultBf_autoExpiresAndCloses() public {
    // Arrange — shortfall leaves the Request un-repayable in-band.
    vm.prank(owner);
    positionManager.setRebalanceConfig(A_LOSS_BPS_PASS, 0);
    _seedStartingPosition();
    address request = _openBatch(uint96(RAISE_TOTAL), MAX_YIELD_BPS);
    _fundAuction(request, RAISE_TOTAL);
    _setFundRedemption(A_WITHDRAW);
    _proposeAndExecute(_buildProposalA(request, RAISE_TOTAL, A_WITHDRAW));

    // Act — never repay; warp past the Request's repaymentDeadline.
    (, , , uint64 deadline, , ) = retargetter.batchInfo();
    vm.warp(uint256(deadline) + 1);

    // Assert — closeBatch syncs the auto-expired Request and succeeds.
    vm.prank(operator);
    retargetter.closeBatch();
    // TODO assert: !retargetter.batchInfo().active; document that PT/YT holders absorb the shortfall.
  }

  /// @notice NEAR-LIQUIDATION: collateral falls so far that the deleverage's required bonus
  ///         (≈ 1 - LTV) exceeds the 10% maxRebalanceLoss cap, so the rebalance is IMPOSSIBLE
  ///         without governance raising the cap (or an external recap).
  function test_C_nearLiquidation_bonusExceedsMaxLossCap_impossible() public {
    // Arrange — start position, then crash the oracle so the position is near its liquidation LTV.
    vm.prank(owner);
    positionManager.setRebalanceConfig(1000, 0); // 10% cap (the production-style ceiling)
    _seedStartingPosition();
    address request = _openBatch(uint96(RAISE_TOTAL), MAX_YIELD_BPS);
    _fundAuction(request, RAISE_TOTAL);

    // Drop collateral price hard (e.g. -20%): equity collapses, so any deleverage that gives up
    // collateral at a >10% effective haircut trips the loss guard.
    oracle.setPrice((DEFAULT_ORACLE_PRICE * 80) / 100);
    _setFundRedemption(A_WITHDRAW);

    // Act + Assert — the REBALANCE leg's NAV drop now exceeds 10%; executeProposal reverts.
    _proposeAndExpectRevert(
      _buildProposalA(request, RAISE_TOTAL, A_WITHDRAW), LibManagerErrors.RebalanceLossExceedsMax.selector
    );

    // TODO: optionally show that raising maxRebalanceLoss above the required bonus (governance) is
    //       the ONLY on-chain path that lets the same proposal through.
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   GUARD / ORDERING TESTS                   */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice executeProposal reverts before the proposal timelock elapses.
  function test_guard_proposalTimelockNotElapsed_reverts() public {
    // TODO: propose then executeProposal immediately; expect ProposalTimelockNotElapsed.
  }

  /// @notice Mutating the proposal payload after propose() breaks the hash commitment.
  function test_guard_proposalHashMismatch_reverts() public {
    // TODO: propose hash of P, then executeProposal(P') with one altered amount; expect ProposalHashMismatch.
  }

  /// @notice A REBALANCE/PULL/REPAY action targeting a PM/Request outside the batch reverts.
  function test_guard_actionTargetNotInBatch_reverts() public {
    // TODO: build a proposal whose REBALANCE targets a non-batch PM; expect ActionTargetNotInBatch.
  }
}
