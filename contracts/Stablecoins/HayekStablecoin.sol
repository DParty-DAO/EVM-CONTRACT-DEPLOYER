// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;

import "../Common/Context.sol";
import "../ERC20/IERC20.sol";
import "../ERC20/ERC20Custom.sol";
import "../ERC20/ERC20.sol";
import "../Math/SafeMath.sol";
import "../Staking/Owned.sol";
import "../HAS/HAS.sol";
import "./Pools/HayekPool.sol";
import "../Oracle/UniswapPairOracle.sol";
import "../Oracle/ChainlinkETHUSDPriceConsumer.sol";
import "../Oracle/ChainlinkFiatUSDPriceConsumer.sol";
import "../Governance/AccessControl.sol";
import "./IHayekStablecoinManager.sol";

import "hardhat/console.sol";

contract HayekStablecoin is ERC20Custom, AccessControl, Owned {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    enum PriceChoice { Stablecoin, HAS }
    ChainlinkETHUSDPriceConsumer private eth_usd_pricer;
    // TODO (Gary): actually set up a oracle on chainlink
    ChainlinkFiatUSDPriceConsumer private fiat_usd_pricer;
    uint8 private eth_usd_pricer_decimals;
    uint8 private fiat_usd_pricer_decimals;
    UniswapPairOracle private stablecoinEthOracle;
    UniswapPairOracle private hasEthOracle;
    // TODO: get the address of the manager
    address private stablecoin_manager_address;

    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    address public creator_address;
    address public timelock_address; // Governance timelock address
    address public controller_address; // Controller contract to dynamically adjust system parameters automatically
    address public has_address;
    address public stablecoin_eth_oracle_address;
    address public has_eth_oracle_address;
    address public weth_address;
    address public eth_usd_consumer_address;
    address public fiat_usd_consumer_address;
    uint256 public constant genesis_supply = 2000000e18; // 2M (only for testing, genesis supply will be 5k on Mainnet). This is to help with establishing the Uniswap pools, as they need liquidity

    // The addresses in this array are added by the oracle and these contracts are able to mint stablecoin
    address[] public stablecoin_pools_array;

    // Mapping is also used for faster verification
    mapping(address => bool) public stablecoin_pools; 

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    
    uint256 public global_collateral_ratio; // 6 decimals of precision, e.g. 924102 = 0.924102
    uint256 public redemption_fee; // 6 decimals of precision, divide by 1000000 in calculations for fee
    uint256 public minting_fee; // 6 decimals of precision, divide by 1000000 in calculations for fee
    uint256 public stablecoin_step; // Amount to change the collateralization ratio by upon refreshCollateralRatio()
    uint256 public refresh_cooldown; // Seconds to wait before being able to run refreshCollateralRatio() again
    uint256 public price_target; // The price of Stablecoin at which the collateral ratio will respond to; this value is only used for the collateral ratio mechanism and not for minting and redeeming which are hardcoded at $1
    uint256 public price_band; // The bound above and below the price target at which the refreshCollateralRatio() will not change the collateral ratio

    address public DEFAULT_ADMIN_ADDRESS;
    bytes32 public constant COLLATERAL_RATIO_PAUSER = keccak256("COLLATERAL_RATIO_PAUSER");
    bool public collateral_ratio_paused = false;

    /* ========== MODIFIERS ========== */

    modifier onlyCollateralRatioPauser() {
        require(hasRole(COLLATERAL_RATIO_PAUSER, msg.sender));
        _;
    }

    modifier onlyPools() {
       require(stablecoin_pools[msg.sender] == true, "Only stablecoin pools can call this function");
        _;
    } 
    
    modifier onlyByOwnerGovernanceOrController() {
        require(msg.sender == owner || msg.sender == timelock_address || msg.sender == controller_address, "Not the owner, controller, or the governance timelock");
        _;
    }

    modifier onlyByOwnerGovernanceOrPool() {
        require(
            msg.sender == owner 
            || msg.sender == timelock_address 
            || stablecoin_pools[msg.sender] == true, 
            "Not the owner, the governance timelock, or a pool");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    // TODO (IMPORTANT): check if the target price is to be fed in the first place at construction
    constructor (
        string memory _name,
        string memory _symbol,
        address _creator_address,
        address _timelock_address
    ) public Owned(_creator_address) {
        require(_timelock_address != address(0), "Zero address detected"); 
        console.log("inside constructor");
        name = _name;
        symbol = _symbol;
        creator_address = _creator_address;
        timelock_address = _timelock_address;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        DEFAULT_ADMIN_ADDRESS = _msgSender();
        _mint(creator_address, genesis_supply);
        grantRole(COLLATERAL_RATIO_PAUSER, creator_address);
        grantRole(COLLATERAL_RATIO_PAUSER, timelock_address);
        stablecoin_step = 2000; // 6 decimals of precision, equal to 0.25%
        global_collateral_ratio = 1000000; // Hayek Stablecoin system starts off fully collateralized (6 decimals of precision)
        refresh_cooldown = 3600; // Refresh cooldown period is set to 1 hour (3600 seconds) at genesis
        price_target = 1000000; // Collateral ratio will adjust according to the $1 price target at genesis
        price_band = 5000; // Collateral ratio will not adjust if between $0.995 and $1.005 at genesis
    }

    /* ========== VIEWS ========== */

    // Choice = 'Stablecoin' or 'HAS' for now
    function oracle_price(PriceChoice choice) internal view returns (uint256) {
        // Get the ETH / USD price first, and cut it down to 1e6 precision
        uint256 __eth_usd_price = uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
        uint256 price_vs_eth = 0;

        if (choice == PriceChoice.Stablecoin) {
            price_vs_eth = uint256(stablecoinEthOracle.consult(weth_address, PRICE_PRECISION)); // How much Stablecoin if you put in PRICE_PRECISION WETH
        }
        else if (choice == PriceChoice.HAS) {
            price_vs_eth = uint256(hasEthOracle.consult(weth_address, PRICE_PRECISION)); // How much HAS if you put in PRICE_PRECISION WETH
        }
        else revert("INVALID PRICE CHOICE. Needs to be either 0 (Stablecoin) or 1 (HAS)");

        // Will be in 1e6 format
        return __eth_usd_price.mul(PRICE_PRECISION).div(price_vs_eth);
    }

    // Returns X Stablecoin = 1 USD
    function stablecoin_price() external view returns (uint256) {
        return oracle_price(PriceChoice.Stablecoin);
    }

    // Returns X HAS = 1 USD
    function has_price() external view returns (uint256) {
        return oracle_price(PriceChoice.HAS);
    }

    function eth_usd_price() external view returns (uint256) {
        return uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
    }

    // TODO (Gary): check price precision
    function fiat_usd_price() external view returns (uint256) {
        return uint256(fiat_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** fiat_usd_pricer_decimals);
    }

    // This is needed to avoid costly repeat calls to different getter functions
    // It is cheaper gas-wise to just dump everything and only use some of the info
    function stablecoin_info() external view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        uint256 total_collateral_value_d18 = 0; 
        for (uint i = 0; i < stablecoin_pools_array.length; i++){ 
            // Exclude null addresses
            if (stablecoin_pools_array[i] != address(0)){
                total_collateral_value_d18 = total_collateral_value_d18.add(HayekPool(stablecoin_pools_array[i]).collatDollarBalance());
            }
        }
        return (
            oracle_price(PriceChoice.Stablecoin), // stablecoin_price()
            oracle_price(PriceChoice.HAS), // has_price()
            totalSupply(), // totalSupply()
            global_collateral_ratio, // global_collateral_ratio()
            total_collateral_value_d18, // globalCollateralValue
            minting_fee, // minting_fee()
            redemption_fee, // redemption_fee()
            uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals) //eth_usd_price
        );
    }

    // Iterate through all stablecoin pools and calculate all value of collateral in all pools globally 
    function globalCollateralValue() external view returns (uint256) {
        uint256 total_collateral_value_d18 = 0; 

        for (uint i = 0; i < stablecoin_pools_array.length; i++){ 
            // Exclude null addresses
            if (stablecoin_pools_array[i] != address(0)){
                total_collateral_value_d18 = total_collateral_value_d18.add(HayekPool(stablecoin_pools_array[i]).collatDollarBalance());
            }
        }
        return total_collateral_value_d18;
    }

    /* ========== PUBLIC FUNCTIONS ========== */
    
    // There needs to be a time interval that this can be called. Otherwise it can be called multiple times per expansion.
    uint256 public last_call_time; // Last time the refreshCollateralRatio function was called
    function refreshCollateralRatio() external {
        require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 stablecoin_price_cur = oracle_price(PriceChoice.Stablecoin);
        require(block.timestamp - last_call_time >= refresh_cooldown, "Must wait for the refresh cooldown since last refresh");

        // Step increments are 0.20% (upon genesis, changable by setStablecoinStep())
        
        price_target = uint256(fiat_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** fiat_usd_pricer_decimals); // fiat current price
        // TODO: currently change with ratio
        if (stablecoin_price_cur > price_target.mul(PRICE_PRECISION.add(price_band)).div(PRICE_PRECISION)) { //decrease collateral ratio
            if(global_collateral_ratio <= stablecoin_step){ //if within a step of 0, go to 0
                global_collateral_ratio = 0;
            } else {
                global_collateral_ratio = global_collateral_ratio.sub(stablecoin_step);
            }
        } else if (stablecoin_price_cur < price_target.mul(PRICE_PRECISION.sub(price_band)).div(PRICE_PRECISION)) { //increase collateral ratio
            if(global_collateral_ratio.add(stablecoin_step) >= 1000000){
                global_collateral_ratio = 1000000; // cap collateral ratio at 1.000000
            } else {
                global_collateral_ratio = global_collateral_ratio.add(stablecoin_step);
            }
        }

        last_call_time = block.timestamp; // Set the time of the last expansion

        emit CollateralRatioRefreshed(global_collateral_ratio);
    }

    function getCollateralRatioRefreshState() public view returns (uint8) {
        if (collateral_ratio_paused == true) {
            return uint8(1); // "Collateral Ratio has been paused"
        }

        if (block.timestamp - last_call_time >= refresh_cooldown) {
            return uint8(2); // "Must wait for the refresh cooldown since last refresh"
        }
        return uint8(0);
    }

    function refreshCollateralRatioAuto() internal returns (uint8) {
        if (collateral_ratio_paused == true) {
            return uint8(1); // "Collateral Ratio has been paused"
        }
        uint256 stablecoin_price_cur = oracle_price(PriceChoice.Stablecoin);

        if (block.timestamp - last_call_time >= refresh_cooldown) {
            return uint8(2); // "Must wait for the refresh cooldown since last refresh"
        }

        // Step increments are 0.20% (upon genesis, changable by setStablecoinStep())
        
        price_target = uint256(fiat_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** fiat_usd_pricer_decimals); // fiat current price
        // TODO: currently change with ratio
        if (stablecoin_price_cur > price_target.mul(PRICE_PRECISION.add(price_band)).div(PRICE_PRECISION)) { //decrease collateral ratio
            if(global_collateral_ratio <= stablecoin_step){ //if within a step of 0, go to 0
                global_collateral_ratio = 0;
            } else {
                global_collateral_ratio = global_collateral_ratio.sub(stablecoin_step);
            }
        } else if (stablecoin_price_cur < price_target.mul(PRICE_PRECISION.sub(price_band)).div(PRICE_PRECISION)) { //increase collateral ratio
            if(global_collateral_ratio.add(stablecoin_step) >= 1000000){
                global_collateral_ratio = 1000000; // cap collateral ratio at 1.000000
            } else {
                global_collateral_ratio = global_collateral_ratio.add(stablecoin_step);
            }
        }

        last_call_time = block.timestamp; // Set the time of the last expansion

        emit CollateralRatioRefreshed(global_collateral_ratio);
        return uint8(0);
    }

    function get_refresh_collateral_ratio() external returns (uint256) {

        uint8 collateral_refresh_state = refreshCollateralRatioAuto();
        return global_collateral_ratio;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Used by pools when user redeems
    function pool_burn_from(address b_address, uint256 b_amount) external onlyPools {
        super._burnFrom(b_address, b_amount);
        emit StablecoinBurned(b_address, msg.sender, b_amount);
    }

    // This function is what other stablecoin pools will call to mint new Stablecoin 
    function pool_mint(address m_address, uint256 m_amount) external onlyPools {
        super._mint(m_address, m_amount);
        emit StablecoinMinted(msg.sender, m_address, m_amount);
    }

    // Adds collateral addresses supported, such as tether and busd, must be ERC20 
    function addPool(address pool_address) external onlyByOwnerGovernanceOrController {
        require(pool_address != address(0), "Zero address detected");

        require(stablecoin_pools[pool_address] == false, "Address already exists");
        stablecoin_pools[pool_address] = true; 
        stablecoin_pools_array.push(pool_address);

        emit PoolAdded(pool_address);
    }

    // Remove a pool 
    function removePool(address pool_address) external onlyByOwnerGovernanceOrController {
        require(pool_address != address(0), "Zero address detected");
        require(stablecoin_pools[pool_address] == true, "Address nonexistant");
        
        // Delete from the mapping
        delete stablecoin_pools[pool_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint i = 0; i < stablecoin_pools_array.length; i++) { 
            if (stablecoin_pools_array[i] == pool_address) {
                stablecoin_pools_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }

        emit PoolRemoved(pool_address);
    }

    function setRedemptionFee(uint256 red_fee) external onlyByOwnerGovernanceOrController {
        redemption_fee = red_fee;

        emit RedemptionFeeSet(red_fee);
    }

    function setMintingFee(uint256 min_fee) external onlyByOwnerGovernanceOrController {
        minting_fee = min_fee;

        emit MintingFeeSet(min_fee);
    }  

    function setStablecoinStep(uint256 _new_step) external onlyByOwnerGovernanceOrController {
        stablecoin_step = _new_step;

        emit StepSet(_new_step);
    }  

    function setPriceTarget (uint256 _new_price_target) external onlyByOwnerGovernanceOrController {
        price_target = _new_price_target;

        emit PriceTargetSet(_new_price_target);
    }

    function setRefreshCooldown(uint256 _new_cooldown) external onlyByOwnerGovernanceOrController {
    	refresh_cooldown = _new_cooldown;

        emit RefreshCooldownSet(_new_cooldown);
    }

    function setHASAddress(address _has_address) external onlyByOwnerGovernanceOrController {
        require(_has_address != address(0), "Zero address detected");

        has_address = _has_address;

        emit HASAddressSet(_has_address);
    }

    function setETHUSDOracle(address _eth_usd_consumer_address) external onlyByOwnerGovernanceOrController {
        require(_eth_usd_consumer_address != address(0), "Zero address detected");

        eth_usd_consumer_address = _eth_usd_consumer_address;
        eth_usd_pricer = ChainlinkETHUSDPriceConsumer(eth_usd_consumer_address);
        eth_usd_pricer_decimals = eth_usd_pricer.getDecimals();

        emit ETHUSDOracleSet(_eth_usd_consumer_address);
    }

    // TODO (Gary): set
    function setFiatUSDOracle(address _fiat_usd_consumer_address) external onlyByOwnerGovernanceOrController {
        require(_fiat_usd_consumer_address != address(0), "Zero address detected");
        
        fiat_usd_consumer_address = _fiat_usd_consumer_address;
        fiat_usd_pricer = ChainlinkFiatUSDPriceConsumer(fiat_usd_consumer_address);
        fiat_usd_pricer_decimals = fiat_usd_pricer.getDecimals();

        emit FiatUSDOracleSet(_fiat_usd_consumer_address);
    }

    function setTimelock(address new_timelock) external onlyByOwnerGovernanceOrController {
        require(new_timelock != address(0), "Zero address detected");

        timelock_address = new_timelock;

        emit TimelockSet(new_timelock);
    }

    function setController(address _controller_address) external onlyByOwnerGovernanceOrController {
        require(_controller_address != address(0), "Zero address detected");

        controller_address = _controller_address;

        emit ControllerSet(_controller_address);
    }

    function setStablecoinManagerAddress(address stablecoin_manager_contract_address) external onlyByOwnerGovernanceOrController {
        require(stablecoin_manager_contract_address != address(0), "Zero address detected");

        stablecoin_manager_address = stablecoin_manager_contract_address;

        emit StablecoinManagerAddressSet(stablecoin_manager_contract_address);
    }

    function setPriceBand(uint256 _price_band) external onlyByOwnerGovernanceOrController {
        price_band = _price_band;

        emit PriceBandSet(_price_band);
    }

    // Sets the Stablecoin_ETH Uniswap oracle address 
    function setStablecoinEthOracle(address _stablecoin_oracle_addr, address _weth_address) external onlyByOwnerGovernanceOrController {
        require((_stablecoin_oracle_addr != address(0)) && (_weth_address != address(0)), "Zero address detected");
        stablecoin_eth_oracle_address = _stablecoin_oracle_addr;
        stablecoinEthOracle = UniswapPairOracle(_stablecoin_oracle_addr); 
        weth_address = _weth_address;

        emit StablecoinETHOracleSet(_stablecoin_oracle_addr, _weth_address);
    }

    // Sets the HAS_ETH Uniswap oracle address 
    function setHASEthOracle(address _has_oracle_addr, address _weth_address) external onlyByOwnerGovernanceOrController {
        require((_has_oracle_addr != address(0)) && (_weth_address != address(0)), "Zero address detected");

        has_eth_oracle_address = _has_oracle_addr;
        hasEthOracle = UniswapPairOracle(_has_oracle_addr);
        weth_address = _weth_address;

        emit HASEthOracleSet(_has_oracle_addr, _weth_address);
    }

    function toggleCollateralRatio() external onlyCollateralRatioPauser {
        collateral_ratio_paused = !collateral_ratio_paused;

        emit CollateralRatioToggled(collateral_ratio_paused);
    }

    /* ========== EVENTS ========== */

    // Track Stablecoin burned
    event StablecoinBurned(address indexed from, address indexed to, uint256 amount);

    // Track Stablecoin minted
    event StablecoinMinted(address indexed from, address indexed to, uint256 amount);

    event CollateralRatioRefreshed(uint256 global_collateral_ratio);
    event PoolAdded(address pool_address);
    event PoolRemoved(address pool_address);
    event RedemptionFeeSet(uint256 red_fee);
    event MintingFeeSet(uint256 min_fee);
    event StepSet(uint256 new_step);
    event PriceTargetSet(uint256 new_price_target);
    event RefreshCooldownSet(uint256 new_cooldown);
    event HASAddressSet(address _has_address);
    event ETHUSDOracleSet(address eth_usd_consumer_address);
    event FiatUSDOracleSet(address _fiat_usd_consumer_address);
    event TimelockSet(address new_timelock);
    event ControllerSet(address controller_address);
    event PriceBandSet(uint256 price_band);
    event StablecoinETHOracleSet(address stablecoin_oracle_addr, address weth_address);
    event HASEthOracleSet(address has_oracle_addr, address weth_address);
    event CollateralRatioToggled(bool collateral_ratio_paused);
    event StablecoinManagerAddressSet(address addr);
}
