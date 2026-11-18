// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibCapsMath} from "src/libs/common/LibCapsMath.sol";

/// @custom:halmos --solver-timeout-assertion 110000
contract LibCapsMathSymbolicTest is Test {
  int24 constant MULT_1_5X = 6144;

  function check_consumption_roundsUpAt1_5x(uint16 amount) public pure {
    assert(LibCapsMath.consumption(amount, MULT_1_5X) == (3 * uint256(amount) + 1) / 2);
  }

  function check_release_roundsDownAt1_5x(uint16 amount) public pure {
    assert(LibCapsMath.release(amount, -MULT_1_5X) == (3 * uint256(amount)) / 2);
  }

  function check_depositable_isLargestFittingAmountAt1_5x(uint16 cap) public pure {
    uint256 amount = LibCapsMath.depositable(cap, MULT_1_5X);
    assert(LibCapsMath.consumption(amount, MULT_1_5X) <= cap);
    assert(LibCapsMath.consumption(amount + 1, MULT_1_5X) > cap);
  }

  function check_releasable_fitsHeadroomAt1_5x(uint16 headroom) public pure {
    uint256 amount = LibCapsMath.releasable(headroom, -MULT_1_5X);
    assert(amount == (2 * uint256(headroom)) / 3);
    assert(LibCapsMath.release(amount, -MULT_1_5X) <= headroom);
  }
}
