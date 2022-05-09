// TODO

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;

// MAY need to be updated
interface IHayekAMOMinter {
  function Stablecoin() external view returns(address);
  function HAS() external view returns(address);
  function acceptOwnership() external;
  function addAMO(address amo_address, bool sync_too) external;
  function allAMOAddresses() external view returns(address[] memory);
  function allAMOsLength() external view returns(uint256);
  function amos(address) external view returns(bool);
  function amos_array(uint256) external view returns(address);
  function burnStablecoinFromAMO(uint256 stablecoin_amount) external;
  function burnHasFromAMO(uint256 has_amount) external;
  function col_idx() external view returns(uint256);
  function collatDollarBalance() external view returns(uint256);
  function collatDollarBalanceStored() external view returns(uint256);
  function collat_borrow_cap() external view returns(int256);
  function collat_borrowed_balances(address) external view returns(int256);
  function collat_borrowed_sum() external view returns(int256);
  function collateral_address() external view returns(address);
  function collateral_token() external view returns(address);
  function correction_offsets_amos(address, uint256) external view returns(int256);
  function custodian_address() external view returns(address);
  function dollarBalances() external view returns(uint256 stablecoin_val_e18, uint256 collat_val_e18);
  // function execute(address _to, uint256 _value, bytes _data) external returns(bool, bytes);
  function stablecoinDollarBalanceStored() external view returns(uint256);
  function stablecoinTrackedAMO(address amo_address) external view returns(int256);
  function stablecoinTrackedGlobal() external view returns(uint256);
  function stablecoin_mint_balances(address) external view returns(int256);
  function stablecoin_mint_cap() external view returns(int256);
  function stablecoin_mint_sum() external view returns(int256);
  function has_mint_balances(address) external view returns(int256);
  function has_mint_cap() external view returns(int256);
  function has_mint_sum() external view returns(int256);
  function giveCollatToAMO(address destination_amo, uint256 collat_amount) external;
  function min_cr() external view returns(uint256);
  function mintStablecoinForAMO(address destination_amo, uint256 stablecoin_amount) external;
  function mintFxsForAMO(address destination_amo, uint256 has_amount) external;
  function missing_decimals() external view returns(uint256);
  function nominateNewOwner(address _owner) external;
  function nominatedOwner() external view returns(address);
  function oldPoolCollectAndGive(address destination_amo) external;
  function oldPoolRedeem(uint256 stablecoin_amount) external;
  function old_pool() external view returns(address);
  function owner() external view returns(address);
  function pool() external view returns(address);
  function receiveCollatFromAMO(uint256 usdc_amount) external;
  function recoverERC20(address tokenAddress, uint256 tokenAmount) external;
  function removeAMO(address amo_address, bool sync_too) external;
  function setAMOCorrectionOffsets(address amo_address, int256 stablecoin_e18_correction, int256 collat_e18_correction) external;
  function setCollatBorrowCap(uint256 _collat_borrow_cap) external;
  function setCustodian(address _custodian_address) external;
  function setStablecoinMintCap(uint256 _stablecoin_mint_cap) external;
  function setStablecoinPool(address _pool_address) external;
  function setFxsMintCap(uint256 _has_mint_cap) external;
  function setMinimumCollateralRatio(uint256 _min_cr) external;
  function setTimelock(address new_timelock) external;
  function syncDollarBalances() external;
  function timelock_address() external view returns(address);
}