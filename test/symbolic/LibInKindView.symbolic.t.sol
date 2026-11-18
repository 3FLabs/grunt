// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibInKindView} from "src/libs/facility/inkind/LibInKindView.sol";

contract LibInKindViewSymbolicTest is Test {
  function check_exitDebtRequired_zeroOnlyForZeroDebt(uint128 debt) public pure {
    assert((LibInKindView.exitDebtRequired(debt) == 0) == (debt == 0));
  }

  function check_exitDebtRequired_addsTenBpsRoundedUpPlusOne(uint16 debt) public pure {
    vm.assume(debt > 0);
    assert(LibInKindView.exitDebtRequired(debt) == uint256(debt) + (uint256(debt) + 999) / 1000 + 1);
  }
}
