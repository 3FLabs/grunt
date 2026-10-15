// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibCapsMath} from "src/libs/common/LibCapsMath.sol";

contract LibCapsMathHarness {
  function consumption(uint256 amount, int24 multiplier) external pure returns (uint256) {
    return LibCapsMath.consumption(amount, multiplier);
  }

  function release(uint256 amount, int24 multiplier) external pure returns (uint256) {
    return LibCapsMath.release(amount, multiplier);
  }

  function depositable(uint256 cap, int24 multiplier) external pure returns (uint256) {
    return LibCapsMath.depositable(cap, multiplier);
  }

  function releasable(uint256 headroom, int24 multiplier) external pure returns (uint256) {
    return LibCapsMath.releasable(headroom, multiplier);
  }

  function charge(uint256 amount, int24 multiplier) external pure returns (uint256) {
    return LibCapsMath.charge(amount, multiplier);
  }

  function quote(uint256 room, int24 multiplier) external pure returns (uint256) {
    return LibCapsMath.quote(room, multiplier);
  }
}

/// @title LibCapsMathTest
/// @notice Unit and fuzz tests for the Q12.12 deposit-cap multiplier math.
contract LibCapsMathTest is Test {
  uint256 constant MAX = type(uint256).max;
  uint256 constant ONE = 4096;
  int24 constant MULT_1X = 4096;
  int24 constant MULT_1_5X = 6144;
  int24 constant MULT_2X = 8192;
  int24 constant MULT_MAX = type(int24).max;
  int24 constant MULT_MIN = type(int24).min;

  LibCapsMathHarness harness;

  function setUp() public {
    harness = new LibCapsMathHarness();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     CONSUMPTION TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_consumption_roundsUp() public view {
    assertEq(harness.consumption(1, 1), 1, "1/4096 rounds up");
    assertEq(harness.consumption(3, MULT_1_5X), 5, "4.5 rounds up");
    assertEq(harness.consumption(7, MULT_2X), 14, "exact product");
  }

  function test_consumption_zeroMultiplierIsFree() public view {
    assertEq(harness.consumption(MAX, 0), 0);
  }

  function test_consumption_maxMultiplier() public view {
    assertEq(harness.consumption(1, MULT_MAX), 2048, "rounds up");
    assertEq(harness.consumption(ONE, MULT_MAX), uint24(MULT_MAX), "exact");
  }

  function testFuzz_consumption_ceilOfProduct(uint256 amount, int24 multiplier) public view {
    multiplier = int24(bound(multiplier, 0, MULT_MAX));
    amount = bound(amount, 0, multiplier == 0 ? MAX : MAX / uint24(multiplier));
    uint256 product = amount * uint24(multiplier);

    assertEq(harness.consumption(amount, multiplier), product / ONE + (product % ONE == 0 ? 0 : 1));
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       RELEASE TESTS                         */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_release_roundsDown() public view {
    assertEq(harness.release(ONE - 1, -1), 0, "4095/4096 rounds down");
    assertEq(harness.release(3, -MULT_1_5X), 4, "4.5 rounds down");
    assertEq(harness.release(7, -MULT_2X), 14, "exact product");
  }

  function test_release_minMultiplier() public view {
    assertEq(harness.release(3, MULT_MIN), 3 << 11);
  }

  function testFuzz_release_floorOfProduct(uint256 amount, int24 multiplier) public view {
    multiplier = int24(bound(multiplier, MULT_MIN, -1));
    amount = bound(amount, 0, MAX / uint256(-int256(multiplier)));

    assertEq(harness.release(amount, multiplier), amount * uint256(-int256(multiplier)) / ONE);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     DEPOSITABLE TESTS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_depositable_roundsDown() public view {
    assertEq(harness.depositable(5, MULT_1_5X), 3, "10/3 rounds down");
    assertEq(harness.depositable(2047, MULT_MAX), 0, "below one unit at max multiplier");
    assertEq(harness.depositable(2048, MULT_MAX), 1, "one unit at max multiplier");
  }

  function test_depositable_unboundedForNonPositiveMultiplier() public view {
    assertEq(harness.depositable(0, 0), MAX, "zero multiplier");
    assertEq(harness.depositable(0, -1), MAX, "negative multiplier");
    assertEq(harness.depositable(0, MULT_MIN), MAX, "min multiplier");
  }

  function testFuzz_depositable_largestConsumableAmount(uint256 cap, int24 multiplier) public view {
    multiplier = int24(bound(multiplier, 1, MULT_MAX));
    cap = bound(cap, 0, (MAX - uint24(MULT_MAX)) / ONE);
    uint256 amount = harness.depositable(cap, multiplier);

    assertLe(harness.consumption(amount, multiplier), cap, "quote fits the cap");
    assertGt(harness.consumption(amount + 1, multiplier), cap, "one more does not fit");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     RELEASABLE TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_releasable_roundsDown() public view {
    assertEq(harness.releasable(1, -MULT_1_5X), 0, "2/3 rounds down");
    assertEq(harness.releasable(5, -MULT_1_5X), 3, "10/3 rounds down");
  }

  function test_releasable_minMultiplier() public view {
    assertEq(harness.releasable((3 << 11) + 2047, MULT_MIN), 3);
  }

  function testFuzz_releasable_fitsHeadroom(uint256 headroom, int24 multiplier) public view {
    multiplier = int24(bound(multiplier, MULT_MIN, -1));
    headroom = bound(headroom, 0, MAX / ONE);
    uint256 amount = harness.releasable(headroom, multiplier);

    assertEq(amount, headroom * ONE / uint256(-int256(multiplier)), "floor of the quotient");
    assertLe(harness.release(amount, multiplier), headroom, "quote fits the headroom");
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                   CHARGE AND QUOTE TESTS                    */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_charge_dispatchesOnSign() public view {
    assertEq(harness.charge(ONE + 1, 1), 2, "positive rounds up");
    assertEq(harness.charge(ONE + 1, -1), 1, "negative rounds down");
    assertEq(harness.charge(MAX, 0), 0, "zero is free");
  }

  function test_charge_revertsWhenProductOverflows() public {
    vm.expectRevert(FixedPointMathLib.MulDivFailed.selector);
    harness.charge(MAX / ONE + 1, MULT_1X);
    vm.expectRevert(FixedPointMathLib.MulDivFailed.selector);
    harness.charge(MAX / ONE + 1, -MULT_1X);
  }

  function test_quote_dispatchesOnSign() public view {
    assertEq(harness.quote(5, MULT_1_5X), 3, "positive is depositable");
    assertEq(harness.quote(5, -MULT_1_5X), 3, "negative is releasable");
    assertEq(harness.quote(5, 0), MAX, "zero is depositable");
  }

  function testFuzz_quote_chargeFitsRoom(uint256 room, int24 multiplier) public view {
    room = bound(room, 0, MAX / ONE);
    uint256 amount = harness.quote(room, multiplier);

    assertLe(harness.charge(amount, multiplier), room);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                     ROUND TRIP TESTS                        */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_roundTrip_exactWhenProductIsMultipleOfOne() public view {
    _assertRoundTrip(7, MULT_2X, 14);
    _assertRoundTrip(2, MULT_1_5X, 3);
    _assertRoundTrip(ONE, MULT_MAX, uint24(MULT_MAX));
  }

  function testFuzz_roundTrip_losesOneUnitOnlyOnInexactProduct(uint256 amount, int24 multiplier) public view {
    multiplier = int24(bound(multiplier, 1, MULT_MAX));
    amount = bound(amount, 0, MAX / uint24(multiplier));
    uint256 consumed = harness.consumption(amount, multiplier);
    uint256 released = harness.release(amount, -multiplier);

    assertLe(released, consumed, "release never exceeds consumption");
    assertEq(consumed - released, (amount * uint24(multiplier)) % ONE == 0 ? 0 : 1, "gap");
  }

  function _assertRoundTrip(uint256 amount, int24 multiplier, uint256 expected) internal view {
    assertEq(harness.consumption(amount, multiplier), expected, "consumption");
    assertEq(harness.release(amount, -multiplier), expected, "release");
  }
}
