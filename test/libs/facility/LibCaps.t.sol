// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "lib/solady/src/utils/LibClone.sol";
import {LibCaps} from "src/libs/facility/LibCaps.sol";
import {LibCapsMath} from "src/libs/common/LibCapsMath.sol";
import {FacilityAbsoluteCaps} from "src/facility/caps/FacilityAbsoluteCaps.sol";
import {FacilityDynamicCaps} from "src/facility/caps/FacilityDynamicCaps.sol";

/// @dev Exposes the library's view helpers.
contract LibCapsHarness {
  function available(uint256 word) external view returns (uint256) {
    return LibCaps.available(word);
  }
}

/// @title LibCapsTest
/// @notice Unit tests for LibCaps.available over ABSOLUTE and EXTERNAL words.
contract LibCapsTest is Test {
  using LibClone for address;

  LibCapsHarness harness;
  FacilityAbsoluteCaps absoluteCaps;
  FacilityDynamicCaps dynamicCaps;

  address owner = makeAddr("owner");
  uint32 constant ID = 7;
  int24 constant MULT_1X = 4096;
  int24 constant MULT_2X = 8192;

  function setUp() public {
    harness = new LibCapsHarness();
    absoluteCaps = FacilityAbsoluteCaps(address(new FacilityAbsoluteCaps()).clone());
    dynamicCaps = FacilityDynamicCaps(address(new FacilityDynamicCaps()).clone());
    address[] memory managers = new address[](1);
    managers[0] = owner;
    address[] memory none = new address[](0);
    absoluteCaps.initialize(owner, managers, none);
    dynamicCaps.initialize(owner, managers, none);
    vm.warp(1_000_000);
  }

  function test_available_absoluteReturnsTheWord() public view {
    assertEq(harness.available(0), 0, "zero word");
    assertEq(harness.available(123e18), 123e18, "plain word");
    assertEq(harness.available(LibCaps.MAX_ABSOLUTE), LibCaps.MAX_ABSOLUTE, "max word");
  }

  function testFuzz_available_absolute(uint256 word) public view {
    word = bound(word, 0, LibCaps.MAX_ABSOLUTE);
    assertEq(harness.available(word), word, "absolute word is its own availability");
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

  function testFuzz_available_externalAbsoluteParity(uint128 cap, uint128 hardCap, int24 multiplier) public {
    cap = uint128(bound(cap, 0, type(uint128).max));
    hardCap = uint128(bound(hardCap, cap, type(uint128).max));
    vm.assume(multiplier != type(int24).min);
    vm.prank(owner);
    absoluteCaps.setCap(ID, cap, hardCap);
    uint256 word = LibCaps.encodeExternal(address(absoluteCaps), ID, multiplier);
    assertEq(harness.available(word), absoluteCaps.available(ID, multiplier), "parity with the pool view");
    if (multiplier > 0) {
      assertEq(harness.available(word), LibCapsMath.depositable(cap, multiplier), "depositable quote");
    } else if (multiplier < 0) {
      assertEq(harness.available(word), LibCapsMath.releasable(hardCap - cap, multiplier), "releasable quote");
    } else {
      assertEq(harness.available(word), type(uint256).max, "unbounded");
    }
  }
}
