// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;

import "../../Staking/Owned.sol";
import "./HayekPool.sol";


contract HayekPoolManager is Owned {
    HayekPool[] public pools;
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
    
    function addPool(
        address _pool_address
    ) public onlyByOwner {
        HayekPool pool = HayekPool(_pool_address);
        pools.push(pool);
        emit PoolAdded(_pool_address);
    }

    event PoolAdded(address _stablecoin_address);
}