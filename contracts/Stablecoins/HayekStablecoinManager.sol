// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;

import "../Staking/Owned.sol";
import "./HayekStablecoin.sol";
import "./IStablecoin.sol";

contract HayekStablecoinManager is Owned {
    address[] public stablecoins;
    uint256 public stablecoin_number;
    address public creator_address;
    
    constructor (
        address _creator_address
    ) public Owned(_creator_address) {
        creator_address = _creator_address;
    }

    modifier onlyByOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }
    
    function addStableCoin(
        address _stablecoin_address
    ) external onlyByOwner {
        stablecoins.push(_stablecoin_address);
        stablecoin_number += 1;
        emit StablecoinAdded(_stablecoin_address);
    }

    function getStablecoin(uint256 i) external view returns (address) {
        return stablecoins[i];
    }

    event StablecoinAdded(address _stablecoin_address);
}