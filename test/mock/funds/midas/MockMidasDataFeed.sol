// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IMidasDataFeed} from "src/interfaces/integrations/midas/IMidasDataFeed.sol";

/// @dev Mock Midas DataFeed with a settable base-18 rate (defaults to 1e18).
contract MockMidasDataFeed is IMidasDataFeed {
  uint256 internal _rate = 1e18;

  function setRate(uint256 rate_) external {
    _rate = rate_;
  }

  function getDataInBase18() external view override returns (uint256) {
    return _rate;
  }
}
