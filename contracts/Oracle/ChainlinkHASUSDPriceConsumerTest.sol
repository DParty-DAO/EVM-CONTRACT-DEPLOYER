// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

import "./AggregatorV3Interface.sol";

contract ChainlinkHASUSDPriceConsumerTest {

    constructor () public {
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public pure returns (int) {
        return 59000000000;
    }

    function getDecimals() public pure returns (uint8) {
        return 8;
    }
}