// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {FacilityBaseTest} from "./FacilityBase.t.sol";

import {stdError} from "forge-std/Test.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {IFacilityIntents} from "src/interfaces/facility/base/IFacilityIntents.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {IntentProperties} from "src/libs/facility/LibIntent.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {LibCommonErrors} from "src/libs/common/LibCommonErrors.sol";

/// @title FacilityCapsValidationFuzzTest
/// @notice Full-word validation of deposit caps on createIntent and setDepositCap
contract FacilityCapsValidationFuzzTest is FacilityBaseTest {
  using LibClone for address;

  FacilityAbsoluteCaps public caps;
  FacilityDynamicCaps public timeCaps;

  uint256 constant MAX_ABSOLUTE = (1 << 248) - 1;
  uint256 constant EXTERNAL_TYPE = 1 << 248;
  uint256 constant ADDRESS_MASK = (1 << 160) - 1;
  uint256 constant ID_MASK = ((1 << 64) - 1) << 160;
  uint256 constant MULTIPLIER_MASK = ((1 << 24) - 1) << 224;
  uint256 constant FIRST_INTENT_ID = 1;

  struct ExternalWord {
    uint256 payload;
    uint256 target;
    uint256 poolSeed;
    bool minMultiplier;
    bool delisted;
  }

  function setUp() public override {
    super.setUp();

    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory consumers = new address[](1);
    consumers[0] = address(facility);
    caps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    caps.initialize(owner, managers, consumers);
    timeCaps = FacilityDynamicCaps(address(new FacilityDynamicCaps()).clone());
    timeCaps.initialize(owner, managers, consumers);

    vm.startPrank(owner);
    capsWhitelist.setAllowed(address(caps), true);
    capsWhitelist.setAllowed(address(timeCaps), true);
    vm.stopPrank();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           HELPERS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function _paramsWithCap(uint256 word) internal view returns (IntentProperties memory props) {
    props = _intentParamsWithTargetPM();
    props.depositCap = word;
  }

  function _storedCap(uint256 intentId) internal view returns (uint256) {
    (IntentProperties memory props,,,) = facility.getIntent(intentId);
    return props.depositCap;
  }

  function _deposit(uint256 intentId, address depositor, uint256 amount) internal {
    _mintDebt(depositor, amount);
    vm.prank(depositor);
    facility.deposit(intentId, amount);
  }

  /// @dev Storage slot holding `word` among the slots getIntent reads
  function _depositCapSlot(uint256 intentId, uint256 word) internal returns (bytes32) {
    vm.record();
    facility.getIntent(intentId);
    (bytes32[] memory reads,) = vm.accesses(address(facility));
    for (uint256 i = 0; i < reads.length; i++) {
      if (uint256(vm.load(address(facility), reads[i])) == word) return reads[i];
    }
    revert("deposit cap slot not found");
  }

  /// @dev Picks an ABSOLUTE (0), EXTERNAL (1) or unknown-type (2) word
  function _anyWord(ExternalWord memory w, uint256 kind) internal returns (uint256) {
    kind = bound(kind, 0, 2);
    if (kind == 0) return w.payload & MAX_ABSOLUTE;
    if (kind == 1) return _setupExternalWord(w);
    return bound(w.payload, 2 << 248, type(uint256).max);
  }

  /// @dev Creates an intent and moves it to depositing (0), resolving (1) or resolved (2)
  function _intentInState(uint256 state) internal returns (uint256 intentId) {
    intentId = _createDefaultIntent();
    state = bound(state, 0, 2);
    if (state > 0) vm.warp(block.timestamp + 1 days);
    if (state == 2) {
      vm.prank(facilitator);
      facility.resolve(intentId);
    }
  }

  /// @dev Builds an EXTERNAL word over a fuzzed payload, pointing at caps, timeCaps or the payload's own
  ///      address, and delists both caps contracts if asked
  function _setupExternalWord(ExternalWord memory w) internal returns (uint256 word) {
    word = EXTERNAL_TYPE | (w.payload & MAX_ABSOLUTE);
    uint256 target = bound(w.target, 0, 2);
    if (target < 2) word = (word & ~ADDRESS_MASK) | uint160(target == 0 ? address(caps) : address(timeCaps));
    // small pool IDs so empty slots, gaps and repeats are common
    if (target == 0 && w.poolSeed & 1 == 0) {
      uint256 id;
      for (uint256 i = 0; i < 4; i++) {
        id |= ((w.poolSeed >> (8 + 2 * i)) & 3) << (16 * i);
      }
      word = (word & ~ID_MASK) | (id << 160);
    }
    if (w.minMultiplier) word = (word & ~MULTIPLIER_MASK) | (uint256(0x800000) << 224);
    if (w.delisted) {
      vm.startPrank(owner);
      capsWhitelist.setAllowed(address(caps), false);
      capsWhitelist.setAllowed(address(timeCaps), false);
      vm.stopPrank();
    }
  }

  /// @dev Revert data validation should produce for an EXTERNAL word, empty if it is accepted
  function _externalRevert(uint256 word, bool delisted) internal view returns (bytes memory) {
    address target = address(uint160(word));
    uint64 id = uint64(word >> 160);
    int24 multiplier = int24(uint24(word >> 224));
    bool listed = !delisted && (target == address(caps) || target == address(timeCaps));
    if (!listed) return abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, target);
    if (multiplier == type(int24).min) return abi.encodeWithSelector(IFacilityCaps.InvalidMultiplier.selector);
    if (target == address(caps) && !_validPoolIds(id)) {
      return abi.encodeWithSelector(FacilityAbsoluteCaps.InvalidCapId.selector);
    }
    return "";
  }

  /// @dev id1 set, pool IDs contiguous from id1 and distinct
  function _validPoolIds(uint64 id) internal pure returns (bool) {
    bool ended;
    for (uint256 i = 0; i < 4; i++) {
      uint16 pool = uint16(id >> (16 * i));
      if (pool == 0) {
        if (i == 0) return false;
        ended = true;
        continue;
      }
      if (ended) return false;
      for (uint256 j = 0; j < i; j++) {
        if (uint16(id >> (16 * j)) == pool) return false;
      }
    }
    return true;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ABSOLUTE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_createIntent_absoluteWord(uint256 word) public {
    word = bound(word, 0, MAX_ABSOLUTE);

    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacilityIntents.DepositCapUpdated(FIRST_INTENT_ID, word);
    vm.prank(owner);
    uint256 intentId = facility.createIntent(_paramsWithCap(word));

    assertEq(_storedCap(intentId), word, "Absolute word should be stored as is");
  }

  function test_deposit_maxAbsoluteWordIsUncapped() public {
    vm.prank(owner);
    uint256 intentId = facility.createIntent(_paramsWithCap(MAX_ABSOLUTE));

    _deposit(intentId, user, MAX_ABSOLUTE - 1);
    _deposit(intentId, user2, 1);
    assertEq(facility.totalSupply(intentId), MAX_ABSOLUTE, "Deposits should fill the whole range");
    assertEq(_storedCap(intentId), MAX_ABSOLUTE, "Deposits should not write the word");

    vm.prank(user);
    facility.withdraw(intentId, user, user, MAX_ABSOLUTE - 1);
    assertEq(_storedCap(intentId), MAX_ABSOLUTE, "Withdrawals should not write the word");
  }

  function test_setDepositCap_absoluteBoundary() public {
    uint256 intentId = _createDefaultIntent();

    vm.prank(facilitator);
    facility.setDepositCap(intentId, MAX_ABSOLUTE);
    assertEq(_storedCap(intentId), MAX_ABSOLUTE, "Largest absolute word should be accepted");

    // one more is the zero EXTERNAL word, pointing at address(0)
    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(0)));
    facility.setDepositCap(intentId, MAX_ABSOLUTE + 1);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        UNKNOWN TYPES                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_createIntent_revertOnUnknownType(uint256 word) public {
    word = bound(word, 2 << 248, type(uint256).max);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, word));
    facility.createIntent(_paramsWithCap(word));
  }

  function testFuzz_setDepositCap_revertOnUnknownType(uint256 word, uint256 state) public {
    word = bound(word, 2 << 248, type(uint256).max);
    uint256 intentId = _intentInState(state);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, word));
    facility.setDepositCap(intentId, word);
  }

  function test_createIntent_revertOnLegacyUnlimitedCap() public {
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, type(uint256).max));
    facility.createIntent(_paramsWithCap(type(uint256).max));
  }

  function test_deposit_legacyStoredWordPanicsUntilReset() public {
    uint256 marker = uint256(keccak256("legacy deposit cap")) >> 8;
    vm.prank(owner);
    uint256 intentId = facility.createIntent(_paramsWithCap(marker));
    _deposit(intentId, user, 1000e18);
    vm.store(address(facility), _depositCapSlot(intentId, marker), bytes32(type(uint256).max));
    assertEq(_storedCap(intentId), type(uint256).max, "Legacy word should be stored");

    _mintDebt(user2, 1000e18);
    vm.prank(user2);
    vm.expectRevert(stdError.enumConversionError);
    facility.deposit(intentId, 1000e18);

    vm.prank(user);
    vm.expectRevert(stdError.enumConversionError);
    facility.withdraw(intentId, user, user, 1000e18);

    vm.prank(pauser);
    vm.expectRevert(stdError.enumConversionError);
    facility.revertDeposit(intentId, user, user);

    vm.prank(facilitator);
    facility.setDepositCap(intentId, MAX_ABSOLUTE);
    vm.prank(user2);
    facility.deposit(intentId, 1000e18);
    vm.prank(user);
    facility.withdraw(intentId, user, user, 1000e18);
    assertEq(facility.totalSupply(intentId), 1000e18, "Reset word should serve deposits and withdrawals");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EXTERNAL                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_createIntent_externalWord(ExternalWord memory w) public {
    uint256 word = _setupExternalWord(w);
    bytes memory revertData = _externalRevert(word, w.delisted);

    if (revertData.length > 0) {
      vm.prank(owner);
      vm.expectRevert(revertData);
      facility.createIntent(_paramsWithCap(word));
      return;
    }
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacilityIntents.DepositCapUpdated(FIRST_INTENT_ID, word);
    vm.prank(owner);
    uint256 intentId = facility.createIntent(_paramsWithCap(word));
    assertEq(_storedCap(intentId), word, "EXTERNAL word should be stored as is");
  }

  function testFuzz_setDepositCap_externalWord(ExternalWord memory w, uint256 state) public {
    uint256 intentId = _intentInState(state);
    uint256 word = _setupExternalWord(w);
    bytes memory revertData = _externalRevert(word, w.delisted);

    if (revertData.length > 0) {
      vm.prank(facilitator);
      vm.expectRevert(revertData);
      facility.setDepositCap(intentId, word);
      return;
    }
    vm.expectEmit(true, true, true, true, address(facility));
    emit IFacilityIntents.DepositCapUpdated(intentId, word);
    vm.prank(facilitator);
    facility.setDepositCap(intentId, word);
    assertEq(_storedCap(intentId), word, "EXTERNAL word should be stored as is");
  }

  function testFuzz_createIntent_validatedLikeSetDepositCap(ExternalWord memory w, uint256 kind) public {
    uint256 intentId = _createDefaultIntent();
    uint256 word = _anyWord(w, kind);

    vm.prank(facilitator);
    (bool setOk, bytes memory setData) =
      address(facility).call(abi.encodeCall(facility.setDepositCap, (intentId, word)));
    vm.prank(facilitator);
    (bool createOk, bytes memory createData) =
      address(facility).call(abi.encodeCall(facility.createIntent, (_paramsWithCap(word))));

    assertEq(createOk, setOk, "Both paths should accept the same words");
    if (!setOk) {
      assertEq(createData, setData, "Both paths should revert alike");
      return;
    }
    assertEq(_storedCap(abi.decode(createData, (uint256))), word, "createIntent should store the word");
    assertEq(_storedCap(intentId), word, "setDepositCap should store the word");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         DE-LISTING                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setDepositCap_revertOnUnchangedWordAfterDelisting() public {
    vm.prank(owner);
    caps.setCap(1, 10_000e18, 10_000e18);
    uint256 word = LibCaps.encodeExternal(address(caps), 1, 4096);
    vm.prank(owner);
    uint256 intentId = facility.createIntent(_paramsWithCap(word));
    vm.prank(owner);
    capsWhitelist.setAllowed(address(caps), false);

    vm.prank(facilitator);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(caps)));
    facility.setDepositCap(intentId, word);

    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(caps)));
    facility.createIntent(_paramsWithCap(word));

    _deposit(intentId, user, 1000e18);
    assertEq(_storedCap(intentId), word, "Stored word should stay");
    (uint128 cap,) = caps.getCap(1);
    assertEq(cap, 9000e18, "Stored word should keep consuming");

    vm.prank(facilitator);
    facility.setDepositCap(intentId, 0);
    assertEq(_storedCap(intentId), 0, "An ABSOLUTE word should still be accepted");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ACCESS AND PAUSE                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_setDepositCap_revertOnNonFacilitator() public {
    uint256 intentId = _createDefaultIntent();
    uint256 externalWord = LibCaps.encodeExternal(address(caps), 1, 4096);

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setDepositCap(intentId, 500_000e18);

    vm.prank(user);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setDepositCap(intentId, externalWord);

    // the owner needs the facilitator role too
    vm.prank(owner);
    vm.expectRevert(Ownable.Unauthorized.selector);
    facility.setDepositCap(intentId, 500_000e18);
  }

  function test_setDepositCap_revertOnPaused() public {
    uint256 intentId = _createDefaultIntent();
    vm.prank(pauser);
    facility.pauseFor(type(uint256).max);

    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.setDepositCap(intentId, 500_000e18);

    // the pause is checked before the word is validated
    vm.prank(facilitator);
    vm.expectRevert(LibCommonErrors.Paused.selector);
    facility.setDepositCap(intentId, 2 << 248);
  }
}
