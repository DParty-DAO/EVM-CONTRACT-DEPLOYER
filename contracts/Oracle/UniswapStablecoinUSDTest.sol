// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0;

contract UniswapStablecoinUSDTest {

  uint8 public decimals = 18;
  string public description;
  uint256 public version = 1;

  constructor(string memory _description) public {
      description = _description;
  }
  // getRoundData and latestRoundData should both raise "No data present"
  // if they do not have data to report, instead of returning unset values
  // which could be misinterpreted as actual reported values.
  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) {
        return (10, 10000000, 1000, 1000, 11);
    }
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) {
        return (10, 10000000, 1000, 1000, 11);
    }

}