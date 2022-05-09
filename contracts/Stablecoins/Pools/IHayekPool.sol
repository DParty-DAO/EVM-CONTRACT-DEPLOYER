// TODO

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;

interface IHayekPool {
    function minting_fee() external returns (uint256);
    function redeemCollateralBalances(address addr) external returns (uint256);
    function redemption_fee() external returns (uint256);
    function buyback_fee() external returns (uint256);
    function recollat_fee() external returns (uint256);

    // NOTE: penalty related
    function mint_redeem_panelty() external returns (uint256);
    function fiat_panelty_paused() external returns (bool);
    function setMintRedeemPaneltyParameters(uint256 new_mint_redeem_panelty, bool new_fiat_panelty_paused) external;

    function collatDollarBalance() external returns (uint256);
    function availableExcessCollatDV() external returns (uint256);
    function getCollateralPrice() external returns (uint256);
    // TODO: check
    function getFiatPrice() external view returns (uint256);
    function getHASPrice() external view returns (uint256);
    
    function setCollatETHOracle(address _collateral_weth_oracle_address, address _weth_address) external;
    function mint1t1Stablecoin(uint256 collateral_amount, uint256 Stablecoin_out_min) external;

    // TODO: this part is deprecated
    function mintAlgorithmicStablecoin(uint256 has_amount_d18, uint256 Stablecoin_out_min) external;
    function mintFractionalStablecoin(uint256 collateral_amount, uint256 has_amount, uint256 Stablecoin_out_min) external;
    function redeem1t1Stablecoin(uint256 Stablecoin_amount, uint256 COLLATERAL_out_min) external;
    function redeemFractionalStablecoin(uint256 Stablecoin_amount, uint256 HAS_out_min, uint256 COLLATERAL_out_min) external;
    function redeemAlgorithmicStablecoin(uint256 Stablecoin_amount, uint256 HAS_out_min) external;

    function collectRedemption() external;
    function recollateralizeStablecoin(uint256 collateral_amount, uint256 HAS_out_min) external;
    function buyBackHAS(uint256 HAS_amount, uint256 COLLATERAL_out_min) external;

    // TODO: this part is deprecated
    function toggleMinting() external;
    function toggleRedeeming() external;
    function toggleRecollateralize() external;
    function toggleBuyBack() external;
    function toggleCollateralPrice(uint256 _new_price) external;

    function setPoolParameters(uint256 new_ceiling, uint256 new_bonus_rate, uint256 new_redemption_delay, uint256 new_mint_fee, uint256 new_redeem_fee, uint256 new_buyback_fee, uint256 new_recollat_fee) external;
    function setTimelock(address new_timelock) external;
    function setOwner(address _owner_address) external;
}