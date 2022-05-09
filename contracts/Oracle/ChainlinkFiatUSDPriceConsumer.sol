// SPDX-License-Identifier: MIT
pragma solidity >=0.6.11;

import "./AggregatorV3Interface.sol";

contract ChainlinkFiatUSDPriceConsumerFactory {
    ChainlinkFiatUSDPriceConsumer[] public price_consumers;

    function CreatePriceConsumer(
        address _addr_price_consumer,
        string memory _name
    ) public {
        ChainlinkFiatUSDPriceConsumer price_consumer = new ChainlinkFiatUSDPriceConsumer(_addr_price_consumer, _name);
        price_consumers.push(price_consumer);
        emit PriceConsumerCreated(_addr_price_consumer, _name);
    }

    event PriceConsumerCreated(address _addr_price_consumer, string _name);
}

contract ChainlinkFiatUSDPriceConsumer {

    AggregatorV3Interface internal priceFeed;
    string public name;
    uint8 private constant PRICE_DECIMALS = 6;

    // TODO: feed the address
    constructor (address _addr_price_consumer, string memory _name) public {
        // priceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        name = _name;
        if (keccak256(bytes(name)) != keccak256(bytes("USD"))) {
            priceFeed = AggregatorV3Interface(_addr_price_consumer);
        }
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        if (keccak256(bytes(name)) == keccak256(bytes("USD"))) {
            return 1e6;
        }
        (uint80 roundID, int price, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(price >= 0 && updatedAt!= 0 && answeredInRound >= roundID, "Invalid chainlink price");
        
        return price;
    }

    function getDecimals() public view returns (uint8) {
        if (keccak256(bytes(name)) == keccak256(bytes("USD"))) {
            return PRICE_DECIMALS;
        }
        return priceFeed.decimals();
    }

    // function setName(string memory _name) public {
    //     name = _name;

    //     emit NameSet(_name);
    // }

    event NameSet(string _name);
}