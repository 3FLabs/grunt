// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAddress} from "src/libs/facility/LibAddress.sol";

/// @dev Harness contract to expose internal library functions for testing
contract LibAddressHarness {
  function checkAssetsMatch(address asset1, address asset2) external pure {
    LibAddress.checkAssetsMatch(asset1, asset2);
  }
}
