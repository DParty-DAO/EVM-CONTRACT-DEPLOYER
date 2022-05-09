// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

import "./AggregatorV3Interface.sol";

contract ChainlinkStablecoinUSDPriceConsumer {

    AggregatorV3Interface internal priceFeed;
    string public name;
    uint8 private constant PRICE_DECIMALS = 6;

    // TODO: feed the address
    constructor (address _addr_price_consumer, string memory _name) public {
        name = _name; // e.g. USDH, EURH, JPYH
        priceFeed = AggregatorV3Interface(_addr_price_consumer);
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        (uint80 roundID, int price, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(price >= 0 && updatedAt!= 0 && answeredInRound >= roundID, "Invalid chainlink price");
        
        return price;
    }

    function getDecimals() public view returns (uint8) {
        return priceFeed.decimals();
    }

    // function setName(string memory _name) public {
    //     name = _name;

    //     emit NameSet(_name);
    // }

    event NameSet(string _name);
}