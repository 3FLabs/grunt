// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {console2} from "forge-std/console2.sol";

import {InKindFacilityBaseTest} from "./InKindFacilityBase.t.sol";
import {Auth} from "src/interfaces/facility/IInKindFacility.sol";
import {PositionManager} from "src/manager/PositionManager.sol";
import {InKindExternalCapsHandler} from "test/mock/facility/InKindExternalCapsHandler.sol";
import {ApproveExactExiter, RepayOnBehalfExiter} from "test/mock/facility/InKindExiters.sol";

/// @title InKindFacilityExternalCapsInvariantTest
/// @notice In-kind invariants on EXTERNAL cap words over two PMs sharing one underlying: entry
///         words on FacilityAbsoluteCaps pools, a FacilityDynamicCaps security word shared by both
///         PMs with auth spill-over, signed exit words (PM1 starts on the entry +1x / exit -1x
///         netting, whose credits revert HardCapExceeded past the pools' headroom), exits with
///         and without a callback, and entries refused above the PM target LTV.
contract InKindFacilityExternalCapsInvariantTest is InKindFacilityBaseTest {
  InKindExternalCapsHandler public handler;
  ApproveExactExiter[2] internal exactExiters;
  RepayOnBehalfExiter[2] internal repayExiters;

  uint16 constant POOL_1 = 1;
  uint16 constant POOL_2 = 2;
  uint16 constant SHARED_POOL = 3;
  uint16 constant EXIT_POOL = 4;
  uint64 constant SECURITY_DYN = 1;
  uint64 constant EXIT_DYN = 2;
  int24 constant MULT_FRACTIONAL = 5001;

  uint128 constant OWN_POOL_CAP = 15_000e6;
  uint128 constant SHARED_POOL_CAP = 20_000e6;
  uint128 constant EXIT_POOL_CAP = 3_000e6;
  uint128 constant SECURITY_RECOVERY = 25_000e6;
  uint128 constant EXIT_RECOVERY = 3_000e6;
  uint256 constant PM2_EXIT_CAP = 2_000e6;
  uint128 constant INITIAL_AUTH = 5_000e6;
  uint256 constant INITIAL_ENTRY = 500e18;

  function setUp() public override {
    super.setUp();

    // C/D = 2e12 on PM1, non-integer on PM2
    _seedPool(positionManager, SEED_COLLATERAL, SEED_DEBT);
    _seedPool(positionManager2, 8_000e18, 3_100e6);
    vm.startPrank(owner);
    positionManager.setFeeData(pmFeeRecipient, 100, 1_000);
    positionManager2.setFeeData(pmFeeRecipient, 100, 1_000);
    absoluteCaps.setCap(POOL_1, _caps(OWN_POOL_CAP), _caps(OWN_POOL_CAP));
    absoluteCaps.setCap(POOL_2, _caps(OWN_POOL_CAP), _caps(OWN_POOL_CAP));
    absoluteCaps.setCap(SHARED_POOL, _caps(SHARED_POOL_CAP), _caps(SHARED_POOL_CAP));
    absoluteCaps.setCap(EXIT_POOL, _caps(EXIT_POOL_CAP), _caps(EXIT_POOL_CAP));
    dynamicCaps.setCap(SECURITY_DYN, _caps(SECURITY_RECOVERY), 1 days, uint64(block.timestamp - 1 days));
    dynamicCaps.setCap(EXIT_DYN, _caps(EXIT_RECOVERY), 1 days, uint64(block.timestamp - 1 days));
    vm.stopPrank();

    InKindExternalCapsHandler.Word[2] memory entryWords;
    entryWords[0] = InKindExternalCapsHandler.Word(address(absoluteCaps), _pair(POOL_1, SHARED_POOL), MULT_1X);
    entryWords[1] = InKindExternalCapsHandler.Word(address(absoluteCaps), _pair(POOL_2, SHARED_POOL), MULT_FRACTIONAL);
    InKindExternalCapsHandler.Word[2] memory exitWords;
    exitWords[0] = InKindExternalCapsHandler.Word(address(absoluteCaps), _pair(POOL_1, SHARED_POOL), -MULT_1X);
    InKindExternalCapsHandler.Word memory securityWord =
      InKindExternalCapsHandler.Word(address(dynamicCaps), SECURITY_DYN, MULT_1X);
    _setEntry(positionManager, _encode(entryWords[0]), FAR_EXPIRY, 25);
    _setEntry(positionManager2, _encode(entryWords[1]), FAR_EXPIRY, 25);
    _setExit(positionManager, _encode(exitWords[0]), FAR_EXPIRY, 25);
    _setExit(positionManager2, PM2_EXIT_CAP, FAR_EXPIRY, 25);
    _setSecurityCap(_encode(securityWord));

    handler = new InKindExternalCapsHandler();
    _setAuth(handler.users(0), INITIAL_AUTH, uint40(block.timestamp + 30 days));
    PositionManager[2] memory pms = [positionManager, positionManager2];
    for (uint256 i = 0; i < 2; i++) {
      address module = i == 0 ? address(borrowPosition) : address(borrowPosition2);
      exactExiters[i] = new ApproveExactExiter(facility, pms[i], debtToken);
      repayExiters[i] = new RepayOnBehalfExiter(facility, pms[i], debtToken, morpho, marketParams, module);
      // every actor starts with shares so exits run from the first call
      _enter(pms[i], handler.users(0), INITIAL_ENTRY, handler.users(0));
      _enter(pms[i], handler.users(1), INITIAL_ENTRY, handler.users(1));
      _enter(pms[i], handler.users(2), INITIAL_ENTRY, handler.users(2));
      _enter(pms[i], handler.users(0), INITIAL_ENTRY, address(exactExiters[i]));
      _enter(pms[i], handler.users(1), INITIAL_ENTRY, address(repayExiters[i]));
    }

    handler.initialize(
      InKindExternalCapsHandler.Config({
        facility: facility,
        pm1: positionManager,
        pm2: positionManager2,
        absoluteCaps: absoluteCaps,
        dynamicCaps: dynamicCaps,
        underlyingToken: underlyingToken,
        debtToken: debtToken,
        oracle: oracle,
        morpho: morpho,
        marketParams: marketParams,
        facilitator: facilitator,
        operator: operator,
        capsManager: owner,
        exactExiters: exactExiters,
        repayExiters: repayExiters,
        entryWords: entryWords,
        exitWords: exitWords,
        securityWord: securityWord
      })
    );

    bytes4[] memory selectors = new bytes4[](4);
    selectors[0] = InKindExternalCapsHandler.act_enter.selector;
    selectors[1] = InKindExternalCapsHandler.act_exit.selector;
    selectors[2] = InKindExternalCapsHandler.act_warp.selector;
    selectors[3] = InKindExternalCapsHandler.act_admin.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    targetContract(address(handler));
  }

  function _pair(uint16 first, uint16 second) internal pure returns (uint64) {
    return uint64(first) | (uint64(second) << 16);
  }

  function _encode(InKindExternalCapsHandler.Word memory word) internal pure returns (uint256) {
    return _externalWord(word.caps, word.id, word.multiplier);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       HANDLER SMOKE                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_handlerLanesSucceed() public {
    // auth spill-over into the shared dynamic security cap
    handler.act_admin(2, 0, 100e6, 1);
    handler.act_enter(0, 0, 1_000e18, 0, 0);
    assertEq(handler.enterSuccesses(), 1, "plain entry");
    assertEq(handler.spillOvers(), 1, "spill-over entry");

    // entry bounds: exact debt, each off-by-one, dry-run shares exact and plus one
    handler.act_enter(0, 1, 1_000e18, 1, 8);
    handler.act_enter(1, 1, 1_000e18, 3, 10);
    handler.act_enter(1, 1, 1_000e18, 3, 11);
    handler.act_enter(1, 1, 1_000e18, 3, 12);
    handler.act_enter(1, 2, 1_000e18, 4, 13);
    handler.act_enter(0, 2, 1_000e18, 2, 15);
    assertEq(handler.enterBoundedSuccesses(), 2, "bounded entries");
    assertEq(handler.enterSlippageReverts(), 4, "off-by-one entries");

    // a dust amount reverts like its preview
    handler.act_enter(0, 0, 1, 0, 3 << 4);
    assertEq(handler.enterDustFailures(), 1, "dust entry");

    // maxEnter on PM2 drains the security cap, a day restores it
    handler.act_enter(1, 1, 0, 1, 6);
    assertEq(handler.maxEnterProbeSuccesses(), 1, "maxEnter-sized entry");
    handler.act_enter(1, 2, 1_000e18, 2, 0);
    assertEq(handler.enterCapFailures(), 1, "drained security cap");
    handler.act_warp(1 days);
    handler.act_enter(1, 2, 1_000e18, 2, 0);
    assertEq(handler.enterSuccesses(), 5, "entry after recovery");

    // exits: plain, exact bounds, each off-by-one, ApproveExact with and without callback, repay
    handler.act_exit(0, 0, 100e18, 0, 0);
    handler.act_exit(0, 1, 100e18, 1, 10);
    handler.act_exit(0, 2, 100e18, 2, 12);
    handler.act_exit(0, 2, 100e18, 2, 13);
    handler.act_exit(0, 3, 100e18, 0, 16);
    handler.act_exit(1, 3, 100e18, 0, 0);
    handler.act_exit(1, 4, 100e18, 0, 32 * 50e6);
    assertEq(handler.exitSuccesses(), 5, "exits");
    assertEq(handler.exitBoundedSuccesses(), 1, "bounded exit");
    assertEq(handler.exitSlippageReverts(), 2, "off-by-one exits");
    assertEq(handler.exitCallbackSuccesses(), 2, "callback exits");
    assertEq(handler.exitRepaySuccesses(), 1, "repay-on-behalf exit");
    assertEq(handler.exitSuccessesByWord(0), 2, "ABSOLUTE exit word");
    assertEq(handler.exitSuccessesByWord(3), 3, "netting exit word");

    // one dust share is all fee: the exit reverts like its preview
    handler.act_exit(0, 7 << 8, 1, 0, 0);
    assertEq(handler.exitGateFailures(), 1, "dust exit");

    // maxExit under a tight ABSOLUTE word, which then refuses more, then the dynamic exit word
    handler.act_admin(1, 0, 6 * 100e6, 0);
    handler.act_exit(0, 0, 1, 0, 7);
    assertEq(handler.maxExitProbeSuccesses(), 1, "maxExit-sized exit");
    handler.act_exit(0, 1, 100e18, 0, 0);
    assertEq(handler.exitCapFailures(), 1, "drained exit word");
    handler.act_admin(1, 1, 2, 0);
    handler.act_exit(1, 0, 100e18, 0, 0);
    assertEq(handler.exitSuccessesByWord(2), 1, "dynamic exit word");

    // the exit pool consumed, then credited back; a dynamic cap ignores a credit
    handler.act_admin(1, 0, 1, 0);
    handler.act_exit(0, 0, 100e18, 0, 0);
    assertEq(handler.exitSuccessesByWord(1), 1, "exit pool word");
    handler.act_admin(1, 1, 10, 0);
    handler.act_exit(1, 0, 100e18, 0, 0);
    assertEq(handler.exitSuccessesByWord(3), 4, "exit pool credit");
    handler.act_admin(1, 1, 5, 0);
    handler.act_exit(1, 1, 100e18, 0, 0);
    assertEq(handler.exitSuccessesByWord(4), 1, "dynamic credit");

    // admin: entry word re-arm, pool top-up, hard-cap raise, oracle, security word, interest
    handler.act_admin(0, 1, 4, 100);
    handler.act_admin(3, 2, 1_000e6, 0);
    handler.act_admin(6, 2, 1_000e6, 0);
    handler.act_admin(4, 1.2e24, 0, 0);
    handler.act_admin(5, 1, 0, 0);
    handler.act_warp(1 hours + 1);
    handler.act_enter(1, 0, 1_000e18, 0, 0);
    handler.act_exit(1, 0, 100e18, 0, 0);
    assertEq(handler.entryRearms(), 1, "entry re-arm");
    assertEq(handler.exitRearms(), 5, "exit re-arms");
    assertEq(handler.authRearms(), 1, "auth re-arm");
    assertEq(handler.warps(), 2, "warps");
    assertEq(handler.refills(), 1, "pool top-up");
    assertEq(handler.hardCapRaises(), 1, "hard-cap raise");
    assertEq(handler.priceMoves(), 1, "oracle move");
    assertEq(handler.aboveTargetMoves(), 0, "oracle below the target LTV");
    assertEq(handler.securityRearms(), 1, "security re-arm");
    assertEq(handler.enterSuccesses(), 6, "entry under the re-armed words");
    assertEq(handler.exitSuccesses(), 11, "exit after the moves");

    _assertAllInvariants();
  }

  function test_handlerCreditsRevertPastTheHardCap() public {
    // PM1 entries take the shared pool first
    handler.act_admin(0, 0, 1, 0);
    handler.act_enter(0, 1, 1_000e18, 1, 0);
    assertEq(handler.enterSuccesses(), 1, "entry into the shared pool");

    // PM2 exits credit the shared pool alone, past what PM1 consumed there
    handler.act_admin(1, 1, 4, 0);
    for (uint256 slot = 0; slot < 3; slot++) {
      _exitAll(1, slot);
    }
    assertEq(handler.exitSuccessesByWord(3), 2, "credits within the headroom");
    assertEq(handler.exitHardCapFailures(), 1, "credit past the shared pool's hard cap");

    // PM1's netting credits then overflow its pools
    _exitAll(0, 0);
    _exitAll(0, 2);
    _exitAll(0, 3);
    _exitAll(0, 1);
    assertEq(handler.exitSuccessesByWord(3), 5, "netting credits within the headroom");
    assertEq(handler.exitHardCapFailures(), 2, "netting credit past the hard caps");

    // a top-up keeps the headroom, a hard-cap raise adds it
    handler.act_admin(3, 2, 1_000e6, 0);
    _exitAll(0, 1);
    assertEq(handler.exitHardCapFailures(), 3, "top-up does not unblock");
    handler.act_admin(6, 2, 1_000e6, 0);
    _exitAll(0, 1);
    assertEq(handler.exitSuccessesByWord(3), 6, "hard-cap raise unblocks");
    assertEq(handler.exitHardCapFailures(), 3, "no further hard-cap revert");

    _assertAllInvariants();
  }

  function test_handlerEntriesRefusedAboveTargetLtv() public {
    // drain the security cap first so an unauthed entry fails on it
    handler.act_enter(1, 1, 0, 1, 6);
    assertEq(handler.maxEnterProbeSuccesses(), 1, "maxEnter-sized entry");

    // PM1, the higher-LTV pool, lands just above its target LTV
    handler.act_admin(4, 3, 0, 0);
    assertEq(handler.aboveTargetMoves(), 1, "above-target move");
    handler.act_enter(0, 0, 1_000e18, 0, 0);
    handler.act_enter(0, 0, 1_000e18, 0, 6);
    assertEq(handler.enterAboveTargetFailures(), 2, "refused above the target LTV");
    handler.act_enter(0, 2, 1_000e18, 2, 0);
    assertEq(handler.enterCapFailures(), 1, "caps checked before the PM");
    handler.act_enter(0, 0, 1, 0, 3 << 4);
    assertEq(handler.enterDustFailures(), 1, "dust reverts DustEntry like its preview");

    // PM2 below its target still enters, PM1 still exits
    handler.act_enter(1, 0, 1_000e18, 0, 0);
    handler.act_exit(0, 0, 100e18, 0, 0);
    assertEq(handler.enterSuccesses(), 2, "PM2 entry");
    assertEq(handler.exitSuccesses(), 1, "PM1 exit above the target");

    // interest up to LTV_CEILING resets the oracle and reopens PM1
    handler.act_admin(4, (120 << 2) | 3, 0, 0);
    for (uint256 i = 0; i < 6; i++) {
      handler.act_warp(30 days - 1);
    }
    assertEq(handler.priceResets(), 1, "oracle reset");
    handler.act_enter(0, 0, 1_000e18, 0, 0);
    assertEq(handler.enterSuccesses(), 3, "PM1 entry after the reset");
    assertEq(handler.enterAboveTargetFailures(), 2, "no refusal below the target");

    _assertAllInvariants();
  }

  /// @dev Exits the whole balance of the actor in `slot` of PM `idx`, unbounded.
  function _exitAll(uint256 idx, uint256 slot) internal {
    PositionManager pm = idx == 0 ? positionManager : positionManager2;
    address who;
    if (slot < 3) who = handler.users(slot);
    else if (slot == 3) who = address(exactExiters[idx]);
    else who = address(repayExiters[idx]);
    handler.act_exit(idx, slot, pm.balanceOf(who), 0, 0);
  }

  function _assertAllInvariants() internal view {
    invariant_stayersKeepTheirValue();
    invariant_facilityHoldsNothing();
    invariant_capsMatchTheModel();
    invariant_authsMatchTheModel();
    invariant_flowsMatchTheirPrediction();
    invariant_maxQuotesFit();
    invariant_previewsAndLegsExact();
    invariant_entriesGatedByTargetLtv();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INVARIANTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function invariant_stayersKeepTheirValue() public view {
    assertFalse(handler.stayerValueDropped(0), "PM1 stayers lost value to a flow");
    assertFalse(handler.stayerValueDropped(1), "PM2 stayers lost value to a flow");
  }

  /// @dev A debt amount in caps units.
  function _caps(uint128 debt) internal pure returns (uint128) {
    return uint128(debt * CAPS_SCALE);
  }

  function invariant_facilityHoldsNothing() public view {
    _assertFacilityClean();
    _assertNoAllowances();
    assertEq(collateralToken.allowance(address(facility), address(positionManager2)), 0, "wrapper allowance PM2");
    assertEq(debtToken.allowance(address(facility), address(positionManager2)), 0, "debt allowance PM2");
  }

  function invariant_capsMatchTheModel() public view {
    assertFalse(handler.capMirrorBroken(), "a flow consumed a cap the model could not fit");
    for (uint16 p = POOL_1; p <= EXIT_POOL; p++) {
      (uint128 cap, uint128 hardCap) = absoluteCaps.getCap(p);
      assertEq(cap, handler.ghostPoolCap(p), "pool != first-pool-first walk");
      assertEq(hardCap, handler.ghostPoolHardCap(p), "hard cap moved without a top-up");
      assertLe(cap, hardCap, "pool above its hard cap");
    }
    for (uint64 id = SECURITY_DYN; id <= EXIT_DYN; id++) {
      (,, uint64 origin) = dynamicCaps.getCap(id);
      assertEq(origin, handler.ghostOrigin(id), "dynamic origin != model");
      assertEq(dynamicCaps.remaining(id), handler.ghostRemaining(id), "dynamic capacity != model");
    }
    for (uint256 i = 0; i < 2; i++) {
      PositionManager pm = i == 0 ? positionManager : positionManager2;
      assertEq(facility.getEntry(address(pm)).capacityCap, handler.ghostEntryWord(i), "entry word != model");
      assertEq(facility.getExit(address(pm)).cap, handler.ghostExitWord(i), "exit word != model");
    }
    assertEq(facility.getSecurityCap(address(underlyingToken)), handler.ghostSecurityWord(), "security word != model");
  }

  function invariant_authsMatchTheModel() public view {
    address[] memory users = handler.getUsers();
    for (uint256 u = 0; u < users.length; u++) {
      Auth memory auth = facility.getAuth(address(underlyingToken), users[u]);
      Auth memory ghost = handler.ghostAuth(users[u]);
      assertEq(auth.amount, ghost.amount, "auth amount != model");
      assertEq(auth.expiry, ghost.expiry, "auth expiry != model");
    }
  }

  function invariant_flowsMatchTheirPrediction() public view {
    bytes memory mismatch = handler.firstMismatch();
    string memory reason = keccak256(mismatch) == keccak256("success") ? "succeeded" : vm.toString(mismatch);
    assertFalse(handler.unexpectedRevert(), string.concat("a flow predicted to pass reverted: ", reason));
    assertFalse(handler.gateParityBroken(), string.concat("a flow did not revert like its preview: ", reason));
    assertFalse(handler.slippageBroken(), string.concat("a bound was not enforced exactly: ", reason));
    assertFalse(handler.capOutcomeBroken(), string.concat("a cap revert differed from the model: ", reason));
  }

  function invariant_maxQuotesFit() public view {
    assertFalse(handler.maxEnterLied(), "a maxEnter quote does not fit the caps");
    assertFalse(handler.maxExitLied(), "a maxExit quote does not fit the exit word");
  }

  function invariant_previewsAndLegsExact() public view {
    assertFalse(handler.previewDesync(), "a preview disagreed with its flow");
    assertFalse(handler.legBroken(), "a debt, underlying or callback leg was not exact");
  }

  function invariant_entriesGatedByTargetLtv() public view {
    assertFalse(handler.targetGateBroken(), "an entry was refused below, or served above, the target LTV");
  }

  /// @dev Logged once per run: as an invariant it would run after every call.
  function _logCallSummary() internal view {
    console2.log("enter ok / bounded", handler.enterSuccesses(), handler.enterBoundedSuccesses());
    console2.log("enter slippage / cap", handler.enterSlippageReverts(), handler.enterCapFailures());
    console2.log("enter dust / gate", handler.enterDustFailures(), handler.enterGateFailures());
    console2.log("enter zero mints", handler.enterZeroMintFailures());
    console2.log("enter above / near target", handler.enterAboveTargetFailures(), handler.enterNearTargetSkips());
    console2.log("enter spill-overs", handler.spillOvers());
    console2.log("maxEnter probes / ok", handler.maxEnterProbes(), handler.maxEnterProbeSuccesses());
    console2.log("maxEnter dust", handler.maxEnterProbeDust());
    console2.log("exit ok / bounded", handler.exitSuccesses(), handler.exitBoundedSuccesses());
    console2.log("exit callback / repay", handler.exitCallbackSuccesses(), handler.exitRepaySuccesses());
    console2.log("exit slippage / cap", handler.exitSlippageReverts(), handler.exitCapFailures());
    console2.log("exit hard cap", handler.exitHardCapFailures());
    console2.log("exit gate / noop", handler.exitGateFailures(), handler.exitNoops());
    console2.log("exit word absolute / pool", handler.exitSuccessesByWord(0), handler.exitSuccessesByWord(1));
    console2.log("exit word dynamic", handler.exitSuccessesByWord(2));
    console2.log("exit word pool / dynamic credit", handler.exitSuccessesByWord(3), handler.exitSuccessesByWord(4));
    console2.log("hard-cap raises / refills", handler.hardCapRaises(), handler.refills());
    console2.log("above-target moves / resets", handler.aboveTargetMoves(), handler.priceResets());
    console2.log("maxExit probes / ok", handler.maxExitProbes(), handler.maxExitProbeSuccesses());
    console2.log("max stayer drop PM1 / PM2", handler.maxStayerDrop(0), handler.maxStayerDrop(1));
  }

  function afterInvariant() public view {
    _logCallSummary();
    assertGt(handler.enterSuccesses(), 0, "no entry went through");
    assertGt(handler.exitSuccesses(), 0, "no exit went through");
  }
}
