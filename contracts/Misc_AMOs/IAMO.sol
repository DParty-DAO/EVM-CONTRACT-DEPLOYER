// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;
pragma experimental ABIEncoderV2;

interface IAMO {
    function dollarBalances() external view returns (uint256 hayek_stablecoin_val_e18, uint256 collat_val_e18);
}
