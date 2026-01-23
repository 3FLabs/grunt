// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPause} from "src/libs/common/LibPause.sol";

/// @dev Helper contract to test LibPause reverts via external calls
contract LibPauseWrapper {
  function pauseFor(uint256 duration) external view returns (uint40) {
    return LibPause.pauseFor(duration);
  }
}
