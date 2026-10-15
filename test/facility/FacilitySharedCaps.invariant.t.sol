// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {console2} from "forge-std/console2.sol";

import {FacilityBaseTest} from "./FacilityBase.t.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {
  FacilitySharedCapsHandler,
  KIND_ABSOLUTE,
  KIND_A,
  KIND_BC,
  KIND_C,
  KIND_D_POS,
  KIND_D_NEG,
  KIND_DYN_POS,
  KIND_DYN_NEG,
  GROUP_A,
  GROUP_BC,
  GROUP_COUNT,
  POOL_A,
  POOL_B,
  POOL_C,
  POOL_D,
  DYN_ID
} from "test/mock/facility/FacilitySharedCapsHandler.sol";

/// @title FacilitySharedCapsInvariantTest
/// @notice Invariants of Facility intents on EXTERNAL deposit cap words (FacilityAbsoluteCaps
///         pools and a FacilityDynamicCaps id) next to ABSOLUTE words.
contract FacilitySharedCapsInvariantTest is FacilityBaseTest {
  using LibClone for address;

  FacilityAbsoluteCaps public absoluteCaps;
  FacilityDynamicCaps public dynamicCaps;
  FacilitySharedCapsHandler public handler;

  uint128 constant POOL_A_CAP = 1_000_000e18;
  uint128 constant POOL_B_CAP = 300_000e18;
  uint128 constant POOL_C_CAP = 700_000e18;
  uint128 constant POOL_D_CAP = 150_000e18;
  uint128 constant POOL_D_HARD_CAP = 300_000e18;
  uint128 constant RECOVERY = 1_000_000e18;
  uint64 constant RECOVERY_TIME = 1 days;

  // Multiplier seeds (FacilitySharedCapsHandler._newWord): 7 mod 8 = max, even = integer x2, odd = raw x2 + 1
  uint256 constant MULT_1X = 2;
  uint256 constant MULT_9X = 18;
  uint256 constant MULT_1_5X = 12_289;
  uint256 constant MULT_MAX = 7;
  uint256 constant ABSOLUTE_WORD = 1_000_000e18 + 1;
  // amount seed % 8 == 3: a plain bounded amount, 10_000e18 + 3
  uint256 constant DEPOSIT_SEED = 10_000e18 + 3;
  // amount seed % 8 == 3, 225_000e18 + 4 at 1.5x: past POOL_D's headroom
  uint256 constant PAST_HEADROOM_SEED = 150_000e18 + 3;
  // amount seed % 8 == 1: the available amount
  uint256 constant AVAILABLE_SEED = 1;

  function setUp() public override {
    super.setUp();
    // past one recovery period, so a zero origin is fully recovered
    vm.warp(30 days);

    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory consumers = new address[](1);
    consumers[0] = address(facility);
    absoluteCaps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    absoluteCaps.initialize(owner, managers, consumers);
    dynamicCaps = FacilityDynamicCaps(address(new FacilityDynamicCaps()).clone());
    dynamicCaps.initialize(owner, managers, consumers);

    vm.startPrank(owner);
    capsWhitelist.setAllowed(address(absoluteCaps), true);
    capsWhitelist.setAllowed(address(dynamicCaps), true);
    absoluteCaps.setCap(POOL_A, POOL_A_CAP, POOL_A_CAP);
    absoluteCaps.setCap(POOL_B, POOL_B_CAP, POOL_B_CAP);
    absoluteCaps.setCap(POOL_C, POOL_C_CAP, POOL_C_CAP);
    absoluteCaps.setCap(POOL_D, POOL_D_CAP, POOL_D_HARD_CAP);
    dynamicCaps.setCap(DYN_ID, RECOVERY, RECOVERY_TIME, 0);
    vm.stopPrank();

    handler = new FacilitySharedCapsHandler(
      facility, absoluteCaps, dynamicCaps, debtToken, address(positionManager), facilitator, pauser
    );
    vm.label(address(handler), "FacilitySharedCapsHandler");

    // one intent per kind, ids 1 to 8 in kind order
    handler.act_createIntent(KIND_ABSOLUTE, 0, ABSOLUTE_WORD, 30 days);
    handler.act_createIntent(KIND_A, MULT_1X, 0, 30 days);
    handler.act_createIntent(KIND_BC, MULT_1_5X, 0, 30 days);
    handler.act_createIntent(KIND_C, MULT_9X, 0, 30 days);
    handler.act_createIntent(KIND_D_POS, MULT_1X, 0, 30 days);
    handler.act_createIntent(KIND_D_NEG, MULT_1_5X, 0, 30 days);
    handler.act_createIntent(KIND_DYN_POS, MULT_1_5X, 0, 30 days);
    handler.act_createIntent(KIND_DYN_NEG, MULT_1X, 0, 30 days);

    // repeated selectors weight the fuzzer towards the flows
    bytes4[] memory selectors = new bytes4[](11);
    selectors[0] = FacilitySharedCapsHandler.act_createIntent.selector;
    selectors[1] = FacilitySharedCapsHandler.act_deposit.selector;
    selectors[2] = FacilitySharedCapsHandler.act_deposit.selector;
    selectors[3] = FacilitySharedCapsHandler.act_deposit.selector;
    selectors[4] = FacilitySharedCapsHandler.act_withdraw.selector;
    selectors[5] = FacilitySharedCapsHandler.act_withdraw.selector;
    selectors[6] = FacilitySharedCapsHandler.act_revertDeposit.selector;
    selectors[7] = FacilitySharedCapsHandler.act_lock.selector;
    selectors[8] = FacilitySharedCapsHandler.act_setDepositCap.selector;
    selectors[9] = FacilitySharedCapsHandler.act_setDepositCap.selector;
    selectors[10] = FacilitySharedCapsHandler.act_warp.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       HANDLER SMOKE                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_handlerActionsSucceed() public {
    for (uint256 kind = 0; kind < 8; kind++) {
      handler.act_deposit(kind, kind, DEPOSIT_SEED);
    }
    assertEq(handler.depositSuccesses(), 8, "one deposit per kind");
    assertEq(handler.dynamicConsumptions(), 1, "only the positive dynamic deposit consumes");

    // C at 9x: the quoted amount fits exactly, one more unit does not
    handler.act_deposit(KIND_C, 0, 1);
    handler.act_deposit(KIND_C, 0, 2);
    assertEq(handler.depositSuccesses(), 9, "available-sized deposit");
    assertEq(handler.depositCapFailures(), 1, "available + 1 deposit");

    handler.act_withdraw(KIND_A, 1, 1_000e18 + 1);
    assertEq(handler.withdrawSuccesses(), 1, "partial withdraw");
    handler.act_revertDeposit(KIND_BC, 2);
    assertEq(handler.revertsWhileDepositing(), 1, "revertDeposit while depositing");

    // intents with supply: ABSOLUTE, A, C, D_POS, ...
    handler.act_lock(3);
    assertEq(handler.locks(), 1, "lock");
    handler.act_revertDeposit(3, 1);
    assertEq(handler.revertsWhileResolving(), 1, "revertDeposit while resolving");

    // documented switch on A: zero word, shares exit, then the new word
    handler.act_setDepositCap(KIND_A, 0, 0, 0);
    assertEq(handler.wordsClosed(), 1, "close with a zero word");
    handler.act_withdraw(1, 1, 0);
    assertEq(handler.withdrawSuccesses(), 2, "exit under the zero word");
    handler.act_setDepositCap(KIND_A, KIND_BC, MULT_1_5X, 0);
    assertEq(handler.wordsSwitched(), 1, "new word at zero supply");
    handler.act_deposit(KIND_A, 0, DEPOSIT_SEED);
    assertEq(handler.depositSuccesses(), 10, "deposit under the new word");

    // ABSOLUTE word cut below the supply blocks deposits
    handler.act_setDepositCap(KIND_ABSOLUTE, 0, 0, 1);
    assertEq(handler.absoluteWordsSet(), 1, "ABSOLUTE word below supply");
    handler.act_deposit(KIND_ABSOLUTE, 0, DEPOSIT_SEED);
    assertEq(handler.depositCapFailures(), 2, "deposit above the ABSOLUTE word");

    // depositing intents with supply: ABSOLUTE, A, C, D_NEG, DYN_POS, DYN_NEG
    handler.act_withdraw(5, 7, 0);
    assertEq(handler.dynamicConsumptions(), 2, "negative dynamic withdrawal consumes");

    // id 9 on DYN_ID at -max: free deposit, then a withdrawal above the remaining capacity
    handler.act_createIntent(KIND_DYN_NEG, MULT_MAX, 0, 30 days);
    handler.act_deposit(7, 0, DEPOSIT_SEED);
    assertEq(handler.depositSuccesses(), 11, "deposit on the negative dynamic word");
    handler.act_withdraw(5, 0, 1_000e18 + 1);
    assertEq(handler.releaseCapFailures(), 1, "negative dynamic withdrawal above the cap");

    handler.act_warp(1 days);
    handler.act_createIntent(KIND_D_NEG, MULT_1X, 0, 1 days);
    assertEq(handler.intentsCreated(), 10, "intent created by the action");

    invariant_poolCapWithinHardCap();
    invariant_positiveGroupsTrackSupply();
    invariant_poolsMatchGhost();
    invariant_dynamicCapOnlyConsumed();
    invariant_flowsMatchCapMath();
    invariant_wordsOnlySetByFacilitator();
  }

  /// @dev D_NEG deposits credit POOL_D up to its hard cap, then D_POS releases revert with
  ///      HardCapExceeded until the credit is consumed back or the manager calls setCap.
  function test_withdraw_sharedPoolAtHardCapReverts() public {
    // ids 5 (D_POS) and 6 (D_NEG at 1.5x) are the 5th and 6th depositing intents
    handler.act_deposit(4, 0, DEPOSIT_SEED);
    handler.act_deposit(5, 1, PAST_HEADROOM_SEED);
    assertEq(handler.depositCapFailures(), 1, "negative deposit past the headroom");
    handler.act_deposit(5, 1, AVAILABLE_SEED);
    assertEq(handler.depositSuccesses(), 2, "negative deposit up to the hard cap");

    // intents with supply: D_POS, D_NEG
    handler.act_withdraw(0, 0, 0);
    handler.act_revertDeposit(0, 0);
    assertEq(handler.releaseCapFailures(), 2, "D_POS releases past the headroom");

    vm.prank(owner);
    absoluteCaps.adjustCap(POOL_D, int256(uint256(POOL_D_HARD_CAP)));
    handler.act_withdraw(0, 0, 0);
    assertEq(handler.releaseCapFailures(), 3, "adjustCap keeps the headroom");
    assertEq(handler.creditFailures(), 4, "every credit failure is HardCapExceeded");

    uint256 snapshot = vm.snapshotState();
    (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(POOL_D);
    vm.prank(owner);
    absoluteCaps.setCap(POOL_D, cap, hardCap + uint128(DEPOSIT_SEED));
    handler.act_withdraw(0, 0, 0);
    assertEq(handler.withdrawSuccesses(), 1, "setCap unblocks the release");
    invariant_flowsMatchCapMath();
    vm.revertToState(snapshot);

    handler.act_withdraw(1, 1, 0);
    handler.act_withdraw(0, 0, 0);
    assertEq(handler.withdrawSuccesses(), 2, "D_NEG exit frees the headroom for D_POS");

    invariant_poolCapWithinHardCap();
    invariant_poolsMatchGhost();
    invariant_flowsMatchCapMath();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INVARIANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice CAP-1: every pool keeps cap <= hardCap.
  function invariant_poolCapWithinHardCap() public view {
    for (uint16 pool = POOL_A; pool <= POOL_D; pool++) {
      (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(pool);
      assertLe(cap, hardCap, "CAP-1: cap above hardCap");
    }
  }

  /// @notice CAP-2: in a group only positive multipliers use, hardCap - cap beyond the group
  ///         base is the bound intents' totalSupply x multiplier within ceil/floor dust (exact
  ///         for integer multipliers).
  function invariant_positiveGroupsTrackSupply() public view {
    _assertTracksSupply(GROUP_A);
    _assertTracksSupply(GROUP_BC);
  }

  /// @notice CAP-3: every flow moves its exact charge (ceil to consume, floor to credit)
  ///         through its pools from id1, each up to its cap or headroom, and leaves the other
  ///         pools as they were, so in every group hardCap - cap is the base plus the mirrored
  ///         charges.
  function invariant_poolsMatchGhost() public view {
    assertFalse(handler.poolsMismatch(), "CAP-3: a flow moved pools off its charge");
    for (uint256 group = 0; group < GROUP_COUNT; group++) {
      assertEq(int256(handler.groupHeadroom(group)), handler.groupGhost(group), "CAP-3: pools != mirrored charges");
    }
  }

  /// @notice CAP-4: the dynamic cap only moves on consumption, by the charge plus at most one
  ///         second of recovery, and recovers at recovery / recoveryTime.
  function invariant_dynamicCapOnlyConsumed() public view {
    assertFalse(handler.dynamicCapMismatch(), "CAP-4: dynamic cap moved off its consumptions");
    (uint256 lo, uint256 hi) = handler.dynamicBounds();
    uint256 remaining = dynamicCaps.remaining(DYN_ID);
    assertGe(remaining, lo, "CAP-4: dynamic cap below its recovery line");
    assertLe(remaining, hi, "CAP-4: dynamic cap above its recovery line");
  }

  /// @notice CAP-5: a flow whose cap has room never reverts; a flow without room reverts with
  ///         the exact cap error (HardCapExceeded for a credit the pools cannot absorb) and
  ///         moves no pool; facilitator calls never revert.
  function invariant_flowsMatchCapMath() public view {
    assertFalse(handler.flowRevertedWithRoom(), "CAP-5: flow reverted with room");
    assertFalse(handler.capErrorMismatch(), "CAP-5: flow without room did not revert with the cap error");
    assertFalse(handler.facilitatorCallReverted(), "CAP-5: facilitator call reverted");
  }

  /// @notice CAP-6: flows never write the word: it is what createIntent or setDepositCap set.
  function invariant_wordsOnlySetByFacilitator() public view {
    uint256[] memory ids = handler.getIntentIds();
    for (uint256 i = 0; i < ids.length; i++) {
      (IntentProperties memory props,,,) = facility.getIntent(ids[i]);
      assertEq(props.depositCap, handler.ghostOf(ids[i]).word, "CAP-6: word changed outside the facilitator");
    }
  }

  function invariant_callSummary() public view {
    console2.log("--- FacilitySharedCaps handler call summary ---");
    console2.log("intents created", handler.intentsCreated());
    console2.log("deposit: ok / cap failure", handler.depositSuccesses(), handler.depositCapFailures());
    console2.log("withdraw ok / release cap failures", handler.withdrawSuccesses(), handler.releaseCapFailures());
    console2.log(
      "revertDeposit: depositing / resolving", handler.revertsWhileDepositing(), handler.revertsWhileResolving()
    );
    console2.log("credit failures", handler.creditFailures());
    console2.log("dynamic consumptions", handler.dynamicConsumptions());
    console2.log(
      "words: closed / switched / ABSOLUTE re-set",
      handler.wordsClosed(),
      handler.wordsSwitched(),
      handler.absoluteWordsSet()
    );
    console2.log("locks / warps", handler.locks(), handler.warps());
  }

  function _assertTracksSupply(uint256 group) internal view {
    (uint256 lo, uint256 hi) = handler.supplyBounds(group);
    int256 outstanding = int256(handler.groupHeadroom(group)) - handler.groupBase(group);
    assertGe(outstanding, int256(lo), "CAP-2: pool consumption below supply x multiplier");
    assertLe(outstanding, int256(hi), "CAP-2: pool consumption above supply x multiplier plus dust");
  }
}
