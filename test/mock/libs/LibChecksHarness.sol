// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibChecks} from "src/libs/common/LibChecks.sol";

/// @dev Harness contract to expose internal LibChecks functions for testing
contract LibChecksHarness {
  function checkNotZeroAddress(address addr) external pure {
    LibChecks.checkNotZero(addr);
  }

  function checkContract(address addr) external view {
    LibChecks.checkContract(addr);
  }

  function checkNotZeroAmount(uint256 amount) external pure {
    LibChecks.checkNotZero(amount);
  }

  function checkValidLtv(uint256 ltv) external pure {
    LibChecks.checkValidLtv(ltv);
  }
}
