// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

import "./AggregatorV3Interface.sol";

contract ChainlinkStablecoinUSDPriceConsumerTest {
    string public name;
    uint8 private constant PRICE_DECIMALS = 6;

    constructor (string memory _name) public {
        name = _name;
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        if (keccak256(bytes(name)) == keccak256(bytes("USD"))) {
            return 1e6;
        }
        return 2e6;
    }

    function getDecimals() public view returns (uint8) {
        return 6;
    }
}