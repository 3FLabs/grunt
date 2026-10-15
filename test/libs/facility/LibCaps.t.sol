// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibCaps, CapType} from "src/libs/facility/LibCaps.sol";
import {LibFacilityErrors} from "src/libs/facility/LibFacilityErrors.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";
import {FacilityCapsWhitelist} from "src/facility/caps/FacilityCapsWhitelist.sol";
import {IFacilityCaps} from "src/interfaces/facility/IFacilityCaps.sol";
import {IFacilityCapsWhitelist} from "src/interfaces/facility/IFacilityCapsWhitelist.sol";

/// @dev Exposes the library's internal functions.
contract LibCapsHarness {
  function available(uint256 word) external view returns (uint256) {
    return LibCaps.available(word);
  }

  function capType(uint256 word) external pure returns (CapType) {
    return LibCaps.capType(word);
  }

  function isExternal(uint256 word) external pure returns (bool) {
    return LibCaps.capType(word) == CapType.EXTERNAL;
  }

  /// @dev Returns the raw stack values so dirty or unextended bits show up.
  function decodeExternalRaw(uint256 word) external pure returns (uint256 caps, uint256 id, uint256 multiplier) {
    (IFacilityCaps c, uint64 i, int24 m) = LibCaps.decodeExternal(word);
    assembly ("memory-safe") {
      caps := c
      id := i
      multiplier := m
    }
  }

  function validate(uint256 word, IFacilityCapsWhitelist whitelist) external view {
    LibCaps.validate(word, whitelist);
  }

  function consume(uint256 word, uint256 capId, uint256 amount) external returns (uint256) {
    return LibCaps.consume(word, capId, amount);
  }

  function release(uint256 word, uint256 amount) external {
    LibCaps.release(word, amount);
  }
}

/// @dev Caps stub that accepts every word, quotes a set amount and records consume calls.
contract LibCapsRecordingCaps is IFacilityCaps {
  uint256 public availableAmount;
  uint256 public consumeCount;
  uint64 public lastId;
  uint256 public lastAmount;
  int24 public lastMultiplier;

  function setAvailable(uint256 amount) external {
    availableAmount = amount;
  }

  function validate(uint64, int24) external pure {}

  function available(uint64, int24) external view returns (uint256) {
    return availableAmount;
  }

  function consume(uint64 id, uint256 amount, int24 multiplier) external {
    consumeCount++;
    lastId = id;
    lastAmount = amount;
    lastMultiplier = multiplier;
  }
}

/// @title LibCapsTest
/// @notice Unit tests for LibCaps encoding, validation, consumption and views.
contract LibCapsTest is Test {
  using LibClone for address;

  LibCapsHarness harness;
  LibCapsRecordingCaps recorder;
  FacilityCapsWhitelist whitelist;
  FacilityAbsoluteCaps absoluteCaps;
  FacilityDynamicCaps dynamicCaps;

  address owner = makeAddr("owner");
  address codeless = makeAddr("codeless");
  uint16 constant ID = 7;
  uint256 constant CAP_ID = 42;
  int24 constant MULT_1X = 4096;
  int24 constant MULT_2X = 8192;

  function setUp() public {
    harness = new LibCapsHarness();
    recorder = new LibCapsRecordingCaps();
    absoluteCaps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    dynamicCaps = FacilityDynamicCaps(address(new FacilityDynamicCaps()).clone());
    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory none = new address[](0);
    absoluteCaps.initialize(owner, managers, none);
    dynamicCaps.initialize(owner, managers, none);

    whitelist = new FacilityCapsWhitelist(address(this));
    whitelist.setAllowed(address(recorder), true);
    vm.warp(1_000_000);
  }

  /// @dev ABSOLUTE word whose low bits reference the recorder like an EXTERNAL word would.
  function _shadowWord() internal view returns (uint256) {
    return LibCaps.encodeExternal(address(recorder), ID, MULT_1X) & LibCaps.MAX_ABSOLUTE;
  }

  function _panic(uint256 code) internal pure returns (bytes memory) {
    return abi.encodeWithSignature("Panic(uint256)", code);
  }

  function _assertRecorded(uint256 count, uint64 id, uint256 amount, int24 multiplier) internal view {
    assertEq(recorder.consumeCount(), count, "consume calls");
    assertEq(recorder.lastId(), id, "id");
    assertEq(recorder.lastAmount(), amount, "amount");
    assertEq(recorder.lastMultiplier(), multiplier, "multiplier");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          ENCODING                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_maxAbsolute_isEveryBitBelowTheTypeByte() public pure {
    assertEq(LibCaps.MAX_ABSOLUTE, 2 ** 248 - 1, "max absolute");
  }

  function test_encodeExternal_packsFields() public pure {
    assertEq(
      LibCaps.encodeExternal(address(type(uint160).max), 0x0123456789abcdef, -2),
      0x01fffffe0123456789abcdefffffffffffffffffffffffffffffffffffffffff,
      "negative multiplier, max address"
    );
    assertEq(
      LibCaps.encodeExternal(address(1), type(uint64).max, type(int24).max),
      0x017fffffffffffffffffffff0000000000000000000000000000000000000001,
      "max multiplier, max id"
    );
    assertEq(
      LibCaps.encodeExternal(address(0), 0, type(int24).min),
      0x0180000000000000000000000000000000000000000000000000000000000000,
      "min multiplier"
    );
  }

  function test_decodeExternal_returnsCleanFields() public view {
    (uint256 caps, uint256 id, uint256 multiplier) =
      harness.decodeExternalRaw(0x01fffffe0123456789abcdefffffffffffffffffffffffffffffffffffffffff);
    assertEq(caps, type(uint160).max, "caps");
    assertEq(id, 0x0123456789abcdef, "id");
    assertEq(multiplier, type(uint256).max - 1, "sign-extended -2");

    (caps, id, multiplier) =
      harness.decodeExternalRaw(0x0180000000000000000000000000000000000000000000000000000000000000);
    assertEq(caps, 0, "zero caps");
    assertEq(id, 0, "zero id");
    assertEq(multiplier, uint256(int256(type(int24).min)), "sign-extended min");
  }

  function testFuzz_encodeExternal_roundTrip(address caps, uint64 id, int24 multiplier) public view {
    uint256 word = LibCaps.encodeExternal(caps, id, multiplier);
    assertEq(uint8(harness.capType(word)), uint8(CapType.EXTERNAL), "cap type");
    (uint256 rawCaps, uint256 rawId, uint256 rawMultiplier) = harness.decodeExternalRaw(word);
    assertEq(rawCaps, uint160(caps), "caps");
    assertEq(rawId, id, "id");
    assertEq(rawMultiplier, uint256(int256(multiplier)), "multiplier");
  }

  function testFuzz_decodeExternal_reencodesTheWord(uint256 payload) public pure {
    uint256 word = (1 << LibCaps.TYPE_OFFSET) | bound(payload, 0, LibCaps.MAX_ABSOLUTE);
    (IFacilityCaps caps, uint64 id, int24 multiplier) = LibCaps.decodeExternal(word);
    assertEq(LibCaps.encodeExternal(address(caps), id, multiplier), word, "bijection");
  }

  function testFuzz_capType_absoluteUpToMaxAbsolute(uint256 word) public view {
    word = bound(word, 0, LibCaps.MAX_ABSOLUTE);
    assertEq(uint8(harness.capType(word)), uint8(CapType.ABSOLUTE), "cap type");
  }

  function testFuzz_capType_unknownTypeBytePanics(uint256 typeByte, uint256 payload) public {
    typeByte = bound(typeByte, 2, type(uint8).max);
    uint256 word = (typeByte << LibCaps.TYPE_OFFSET) | bound(payload, 0, LibCaps.MAX_ABSOLUTE);

    vm.expectRevert(_panic(0x21));
    harness.isExternal(word);
    vm.expectRevert(_panic(0x21));
    harness.available(word);
    vm.expectRevert(_panic(0x21));
    harness.consume(word, CAP_ID, 0);
    vm.expectRevert(_panic(0x21));
    harness.release(word, 0);
  }

  function test_capType_unknownTypeBytePanicsAtBothEnds() public {
    vm.expectRevert(_panic(0x21));
    harness.isExternal(2 << LibCaps.TYPE_OFFSET);
    vm.expectRevert(_panic(0x21));
    harness.isExternal(type(uint256).max);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       LEGACY WORDS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consume_legacyUncappedWordPanicsUntilResetToMaxAbsolute() public {
    uint256 legacy = type(uint256).max;
    vm.expectRevert(_panic(0x21));
    harness.available(legacy);
    vm.expectRevert(_panic(0x21));
    harness.consume(legacy, CAP_ID, 1e18);
    vm.expectRevert(_panic(0x21));
    harness.release(legacy, 1e18);

    uint256 reset = LibCaps.MAX_ABSOLUTE;
    assertEq(harness.available(reset), reset, "reset word quotes itself");
    assertEq(harness.consume(reset, CAP_ID, 1e18), reset - 1e18, "reset word is a plain budget");
    harness.release(reset, 1e18);
  }

  function test_consume_legacyWordAtTwoPow248IsReadAsExternal() public {
    uint256 legacy = 1 << LibCaps.TYPE_OFFSET;
    assertEq(uint8(harness.capType(legacy)), uint8(CapType.EXTERNAL), "cap type");

    // the low 160 bits are read as the caps address, here address(0)
    _assertReverts(abi.encodeCall(harness.available, (legacy)));
    _assertReverts(abi.encodeCall(harness.consume, (legacy, CAP_ID, 1e18)));
    _assertReverts(abi.encodeCall(harness.release, (legacy, 1e18)));
  }

  /// @dev The revert data of a call to a codeless address differs across forge versions.
  function _assertReverts(bytes memory data) internal {
    (bool ok,) = address(harness).call(data);
    assertFalse(ok, "call succeeded");
  }

  function testFuzz_consume_legacyWordBelowTwoPow249CallsItsLowBits(uint256 high, uint256 amount) public {
    uint256 legacy = (1 << LibCaps.TYPE_OFFSET) | (bound(high, 0, (1 << 88) - 1) << 160) | uint160(address(recorder));
    (, uint64 id, int24 multiplier) = LibCaps.decodeExternal(legacy);

    assertEq(harness.consume(legacy, CAP_ID, amount), legacy, "word is not decremented");
    _assertRecorded(1, id, amount, multiplier);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         VALIDATION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function testFuzz_validate_absoluteMakesNoCall(uint256 word) public view {
    word = bound(word, 0, LibCaps.MAX_ABSOLUTE);
    harness.validate(word, IFacilityCapsWhitelist(codeless));
  }

  function testFuzz_validate_revertOnEveryUnknownTypeByte(uint256 payload) public {
    payload = bound(payload, 0, LibCaps.MAX_ABSOLUTE);
    for (uint256 typeByte = 2; typeByte <= type(uint8).max; typeByte++) {
      uint256 word = (typeByte << LibCaps.TYPE_OFFSET) | payload;
      vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.InvalidDepositCap.selector, word));
      harness.validate(word, IFacilityCapsWhitelist(codeless));
    }
  }

  function test_validate_firstWordAboveMaxAbsoluteIsExternal() public {
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(0)));
    harness.validate(LibCaps.MAX_ABSOLUTE + 1, whitelist);
  }

  function testFuzz_validate_externalForwardsIdAndMultiplier(uint64 id, int24 multiplier) public {
    uint256 word = LibCaps.encodeExternal(address(recorder), id, multiplier);
    vm.expectCall(address(whitelist), abi.encodeCall(IFacilityCapsWhitelist.isAllowed, (address(recorder))), 1);
    vm.expectCall(address(recorder), abi.encodeCall(IFacilityCaps.validate, (id, multiplier)), 1);
    harness.validate(word, whitelist);
  }

  function test_validate_revertWhenCapsNotAllowed() public {
    LibCapsRecordingCaps rogue = new LibCapsRecordingCaps();
    uint256 word = LibCaps.encodeExternal(address(rogue), ID, MULT_1X);
    vm.expectCall(address(rogue), abi.encodeWithSelector(IFacilityCaps.validate.selector), 0);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapsNotAllowed.selector, address(rogue)));
    harness.validate(word, whitelist);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        CONSUMPTION                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consume_absoluteWholeWordLeavesZero() public {
    assertEq(harness.consume(LibCaps.MAX_ABSOLUTE, CAP_ID, LibCaps.MAX_ABSOLUTE), 0, "exhausted word");
  }

  function test_consume_revertOneAboveAbsoluteWord() public {
    uint256 word = LibCaps.MAX_ABSOLUTE;
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, CAP_ID, word, word + 1));
    harness.consume(word, CAP_ID, word + 1);
  }

  function testFuzz_consume_absoluteDecrementsWord(uint256 word, uint256 capId, uint256 amount) public {
    word = bound(word, 0, LibCaps.MAX_ABSOLUTE);
    amount = bound(amount, 0, word);
    assertEq(harness.consume(word, capId, amount), word - amount, "decremented word");
  }

  function testFuzz_consume_revertAboveAbsoluteWord(uint256 word, uint256 capId, uint256 amount) public {
    word = bound(word, 0, LibCaps.MAX_ABSOLUTE);
    amount = bound(amount, word + 1, type(uint256).max);
    vm.expectRevert(abi.encodeWithSelector(LibFacilityErrors.CapExceeded.selector, capId, word, amount));
    harness.consume(word, capId, amount);
  }

  function test_consume_absoluteMakesNoCall() public {
    uint256 word = _shadowWord();
    assertEq(harness.consume(word, CAP_ID, 1), word - 1, "decremented word");
    assertEq(recorder.consumeCount(), 0, "no consume call");
  }

  function testFuzz_consume_externalForwardsTheWordMultiplier(
    uint64 id,
    uint256 capId,
    uint256 amount,
    int24 multiplier
  ) public {
    uint256 word = LibCaps.encodeExternal(address(recorder), id, multiplier);
    assertEq(harness.consume(word, capId, amount), word, "word unchanged");
    _assertRecorded(1, id, amount, multiplier);
  }

  function test_release_absoluteMakesNoCall() public {
    harness.release(_shadowWord(), 1e18);
    assertEq(recorder.consumeCount(), 0, "no consume call");
  }

  function testFuzz_release_externalNegatesTheWordMultiplier(uint64 id, uint256 amount, int24 multiplier) public {
    multiplier = int24(bound(multiplier, type(int24).min + 1, type(int24).max));
    harness.release(LibCaps.encodeExternal(address(recorder), id, multiplier), amount);
    _assertRecorded(1, id, amount, -multiplier);
  }

  function test_release_externalNegatesAtInt24Bounds() public {
    harness.release(LibCaps.encodeExternal(address(recorder), ID, type(int24).max), 1e18);
    _assertRecorded(1, ID, 1e18, type(int24).min + 1);
    harness.release(LibCaps.encodeExternal(address(recorder), ID, type(int24).min + 1), 1e18);
    _assertRecorded(2, ID, 1e18, type(int24).max);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_available_absoluteReturnsTheWord() public view {
    assertEq(harness.available(0), 0, "zero word");
    assertEq(harness.available(123e18), 123e18, "plain word");
    assertEq(harness.available(LibCaps.MAX_ABSOLUTE), LibCaps.MAX_ABSOLUTE, "max word");
  }

  function testFuzz_available_absolute(uint256 word) public view {
    word = bound(word, 0, LibCaps.MAX_ABSOLUTE);
    assertEq(harness.available(word), word, "absolute word is its own availability");
  }

  function test_available_absoluteMakesNoCall() public {
    uint256 word = _shadowWord();
    vm.expectCall(address(recorder), abi.encodeWithSelector(IFacilityCaps.available.selector), 0);
    assertEq(harness.available(word), word, "the word itself");
  }

  function testFuzz_available_externalForwardsIdAndMultiplier(uint64 id, int24 multiplier, uint256 quote) public {
    recorder.setAvailable(quote);
    uint256 word = LibCaps.encodeExternal(address(recorder), id, multiplier);
    vm.expectCall(address(recorder), abi.encodeCall(IFacilityCaps.available, (id, multiplier)), 1);
    assertEq(harness.available(word), quote, "caps quote");
  }

  function test_available_externalAbsoluteMirrorsPoolUnderMultiplier() public {
    vm.prank(owner);
    absoluteCaps.setCap(ID, 300e18, 1_000e18);
    uint256 word1x = LibCaps.encodeExternal(address(absoluteCaps), ID, MULT_1X);
    uint256 word2x = LibCaps.encodeExternal(address(absoluteCaps), ID, MULT_2X);
    assertEq(harness.available(word1x), 300e18, "1x mirrors the pool");
    assertEq(harness.available(word2x), 150e18, "2x halves the depositable amount");
    // negative multiplier: releasable headroom under |multiplier|
    uint256 wordNeg = LibCaps.encodeExternal(address(absoluteCaps), ID, -MULT_2X);
    assertEq(harness.available(wordNeg), 350e18, "releasable headroom (1000 - 300) / 2");
    uint256 wordZero = LibCaps.encodeExternal(address(absoluteCaps), ID, 0);
    assertEq(harness.available(wordZero), type(uint256).max, "zero multiplier is unbounded");
  }

  function test_available_externalDynamicMirrorsPool() public {
    vm.prank(owner);
    dynamicCaps.setCap(ID, 1_000e18, 1 days, uint64(block.timestamp - 12 hours));
    uint256 word1x = LibCaps.encodeExternal(address(dynamicCaps), ID, MULT_1X);
    assertEq(harness.available(word1x), 500e18, "half recovered");
    uint256 wordNeg = LibCaps.encodeExternal(address(dynamicCaps), ID, -MULT_1X);
    assertEq(harness.available(wordNeg), type(uint256).max, "release direction is unbounded");
  }
}
