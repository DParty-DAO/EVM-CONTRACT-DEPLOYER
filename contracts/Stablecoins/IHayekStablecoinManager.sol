// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;

import "./HayekStablecoin.sol";

interface IHayekStablecoinManager {
    function stablecoins() external view returns (address[] memory);
    function getStablecoin(uint256 i) external view returns (address);
    function stablecoin_number() external view returns (uint256);
    function addStableCoin(address _stablecoin_address) external;
}