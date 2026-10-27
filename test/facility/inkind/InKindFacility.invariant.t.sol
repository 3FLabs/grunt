// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {console2} from "forge-std/console2.sol";

import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {InKindFacilityHandler} from "test/mock/facility/InKindFacilityHandler.sol";

/// @title InKindFacilityInvariantTest
/// @notice Invariant test suite for the InKindFacility contract.
/// @dev Exercises the in-kind lifecycle (entries, exits, ops seeding, oracle and interest
///      drift, offer / security cap / auth re-arms with ABSOLUTE words, pauses) via an
///      InKindFacilityHandler and asserts after every fuzzed action sequence:
///      - INK-1: the facility is a pure pass-through and holds no token.
///      - INK-2: the facility never keeps allowances it granted.
///      - INK-3: the ABSOLUTE capacity, security and exit words and every user auth match an
///        exact ghost mirror of every consume.
///      - INK-4: the ABSOLUTE words and the auth amounts only decrease between re-arms.
///      - INK-5: the previews agree with execution and share its gates.
///      - INK-6: `maxEnter` / `maxExit` never quote an amount the caps then refuse.
///      - INK-7: the share fees are exact, rounded up, and paid to the fee recipient.
///      - INK-8: the debt and underlying legs are exact.
///      - INK-9: solvency echo: PM supply equals the tracked holders' balances and the PM
///        aggregate views stay callable and consistent in every reachable state.
///      Runs under `fail_on_revert = false`; the handler itself never reverts, which the
///      counters and the smoke test guard.
contract InKindFacilityInvariantTest is InKindFacilityBaseTest {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          HANDLER                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  InKindFacilityHandler public handler;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          CONSTANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  // Large but finite ABSOLUTE words: a few dozen entries at the seed ratio exhaust them.
  uint256 constant INITIAL_CAPACITY = 100_000e6;
  uint256 constant INITIAL_SECURITY = 60_000e6;
  uint256 constant INITIAL_EXIT_CAP = 80_000e6;
  uint128 constant INITIAL_AUTH = 5_000e6;
  uint24 constant PM_MANAGEMENT_FEE = 100;
  uint24 constant PM_PERFORMANCE_FEE = 1_000;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            SETUP                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function setUp() public override {
    super.setUp();

    // Seed and lever the pool through the ops path so offers open on a live ratio, with PM
    // fees on so pending fee shares are part of every share denominator.
    _seedPool(SEED_COLLATERAL, SEED_DEBT);
    _setPmFees(PM_MANAGEMENT_FEE, PM_PERFORMANCE_FEE);

    // Open both sides and the security cap with finite ABSOLUTE words.
    _setEntry(positionManager, INITIAL_CAPACITY, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setExit(positionManager, INITIAL_EXIT_CAP, FAR_EXPIRY, DEFAULT_FEE_BPS);
    _setSecurityCap(INITIAL_SECURITY);

    // Handler wiring: initialize, one initial auth, prime the ghosts, register the selectors.
    handler = new InKindFacilityHandler();
    _setAuth(handler.users(0), INITIAL_AUTH, uint40(block.timestamp + 30 days));
    handler.initialize(
      facility, positionManager, collateralToken, underlyingToken, debtToken, facilitator, operator, compliance, seeder
    );
    handler.initializeDependencies(oracle, morpho, marketParams);

    bytes4[] memory selectors = new bytes4[](11);
    selectors[0] = InKindFacilityHandler.act_enter.selector;
    selectors[1] = InKindFacilityHandler.act_exit.selector;
    selectors[2] = InKindFacilityHandler.act_seed.selector;
    selectors[3] = InKindFacilityHandler.act_warp.selector;
    selectors[4] = InKindFacilityHandler.act_moveOracle.selector;
    selectors[5] = InKindFacilityHandler.act_accrueInterest.selector;
    selectors[6] = InKindFacilityHandler.act_setEntry.selector;
    selectors[7] = InKindFacilityHandler.act_setExit.selector;
    selectors[8] = InKindFacilityHandler.act_setSecurityCap.selector;
    selectors[9] = InKindFacilityHandler.act_setAuth.selector;
    selectors[10] = InKindFacilityHandler.act_pause.selector;

    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));

    vm.label(address(handler), "InKindFacilityHandler");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       HANDLER SMOKE                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Guards against vacuous invariant runs: every action must actually go through
  ///         (not just early-return through its try/catch) under known-good fixed seeds, and
  ///         the cap, gate and probe branches must each be reached once.
  function test_handlerActionsSucceed() public {
    address user0 = handler.users(0);

    // Plain entry by user0 (authed) to itself, then an entry to another receiver.
    handler.act_enter(0, 1_000e18, 0, 1);
    assertEq(handler.enterSuccesses(), 1, "enter action did not go through");
    handler.act_enter(1, 500e18, 2, 1);
    assertEq(handler.enterSuccesses(), 2, "cross-receiver enter did not go through");
    assertLt(
      facility.getAuth(address(underlyingToken), address(debtToken), user0).amount, INITIAL_AUTH, "auth not consumed"
    );

    // Entry at exactly the maxEnter quote must not fail on a cap.
    handler.act_enter(2, 0, 2, 0);
    assertEq(handler.maxEnterProbes(), 1, "maxEnter probe not taken");
    assertEq(handler.enterSuccesses(), 3, "maxEnter-sized entry did not go through");

    // Ops path, time, interest and price drift.
    handler.act_seed(2_000e18, 900e6);
    assertEq(handler.seedSuccesses(), 1, "seed action did not go through");
    handler.act_warp(1 days + 1); // odd seed: long warp
    handler.act_accrueInterest();
    handler.act_moveOracle(1.2e24 + 1); // seed % 16 != 0: normal band, in range so taken as is

    // Exit half of user0's shares to user1, then a maxExit-sized exit by user2 (the largest
    // holder after its maxEnter-sized entry) under a tight cap.
    handler.act_exit(0, positionManager.balanceOf(user0) / 2, 1, 1);
    assertEq(handler.exitSuccesses(), 1, "exit action did not go through");
    handler.act_setExit(1_000e6 + 1, 1, 100); // tight cap (seed % 3 != 0), long expiry
    assertEq(handler.exitRearms(), 1, "exit re-arm did not go through");
    handler.act_exit(2, 1, 0, 0);
    assertEq(handler.maxExitProbes(), 1, "maxExit probe not taken");
    assertEq(handler.exitSuccesses(), 2, "maxExit-sized exit did not go through");

    // Cap branch: a zero security cap with no auth left for user1 refuses the entry.
    handler.act_setSecurityCap(1); // mode 1: zero
    assertEq(facility.getSecurityCap(address(underlyingToken), address(debtToken)), 0, "security cap not closed");
    handler.act_enter(1, 100e18, 1, 1);
    assertEq(handler.enterCapFailures(), 1, "entry under a closed security cap should fail on the cap");

    // Auth branch: an auth on user1 reopens the way, an expired one does not.
    handler.act_setAuth(1, 10_000e6, 1); // future expiry (seed % 4 != 0)
    assertEq(handler.authRearms(), 1, "auth action did not go through");
    handler.act_enter(1, 100e18, 1, 1);
    assertEq(handler.enterSuccesses(), 4, "authed entry did not go through");
    handler.act_setAuth(1, 10_000e6, 4); // expired (seed % 4 == 0)
    handler.act_enter(1, 100e18, 1, 1);
    assertEq(handler.enterCapFailures(), 2, "entry under an expired auth should fail on the cap");

    // Gate branch: a pause refuses both flows, a warp lifts it.
    handler.act_pause(101); // odd seed: pause for 101 seconds
    assertEq(handler.pauses(), 1, "pause action did not go through");
    handler.act_setSecurityCap(0); // mode 0: unlimited
    handler.act_enter(0, 100e18, 0, 1);
    assertEq(handler.enterGateFailures(), 1, "entry while paused should fail on the gate");
    handler.act_exit(0, 1, 0, 1);
    assertEq(handler.exitGateFailures(), 1, "exit while paused should fail on the gate");
    handler.act_warp(2); // even seed: short warp, at least 1 second
    handler.act_warp(6 hours); // even seed: short warp past the pause
    handler.act_enter(0, 100e18, 0, 1);
    assertEq(handler.enterSuccesses(), 5, "entry after the pause did not go through");

    // Entry re-arm with a tight capacity cap, then a short expiry that a warp disables.
    handler.act_setEntry(2_000e6 + 2, 1, 100);
    assertEq(handler.entryRearms(), 1, "entry re-arm did not go through");
    assertEq(facility.getEntry(address(positionManager)).capacityCap, 2_000e6 + 2, "capacity not re-armed");
    handler.act_setEntry(3, 16, 0); // unlimited cap, expiry in one second (seed % 16 == 0), no fee
    handler.act_warp(1 hours + 1);
    handler.act_enter(0, 100e18, 0, 1);
    assertEq(handler.enterGateFailures(), 2, "entry on an expired offer should fail on the gate");

    assertFalse(handler.facilityHeldTokens(), "ghost INK-1 tripped");
    assertFalse(handler.facilityHeldAllowance(), "ghost INK-2 tripped");
    assertFalse(handler.capMirrorBroken(), "ghost INK-3 tripped");
    assertFalse(handler.absoluteCapIncreased(), "ghost INK-4 tripped");
    assertFalse(handler.previewDesync(), "ghost INK-5 tripped");
    assertFalse(handler.maxEnterLied(), "ghost INK-6 maxEnter tripped");
    assertFalse(handler.maxExitLied(), "ghost INK-6 maxExit tripped");
    assertFalse(handler.feeMirrorBroken(), "ghost INK-7 tripped");
    assertFalse(handler.debtLegBroken(), "ghost INK-8 debt tripped");
    assertFalse(handler.underlyingLegBroken(), "ghost INK-8 underlying tripped");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INVARIANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice INK-1: the facility is a pure pass-through: zero underlying, wrapper, debt asset
  ///         and PM shares after every action and now.
  function invariant_facilityHoldsNothing() public view {
    assertFalse(handler.facilityHeldTokens(), "INK-1: facility held tokens after an op");
    _assertFacilityClean();
  }

  /// @notice INK-2: the facility never keeps allowances it granted: approvals around the
  ///         wrapper and PM calls are exact and reset within the same op.
  function invariant_facilityGrantsNoAllowances() public view {
    assertFalse(handler.facilityHeldAllowance(), "INK-2: facility held an allowance after an op");
    _assertNoAllowances();
  }

  /// @notice INK-3: the ABSOLUTE capacity, security and exit words and every tracked user's
  ///         auth equal an exact ghost mirror of every consume (entry: capacity, then auth,
  ///         then security; exit: exit cap), reset by re-arms; none exceeds MAX_ABSOLUTE.
  function invariant_absoluteCapMirrorsExact() public view {
    assertFalse(handler.capMirrorBroken(), "INK-3: a word or auth diverged from its ghost after an op");
    uint256 capacity = facility.getEntry(address(positionManager)).capacityCap;
    uint256 exitCap = facility.getExit(address(positionManager)).cap;
    uint256 security = facility.getSecurityCap(address(underlyingToken), address(debtToken));
    assertEq(capacity >> LibCaps.TYPE_OFFSET, 0, "INK-3: capacity word not ABSOLUTE");
    assertEq(exitCap >> LibCaps.TYPE_OFFSET, 0, "INK-3: exit word not ABSOLUTE");
    assertEq(security >> LibCaps.TYPE_OFFSET, 0, "INK-3: security word not ABSOLUTE");
    assertEq(capacity, handler.ghostCapacity(), "INK-3: capacity word != ghost");
    assertEq(exitCap, handler.ghostExit(), "INK-3: exit word != ghost");
    assertEq(security, handler.ghostSecurity(), "INK-3: security word != ghost");
    assertLe(capacity, LibCaps.MAX_ABSOLUTE, "INK-3: capacity above MAX_ABSOLUTE");
    assertLe(exitCap, LibCaps.MAX_ABSOLUTE, "INK-3: exit cap above MAX_ABSOLUTE");
    assertLe(security, LibCaps.MAX_ABSOLUTE, "INK-3: security cap above MAX_ABSOLUTE");

    address[] memory trackedUsers = handler.getUsers();
    for (uint256 u = 0; u < trackedUsers.length; u++) {
      Auth memory auth = facility.getAuth(address(underlyingToken), address(debtToken), trackedUsers[u]);
      Auth memory ghost = handler.ghostAuth(trackedUsers[u]);
      assertEq(auth.amount, ghost.amount, "INK-3: auth amount != ghost");
      assertEq(auth.expiry, ghost.expiry, "INK-3: auth expiry != ghost");
    }
  }

  /// @notice INK-4: the ABSOLUTE words and the auth amounts only decrease between re-arms
  ///         (nothing ever releases into them).
  function invariant_capsOnlyDecreaseBetweenRearms() public view {
    assertFalse(handler.absoluteCapIncreased(), "INK-4: a word or auth increased without a re-arm");
    assertLe(
      facility.getEntry(address(positionManager)).capacityCap,
      handler.trackedCapacity(),
      "INK-4: capacity above last tracked value"
    );
    assertLe(facility.getExit(address(positionManager)).cap, handler.trackedExit(), "INK-4: exit cap above tracked");
    assertLe(
      facility.getSecurityCap(address(underlyingToken), address(debtToken)),
      handler.trackedSecurity(),
      "INK-4: security above tracked"
    );
    address[] memory trackedUsers = handler.getUsers();
    for (uint256 u = 0; u < trackedUsers.length; u++) {
      assertLe(
        facility.getAuth(address(underlyingToken), address(debtToken), trackedUsers[u]).amount,
        handler.trackedAuth(trackedUsers[u]),
        "INK-4: auth above tracked"
      );
    }
  }

  /// @notice INK-5: `previewEnter` quotes the exact debt and `previewExit` the exact debtIn,
  ///         underlyingOut and feeShares of the flow that follows in the same block, and both
  ///         revert on exactly the gates the flows revert on (offer, pause, bad debt, unlevered
  ///         pool, nothing to burn).
  function invariant_previewsMatchExecution() public view {
    assertFalse(handler.previewDesync(), "INK-5: a preview disagreed with the flow it previews");
  }

  /// @notice INK-6: an entry of exactly `maxEnter(pm, user)` never fails on a cap, and an exit
  ///         of exactly `maxExit(pm)` never fails on the exit cap (other reverts, such as the
  ///         PM's LTV gate or Morpho liquidity, are not the quote's business).
  function invariant_maxEnterNeverLies() public view {
    assertFalse(handler.maxEnterLied(), "INK-6: maxEnter quoted an amount the caps refused");
    assertFalse(handler.maxExitLied(), "INK-6: maxExit quoted an amount the cap refused");
  }

  /// @notice INK-7: the fee recipient's PM share delta is exactly `ceil(minted * fee / BPS)`
  ///         on entry (the receiver getting the rest) and `ceil(shares * fee / BPS)` on exit
  ///         (the caller losing exactly `shares`).
  function invariant_feeSharesExact() public view {
    assertFalse(handler.feeMirrorBroken(), "INK-7: fee shares diverged from the rounded-up fee");
  }

  /// @notice INK-8: the debt leg is exact (receiver delta == returned debt on entry, caller
  ///         delta == -debtIn on exit) and so is the underlying leg (caller pays `amount`,
  ///         receiver gets `underlyingOut`).
  function invariant_debtLegExact() public view {
    assertFalse(handler.debtLegBroken(), "INK-8: a debt leg was not exact");
    assertFalse(handler.underlyingLegBroken(), "INK-8: an underlying leg was not exact");
  }

  /// @notice INK-9: solvency echo. PM supply equals the sum of the tracked holders' balances
  ///         (users, seeder, fee recipient, PM fee recipient, facility), burn's share
  ///         denominator is nonzero, and the PM aggregate views stay callable and consistent
  ///         (single module: equity == quoted collateral - debt unless it is bad debt, in which
  ///         case the module is excluded and quoted collateral < debt).
  function invariant_solvencyViewsHold() public view {
    address[] memory trackedUsers = handler.getUsers();
    uint256 sumBalances;
    for (uint256 u = 0; u < trackedUsers.length; u++) {
      sumBalances += positionManager.balanceOf(trackedUsers[u]);
    }
    sumBalances += positionManager.balanceOf(seeder);
    sumBalances += positionManager.balanceOf(feeRecipient);
    sumBalances += positionManager.balanceOf(pmFeeRecipient);
    sumBalances += positionManager.balanceOf(address(facility));
    assertEq(positionManager.totalSupply(), sumBalances, "INK-9: totalSupply != sum of tracked balances");

    (, uint256 totalSupply_, uint256 mgmtFeeShares, uint256 perfFeeShares) = positionManager.pendingFees();
    assertEq(totalSupply_, positionManager.totalSupply(), "INK-9: pendingFees supply != totalSupply");
    assertGt(
      totalSupply_ + mgmtFeeShares + perfFeeShares + positionManager.virtualShareOffset(),
      0,
      "INK-9: zero share denominator"
    );

    uint256 quoted = positionManager.collateralAmountQuoted();
    uint256 debt = positionManager.debtAmount();
    uint256 equity = positionManager.totalAssets();
    positionManager.collateralAmount();
    if (positionManager.hasBadDebt()) {
      assertLt(quoted, debt, "INK-9: bad debt flagged with collateral covering debt");
      assertEq(equity, 0, "INK-9: bad-debt module still counted in equity");
    } else {
      assertGe(quoted, debt, "INK-9: no bad debt flagged with debt above collateral");
      assertEq(equity, quoted - debt, "INK-9: equity != quoted collateral - debt");
    }
  }

  /// @notice Logs the handler's coverage counters (never fails): entries and exits that went
  ///         through, cap / gate / other rejections, probes, re-arms, pauses and bad-debt states.
  function invariant_callSummary() public view {
    console2.log("--- InKindFacility handler call summary ---");
    console2.log("enter: ok / cap / gate / other", handler.enterSuccesses(), handler.enterCapFailures());
    console2.log("  (gate / other)", handler.enterGateFailures(), handler.enterOtherFailures());
    console2.log(
      "exit: ok / cap / gate", handler.exitSuccesses(), handler.exitCapFailures(), handler.exitGateFailures()
    );
    console2.log("  (other / noop)", handler.exitOtherFailures(), handler.exitNoops());
    console2.log("probes: maxEnter / maxExit", handler.maxEnterProbes(), handler.maxExitProbes());
    console2.log("seed: ok / failed", handler.seedSuccesses(), handler.seedFailures());
    console2.log(
      "rearms: entry / exit / security", handler.entryRearms(), handler.exitRearms(), handler.securityRearms()
    );
    console2.log(
      "rearms: auth, pauses, bad-debt states", handler.authRearms(), handler.pauses(), handler.badDebtObserved()
    );
  }
}
