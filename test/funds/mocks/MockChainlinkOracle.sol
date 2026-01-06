// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "src/interfaces/integrations/AggregatorV3Interface.sol";

contract MockChainlinkOracle is AggregatorV3Interface {
  struct RoundData {
    int256 answer;
    uint256 startedAt;
    uint256 updatedAt;
    uint80 answeredInRound;
  }

  uint8 private immutable _decimals;
  uint80 private latestRoundId;
  mapping(uint80 => RoundData) private rounds;

  constructor(uint8 decimals_) {
    _decimals = decimals_;
  }

  function setRoundData(uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound) external {
    rounds[roundId] =
      RoundData({answer: answer, startedAt: updatedAt, updatedAt: updatedAt, answeredInRound: answeredInRound});
  }

  function setLatestRound(uint80 roundId) external {
    latestRoundId = roundId;
  }

  function decimals() external view returns (uint8) {
    return _decimals;
  }

  function description() external pure returns (string memory) {
    return "MockChainlinkOracle";
  }

  function version() external pure returns (uint256) {
    return 1;
  }

  function getRoundData(uint80 _roundId)
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    RoundData memory data = rounds[_roundId];
    return (_roundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound);
  }

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    RoundData memory data = rounds[latestRoundId];
    return (latestRoundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound);
  }

  function latestAnswer() external view returns (int256) {
    return rounds[latestRoundId].answer;
  }

  function latestTimestamp() external view returns (uint256) {
    return rounds[latestRoundId].updatedAt;
  }

  function latestRound() external view returns (uint256) {
    return latestRoundId;
  }

  function getAnswer(uint256 roundId) external view returns (int256) {
    return rounds[uint80(roundId)].answer;
  }

  function getTimestamp(uint256 roundId) external view returns (uint256) {
    return rounds[uint80(roundId)].updatedAt;
  }
}
