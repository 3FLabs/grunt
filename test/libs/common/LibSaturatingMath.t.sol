// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test, stdError} from "forge-std/Test.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";
import {LibSaturatingMath} from "src/libs/common/LibSaturatingMath.sol";

contract LibSaturatingMathHarness {
  function mulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
    return LibSaturatingMath.mulDiv(x, y, d);
  }

  function fullMulDiv(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
    return FixedPointMathLib.fullMulDiv(x, y, d);
  }
}

/// @title LibSaturatingMathTest
/// @notice Unit and fuzz tests for LibSaturatingMath.mulDiv over the full uint256 range.
contract LibSaturatingMathTest is Test {
  uint256 constant MAX = type(uint256).max;

  LibSaturatingMathHarness harness;

  function setUp() public {
    harness = new LibSaturatingMathHarness();
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       MULDIV TESTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  function test_mulDiv_roundsDown() public view {
    assertEq(harness.mulDiv(10, 3, 4), 7);
  }

  function test_mulDiv_exactWhenProductOverflows() public view {
    assertEq(harness.mulDiv(MAX, 3, 4), (3 << 254) - 1);
  }

  function test_mulDiv_xBelowDivisor() public view {
    assertEq(harness.mulDiv(3, 1 << 128, 4), 3 << 126);
  }

  function test_mulDiv_exactWhenRemainderProductOverflows() public view {
    assertEq(harness.mulDiv(1 << 255, 1 << 255, (1 << 255) + 1), (1 << 255) - 1, "q == 0");
    assertEq(harness.mulDiv(3 << 199, 1 << 100, 1 << 200), 3 << 99, "q == 1");
    assertEq(harness.mulDiv(MAX - 1, MAX, MAX), MAX - 1, "y == d");
  }

  function test_mulDiv_saturatesWhenRemainderProductOverflows() public view {
    // q * y == MAX passes the quotient check, the remainder term then overflows the sum
    assertEq(harness.mulDiv(MAX, MAX, 1 << 255), MAX);
  }

  function test_mulDiv_zeroYReturnsZero() public view {
    assertEq(harness.mulDiv(MAX, 0, 1), 0);
  }

  function test_mulDiv_exactAtQuotientBoundary() public view {
    assertEq(harness.mulDiv(MAX / 2, 2, 1), MAX - 1);
  }

  function test_mulDiv_saturatesAboveQuotientBoundary() public view {
    assertEq(harness.mulDiv(MAX / 2 + 1, 2, 1), MAX);
  }

  function test_mulDiv_saturatesWhenRemainderTermOverflowsSum() public view {
    assertEq(harness.mulDiv((MAX / 3) * 2 + 1, 3, 2), MAX);
  }

  function test_mulDiv_revertsOnZeroDivisor() public {
    vm.expectRevert(stdError.divisionError);
    harness.mulDiv(1, 1, 0);
  }

  function testFuzz_mulDiv_matchesFullMulDivOrSaturates(uint256 x, uint256 y, uint256 d) public view {
    d = bound(d, 1, MAX);

    assertEq(harness.mulDiv(x, y, d), _reference(x, y, d));
  }

  function testFuzz_mulDiv_remainderProductOverflows(uint256 r, uint256 y, uint256 d) public view {
    d = bound(d, 3, MAX);
    r = bound(r, 2, d - 1);
    // r * y overflows 256 bits
    y = bound(y, MAX / r + 1, MAX);

    assertEq(harness.mulDiv(r, y, d), _reference(r, y, d), "q == 0");
    if (r <= MAX - d) assertEq(harness.mulDiv(d + r, y, d), _reference(d + r, y, d), "q == 1");
  }

  function testFuzz_mulDiv_quotientBoundary(uint256 y, uint256 d, uint256 r) public view {
    y = bound(y, 2, MAX);
    uint256 q = MAX / y;
    // keeps (q + 1) * d, and so q * d + r, within 256 bits
    d = bound(d, 1, FixedPointMathLib.min(y - 1, MAX / (q + 1)));
    r = bound(r, 0, d - 1);

    assertEq(harness.mulDiv(q * d + r, y, d), _reference(q * d + r, y, d), "q == max / y");
    assertEq(harness.mulDiv((q + 1) * d, y, d), MAX, "q > max / y saturates");
  }

  function _reference(uint256 x, uint256 y, uint256 d) internal view returns (uint256) {
    try harness.fullMulDiv(x, y, d) returns (uint256 result) {
      return result;
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(FixedPointMathLib.FullMulDivFailed.selector), "only overflow");
      return MAX;
    }
  }
}
