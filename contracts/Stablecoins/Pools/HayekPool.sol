// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.6.11;
pragma experimental ABIEncoderV2;

import "../../Math/SafeMath.sol";
import "../../Uniswap/TransferHelper.sol";
import "../../Staking/Owned.sol";
import "../../HAS/IHas.sol";
import "../../Stablecoins/IStablecoin.sol";
import "../../Oracle/AggregatorV3Interface.sol";
import "../IHayekAMOMinter.sol";
import "../../ERC20/ERC20.sol";

contract HayekPool is Owned {
    using SafeMath for uint256;
    // SafeMath automatically included in Solidity >= 8.0.0

    /* ========== STATE VARIABLES ========== */

    // Core
    address public timelock_address;
    address public custodian_address; // Custodian is an EOA (or msig) with pausing privileges only, in case of an emergency
    // TODO (Gary): change the addresses
    // IStablecoin private Stablecoin = IStablecoin(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    IStablecoin private Stablecoin;
    // IHas private HAS = IHas(0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0);
    IHas private HAS;

    mapping(address => bool) public amo_minter_addresses; // minter address -> is it enabled
    // TODO (Gary): have the address
    // AggregatorV3Interface public priceFeedStablecoinUSD = AggregatorV3Interface(0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD);
    // AggregatorV3Interface public priceFeedHASUSD = AggregatorV3Interface(0x6Ebc52C8C1089be9eB3945C4350B68B8E4C2233f);
    // AggregatorV3Interface public priceFeedFiatUSD = AggregatorV3Interface(0x6Ebc52C8C1089be9eB3945C4350B68B8E4C2233f);
    AggregatorV3Interface public priceFeedStablecoinUSD;
    AggregatorV3Interface public priceFeedHASUSD;
    AggregatorV3Interface public priceFeedFiatUSD;
    uint256 private chainlink_stablecoin_usd_decimals;
    uint256 private chainlink_has_usd_decimals;
    uint256 private chainlink_fiat_usd_decimals;

    // Collateral
    address[] public collateral_addresses;
    string[] public collateral_symbols;
    uint256[] public missing_decimals; // Number of decimals needed to get to E18. collateral index -> missing_decimals
    uint256[] public pool_ceilings; // Total across all collaterals. Accounts for missing_decimals
    uint256[] public collateral_prices; // Stores price of the collateral, if price is paused. CONSIDER ORACLES EVENTUALLY!!!
    mapping(address => uint256) public collateralAddrToIdx; // collateral addr -> collateral index
    mapping(address => bool) public enabled_collaterals; // collateral address -> is it enabled
    
    // Redeem related
    mapping (address => uint256) public redeemHASBalances;
    mapping (address => mapping(uint256 => uint256)) public redeemCollateralBalances; // Address -> collateral index -> balance
    uint256[] public unclaimedPoolCollateral; // collateral index -> balance
    uint256 public unclaimedPoolHAS;
    mapping (address => uint256) public lastRedeemed; // Collateral independent
    uint256 public redemption_delay = 2; // Number of blocks to wait before being able to collectRedemption()
    
    // NOTE: this is the ratio of price diversion, not the real price
    uint256 public redeem_price_threshold = 990000; // 99%
    uint256 public mint_price_threshold = 1010000; // 101%
    
    // Buyback related
    mapping(uint256 => uint256) public bbkHourlyCum; // Epoch hour ->  Collat out in that hour (E18)
    uint256 public bbkMaxColE18OutPerHour = 1000e18;

    // Recollat related
    mapping(uint256 => uint256) public rctHourlyCum; // Epoch hour ->  HAS out in that hour
    uint256 public rctMaxHasOutPerHour = 1000e18;

    // Fees and rates
    // getters are in collateral_information()
    uint256[] private minting_fee;
    uint256[] private redemption_fee;
    uint256[] private buyback_fee;
    uint256[] private recollat_fee;
    uint256 public bonus_rate; // Bonus rate on HAS minted during recollateralize(); 6 decimals of precision, set to 0.75% on genesis
    // NOTE: new
    uint256 public mint_redeem_panelty = 30000; // panelty rate on redemption if not USDH

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;

    // Pause variables
    // getters are in collateral_information()
    bool[] private mintPaused; // Collateral-specific
    bool[] private redeemPaused; // Collateral-specific
    bool[] private recollateralizePaused; // Collateral-specific
    bool[] private buyBackPaused; // Collateral-specific
    bool[] private borrowingPaused; // Collateral-specific
    bool public fiat_panelty_paused = false;

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier onlyByOwnGovCust() {
        require(msg.sender == timelock_address || msg.sender == owner || msg.sender == custodian_address, "Not owner, tlck, or custd");
        _;
    }

    modifier onlyAMOMinters() {
        require(amo_minter_addresses[msg.sender], "Not an AMO Minter");
        _;
    }

    modifier collateralEnabled(uint256 col_idx) {
        require(enabled_collaterals[collateral_addresses[col_idx]], "Collateral disabled");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */
    
    constructor (
        address _pool_manager_address,
        address _custodian_address,
        address _timelock_address,
        address _has_address,
        address _stablecoin_address,
        address _priceFeedStablecoinUSD_address,
        address _priceFeedHASUSD_address,
        address _priceFeedFiatUSD_address,
        address[] memory _collateral_addresses,
        uint256[] memory _pool_ceilings,
        uint256[] memory _initial_fees
    ) public Owned(_pool_manager_address){
        // Core
        timelock_address = _timelock_address;
        custodian_address = _custodian_address;
        HAS = IHas(_has_address);
        Stablecoin = IStablecoin(_stablecoin_address);

        // Fill collateral info
        collateral_addresses = _collateral_addresses;
        for (uint256 i = 0; i < _collateral_addresses.length; i++){ 
            // For fast collateral address -> collateral idx lookups later
            collateralAddrToIdx[_collateral_addresses[i]] = i;

            // Set all of the collaterals initially to disabled
            enabled_collaterals[_collateral_addresses[i]] = false;

            // Add in the missing decimals
            missing_decimals.push(uint256(18).sub(ERC20(_collateral_addresses[i]).decimals()));

            // Add in the collateral symbols
            collateral_symbols.push(ERC20(_collateral_addresses[i]).symbol());

            // Initialize unclaimed pool collateral
            unclaimedPoolCollateral.push(0);

            // Initialize paused prices to $1 as a backup
            collateral_prices.push(PRICE_PRECISION);

            // Handle the fees
            minting_fee.push(_initial_fees[0]);
            redemption_fee.push(_initial_fees[1]);
            buyback_fee.push(_initial_fees[2]);
            recollat_fee.push(_initial_fees[3]);

            // Handle the pauses
            mintPaused.push(false);
            redeemPaused.push(false);
            recollateralizePaused.push(false);
            buyBackPaused.push(false);
            borrowingPaused.push(false);
        }

        // Pool ceiling
        pool_ceilings = _pool_ceilings;
        priceFeedStablecoinUSD = AggregatorV3Interface(_priceFeedStablecoinUSD_address);
        priceFeedHASUSD = AggregatorV3Interface(_priceFeedHASUSD_address);
        priceFeedFiatUSD = AggregatorV3Interface(_priceFeedFiatUSD_address);

        // Set the decimals
        chainlink_stablecoin_usd_decimals = priceFeedStablecoinUSD.decimals();
        chainlink_has_usd_decimals = priceFeedHASUSD.decimals();
        chainlink_fiat_usd_decimals = priceFeedFiatUSD.decimals();
    }

    /* ========== STRUCTS ========== */
    
    struct CollateralInformation {
        uint256 index;
        string symbol;
        address col_addr;
        bool is_enabled;
        uint256 missing_decs;
        uint256 price;
        uint256 pool_ceiling;
        bool mint_paused;
        bool redeem_paused;
        bool recollat_paused;
        bool buyback_paused;
        bool borrowing_paused;
        uint256 minting_fee;
        uint256 redemption_fee;
        uint256 buyback_fee;
        uint256 recollat_fee;
        // NOTE: new

    }

    /* ========== VIEWS ========== */

    // Helpful for UIs
    function collateral_information(address collat_address) external view returns (CollateralInformation memory return_data){
        require(enabled_collaterals[collat_address], "Invalid collateral");

        // Get the index
        uint256 idx = collateralAddrToIdx[collat_address];
        
        return_data = CollateralInformation(
            idx, // [0]
            collateral_symbols[idx], // [1]
            collat_address, // [2]
            enabled_collaterals[collat_address], // [3]
            missing_decimals[idx], // [4]
            collateral_prices[idx], // [5]
            pool_ceilings[idx], // [6]
            mintPaused[idx], // [7]
            redeemPaused[idx], // [8]
            recollateralizePaused[idx], // [9]
            buyBackPaused[idx], // [10]
            borrowingPaused[idx], // [11]
            minting_fee[idx], // [12]
            redemption_fee[idx], // [13]
            buyback_fee[idx], // [14]
            recollat_fee[idx] // [15]
        );
    }

    function allCollaterals() external view returns (address[] memory) {
        return collateral_addresses;
    }

    // TODO (Gary): maybe add an external version of this function for interface use
    function getStablecoinPrice() public view returns (uint256) {
        (uint80 roundID, int price, , uint256 updatedAt, uint80 answeredInRound) = priceFeedStablecoinUSD.latestRoundData();
        require(price >= 0 && updatedAt!= 0 && answeredInRound >= roundID, "Invalid chainlink price");

        return uint256(price).mul(PRICE_PRECISION).div(10 ** chainlink_stablecoin_usd_decimals);
    }

    function getHASPrice() public view returns (uint256) {
        (uint80 roundID, int price, , uint256 updatedAt, uint80 answeredInRound) = priceFeedHASUSD.latestRoundData();
        require(price >= 0 && updatedAt!= 0 && answeredInRound >= roundID, "Invalid chainlink price");

        return uint256(price).mul(PRICE_PRECISION).div(10 ** chainlink_has_usd_decimals);
        
    }

    // TODO (Gary)
    function getFiatPrice() public view returns (uint256) {
        (uint80 roundID, int price, , uint256 updatedAt, uint80 answeredInRound) = priceFeedFiatUSD.latestRoundData();
        require(price >= 0 && updatedAt!= 0 && answeredInRound >= roundID, "Invalid chainlink price");

        return uint256(price).mul(PRICE_PRECISION).div(10 ** chainlink_fiat_usd_decimals);
    }

    // Returns the Stablecoin value in collateral tokens
    // changed
    function getStablecoinInCollateral(uint256 col_idx, uint256 stablecoin_amount) public view returns (uint256) {
        uint256 fiat_price = getFiatPrice();
        return stablecoin_amount.mul(fiat_price).div(10 ** missing_decimals[col_idx]).div(collateral_prices[col_idx]);
    }

    // Used by some functions.
    function freeCollatBalance(uint256 col_idx) public view returns (uint256) {
        return ERC20(collateral_addresses[col_idx]).balanceOf(address(this)).sub(unclaimedPoolCollateral[col_idx]);
    }

    // Returns dollar value of collateral held in this Stablecoin pool, in E18
    function collatDollarBalance() external view returns (uint256 balance_tally) {
        balance_tally = 0;

        // Test 1
        for (uint256 i = 0; i < collateral_addresses.length; i++){ 
            balance_tally += freeCollatBalance(i).mul(10 ** missing_decimals[i]).mul(collateral_prices[i]).div(PRICE_PRECISION);
        }

    }

    function comboCalcBbkRct(uint256 cur, uint256 max, uint256 theo) internal pure returns (uint256) {
        if (cur >= max) {
            // If the hourly limit has already been reached, return 0;
            return 0;
        }
        else {
            // Get the available amount
            uint256 available = max.sub(cur);

            if (theo >= available) {
                // If the the theoretical is more than the available, return the available
                return available;
            }
            else {
                // Otherwise, return the theoretical amount
                return theo;
            }
        } 
    }

    // Returns the value of excess collateral (in E18) held globally, compared to what is needed to maintain the global collateral ratio
    // Also has throttling to avoid dumps during large price movements
    function buybackAvailableCollat() public view returns (uint256) {
        uint256 total_supply = Stablecoin.totalSupply();
        uint256 global_collateral_ratio = Stablecoin.global_collateral_ratio();
        uint256 global_collat_value = Stablecoin.globalCollateralValue();

        if (global_collateral_ratio > PRICE_PRECISION) global_collateral_ratio = PRICE_PRECISION; // Handles an overcollateralized contract with CR > 1
        uint256 required_collat_dollar_value_d18 = (total_supply.mul(global_collateral_ratio)).div(PRICE_PRECISION); // Calculates collateral needed to back each 1 Stablecoin with $1 of collateral at current collat ratio
        
        if (global_collat_value > required_collat_dollar_value_d18) {
            // Get the theoretical buyback amount
            uint256 theoretical_bbk_amt = global_collat_value.sub(required_collat_dollar_value_d18);

            // See how much has collateral has been issued this hour
            uint256 current_hr_bbk = bbkHourlyCum[curEpochHr()];

            // Account for the throttling
            return comboCalcBbkRct(current_hr_bbk, bbkMaxColE18OutPerHour, theoretical_bbk_amt);
        }
        else return 0;
    }

    // Returns the missing amount of collateral (in E18) needed to maintain the collateral ratio
    // changed
    function recollatTheoColAvailableE18() public view returns (uint256) {
        uint256 fiat_price = getFiatPrice();
        uint256 stablecoin_total_supply = Stablecoin.totalSupply().mul(fiat_price).div(PRICE_PRECISION);
        uint256 effective_collateral_ratio = Stablecoin.globalCollateralValue().mul(PRICE_PRECISION).div(stablecoin_total_supply); // Returns it in 1e6

        uint256 desired_collat_e24 = (Stablecoin.global_collateral_ratio()).mul(stablecoin_total_supply);
        uint256 effective_collat_e24 = effective_collateral_ratio.mul(stablecoin_total_supply);

        // Return 0 if already overcollateralized
        // Otherwise, return the deficiency
        if (effective_collat_e24 >= desired_collat_e24) return 0;
        else {
            return (desired_collat_e24.sub(effective_collat_e24)).div(PRICE_PRECISION);
        }
    }

    // Returns the value of HAS available to be used for recollats
    // Also has throttling to avoid dumps during large price movements
    function recollatAvailableHas() public view returns (uint256) {
        uint256 has_price = getHASPrice();

        // Get the amount of collateral theoretically available
        uint256 recollat_theo_available_e18 = recollatTheoColAvailableE18();

        // Get the amount of HAS theoretically outputtable
        uint256 has_theo_out = recollat_theo_available_e18.mul(PRICE_PRECISION).div(has_price);

        // See how much HAS has been issued this hour
        uint256 current_hr_rct = rctHourlyCum[curEpochHr()];

        // Account for the throttling
        return comboCalcBbkRct(current_hr_rct, rctMaxHasOutPerHour, has_theo_out);
    }

    // Returns the current epoch hour
    function curEpochHr() public view returns (uint256) {
        return (block.timestamp / 3600); // Truncation desired
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    function mintStablecoin(
        uint256 col_idx,
        uint256 stablecoin_amt,
        uint256 stablecoin_out_min,
        uint256 max_collat_in,
        uint256 max_has_in,
        bool one_to_one_override
    ) external collateralEnabled(col_idx) returns (
        uint256 total_stablecoin_mint,
        uint256 collat_needed,
        uint256 has_needed
    ) {
        require(mintPaused[col_idx] == false, "Minting is paused");

        // Prevent unneccessary mints
        require(getStablecoinPrice() >= mint_price_threshold * getFiatPrice() / PRICE_PRECISION, "Stablecoin price too low");
        

        {
            // uint256 global_collateral_ratio = Stablecoin.global_collateral_ratio();
            // NOTE: refresh CR on mint / redeem
            uint256 global_collateral_ratio = Stablecoin.get_refresh_collateral_ratio();
            if (one_to_one_override || global_collateral_ratio >= PRICE_PRECISION) { 
                // 1-to-1, overcollateralized, or user selects override
                collat_needed = getStablecoinInCollateral(col_idx, stablecoin_amt);
                has_needed = 0;
            } else if (global_collateral_ratio == 0) { 
                // Algorithmic
                collat_needed = 0;
                has_needed = stablecoin_amt * PRICE_PRECISION / getHASPrice();
            } else { 
                // Fractional
                collat_needed = getStablecoinInCollateral(col_idx, stablecoin_amt * global_collateral_ratio / PRICE_PRECISION);
                has_needed = stablecoin_amt.sub(stablecoin_amt * global_collateral_ratio / PRICE_PRECISION) * PRICE_PRECISION / getHASPrice();
            }
        }

        // NOTE: panelty added
        if (fiat_panelty_paused == false && keccak256(bytes(Stablecoin.symbol())) != keccak256(bytes("USDH"))) {
            total_stablecoin_mint = (stablecoin_amt.mul(PRICE_PRECISION.sub(minting_fee[col_idx] + mint_redeem_panelty))).div(PRICE_PRECISION);
        } else {
            // Subtract the minting fee
            total_stablecoin_mint = (stablecoin_amt.mul(PRICE_PRECISION.sub(minting_fee[col_idx]))).div(PRICE_PRECISION);
        }
        

        // Check slippages
        require((total_stablecoin_mint >= stablecoin_out_min), "Stablecoin slippage");
        require((collat_needed <= max_collat_in), "Collat slippage");
        require((has_needed <= max_has_in), "HAS slippage");

        // Check the pool ceiling
        require(freeCollatBalance(col_idx).add(collat_needed) <= pool_ceilings[col_idx], "Pool ceiling");

        // Take the HAS and collateral first
        HAS.pool_burn_from(msg.sender, has_needed);
        TransferHelper.safeTransferFrom(collateral_addresses[col_idx], msg.sender, address(this), collat_needed);

        // Mint the Stablecoin
        Stablecoin.pool_mint(msg.sender, total_stablecoin_mint);
    }

    function redeemStablecoin(
        uint256 col_idx,
        uint256 stablecoin_amount,
        uint256 has_out_min,
        uint256 col_out_min
    ) external collateralEnabled(col_idx) returns (
        uint256 collat_out,
        uint256 has_out
    ) {
        require(redeemPaused[col_idx] == false, "Redeeming is paused");

        // Prevent unnecessary redemptions that could adversely affect the HAS price
        uint256 fiat_price = getFiatPrice();

        // NOTE: check price threshold
        require(getStablecoinPrice() <= redeem_price_threshold.mul(fiat_price).div(PRICE_PRECISION), "Stablecoin price too high");
        uint256 redemption_fee_ = redemption_fee[col_idx];

        // NOTE: panelty added
        if (fiat_panelty_paused == false && keccak256(bytes(Stablecoin.symbol())) != keccak256(bytes("USDH"))) {
            redemption_fee_ = redemption_fee_ + mint_redeem_panelty;
        }
        // uint256 global_collateral_ratio = Stablecoin.global_collateral_ratio();
        uint256 global_collateral_ratio = Stablecoin.get_refresh_collateral_ratio();
        uint256 stablecoin_after_fee = (stablecoin_amount.mul(PRICE_PRECISION.sub(redemption_fee_))).div(PRICE_PRECISION);

        // Assumes $1 Stablecoin in all cases
        if(global_collateral_ratio >= PRICE_PRECISION) { 
            // 1-to-1 or overcollateralized
            collat_out = getStablecoinInCollateral(col_idx, stablecoin_after_fee);
            has_out = 0;
        } else if (global_collateral_ratio == 0) { 
            // Algorithmic
            has_out = stablecoin_after_fee
                            .mul(PRICE_PRECISION)
                            .div(getHASPrice());
            collat_out = 0;
        } else { 
            // Fractional
            collat_out = getStablecoinInCollateral(col_idx, stablecoin_after_fee).mul(global_collateral_ratio).div(PRICE_PRECISION);
            has_out = stablecoin_after_fee.mul(PRICE_PRECISION.sub(global_collateral_ratio)).div(getHASPrice()); // PRICE_PRECISIONS CANCEL OUT
        }

        // Checks
        require(collat_out <= (ERC20(collateral_addresses[col_idx])).balanceOf(address(this)).sub(unclaimedPoolCollateral[col_idx]), "Insufficient pool collateral");
        require(collat_out >= col_out_min, "Collateral slippage");
        require(has_out >= has_out_min, "HAS slippage");

        // Account for the redeem delay
        redeemCollateralBalances[msg.sender][col_idx] = redeemCollateralBalances[msg.sender][col_idx].add(collat_out);
        unclaimedPoolCollateral[col_idx] = unclaimedPoolCollateral[col_idx].add(collat_out);

        redeemHASBalances[msg.sender] = redeemHASBalances[msg.sender].add(has_out);
        unclaimedPoolHAS = unclaimedPoolHAS.add(has_out);

        lastRedeemed[msg.sender] = block.number;

        Stablecoin.pool_burn_from(msg.sender, stablecoin_amount);
        HAS.pool_mint(address(this), has_out);
    }

    // After a redemption happens, transfer the newly minted HAS and owed collateral from this pool
    // contract to the user. Redemption is split into two functions to prevent flash loans from being able
    // to take out Stablecoin/collateral from the system, use an AMM to trade the new price, and then mint back into the system.
    function collectRedemption(uint256 col_idx) external returns (uint256 has_amount, uint256 collateral_amount) {
        require(redeemPaused[col_idx] == false, "Redeeming is paused");
        require((lastRedeemed[msg.sender].add(redemption_delay)) <= block.number, "Too soon");
        bool sendHAS = false;
        bool sendCollateral = false;

        // Use Checks-Effects-Interactions pattern
        if(redeemHASBalances[msg.sender] > 0){
            has_amount = redeemHASBalances[msg.sender];
            redeemHASBalances[msg.sender] = 0;
            unclaimedPoolHAS = unclaimedPoolHAS.sub(has_amount);
            sendHAS = true;
        }
        
        if(redeemCollateralBalances[msg.sender][col_idx] > 0){
            collateral_amount = redeemCollateralBalances[msg.sender][col_idx];
            redeemCollateralBalances[msg.sender][col_idx] = 0;
            unclaimedPoolCollateral[col_idx] = unclaimedPoolCollateral[col_idx].sub(collateral_amount);
            sendCollateral = true;
        }

        // Send out the tokens
        if(sendHAS){
            TransferHelper.safeTransfer(address(HAS), msg.sender, has_amount);
        }
        if(sendCollateral){
            TransferHelper.safeTransfer(collateral_addresses[col_idx], msg.sender, collateral_amount);
        }
    }

    // Function can be called by an HAS holder to have the protocol buy back HAS with excess collateral value from a desired collateral pool
    // This can also happen if the collateral ratio > 1
    function buyBackHas(uint256 col_idx, uint256 has_amount, uint256 col_out_min) external collateralEnabled(col_idx) returns (uint256 col_out) {
        require(buyBackPaused[col_idx] == false, "Buyback is paused");
        uint256 has_price = getHASPrice();
        uint256 available_excess_collat_dv = buybackAvailableCollat();

        uint256 global_collateral_ratio = Stablecoin.get_refresh_collateral_ratio();

        // If the total collateral value is higher than the amount required at the current collateral ratio then buy back up to the possible HAS with the desired collateral
        require(available_excess_collat_dv > 0, "Insuf Collat Avail For BBK");

        // Make sure not to take more than is available
        uint256 has_dollar_value_d18 = has_amount.mul(has_price).div(PRICE_PRECISION);
        require(has_dollar_value_d18 <= available_excess_collat_dv, "Insuf Collat Avail For BBK");

        // Get the equivalent amount of collateral based on the market value of HAS provided 
        uint256 collateral_equivalent_d18 = has_dollar_value_d18.mul(PRICE_PRECISION).div(collateral_prices[col_idx]);
        col_out = collateral_equivalent_d18.div(10 ** missing_decimals[col_idx]); // In its natural decimals()

        // Subtract the buyback fee
        col_out = (col_out.mul(PRICE_PRECISION.sub(buyback_fee[col_idx]))).div(PRICE_PRECISION);

        // Check for slippage
        require(col_out >= col_out_min, "Collateral slippage");

        // Take in and burn the HAS, then send out the collateral
        HAS.pool_burn_from(msg.sender, has_amount);
        TransferHelper.safeTransfer(collateral_addresses[col_idx], msg.sender, col_out);

        // Increment the outbound collateral, in E18, for that hour
        // Used for buyback throttling
        bbkHourlyCum[curEpochHr()] += collateral_equivalent_d18;
    }

    // When the protocol is recollateralizing, we need to give a discount of HAS to hit the new CR target
    // Thus, if the target collateral ratio is higher than the actual value of collateral, minters get HAS for adding collateral
    // This function simply rewards anyone that sends collateral to a pool with the same amount of HAS + the bonus rate
    // Anyone can call this function to recollateralize the protocol and take the extra HAS value from the bonus rate as an arb opportunity
    function recollateralize(uint256 col_idx, uint256 collateral_amount, uint256 has_out_min) external collateralEnabled(col_idx) returns (uint256 has_out) {
        require(recollateralizePaused[col_idx] == false, "Recollat is paused");
        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals[col_idx]);
        uint256 has_price = getHASPrice();

        uint256 global_collateral_ratio = Stablecoin.get_refresh_collateral_ratio();

        // Get the amount of HAS actually available (accounts for throttling)
        uint256 has_actually_available = recollatAvailableHas();

        // Calculated the attempted amount of HAS
        has_out = collateral_amount_d18.mul(PRICE_PRECISION.add(bonus_rate).sub(recollat_fee[col_idx])).div(has_price);

        // Make sure there is HAS available
        require(has_out <= has_actually_available, "Insuf HAS Avail For RCT");

        // Check slippage
        require(has_out >= has_out_min, "HAS slippage");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(freeCollatBalance(col_idx).add(collateral_amount) <= pool_ceilings[col_idx], "Pool ceiling");

        // Take in the collateral and pay out the HAS
        TransferHelper.safeTransferFrom(collateral_addresses[col_idx], msg.sender, address(this), collateral_amount);
        HAS.pool_mint(msg.sender, has_out);

        // Increment the outbound HAS, in E18
        // Used for recollat throttling
        rctHourlyCum[curEpochHr()] += has_out;
    }

    // Bypasses the gassy mint->redeem cycle for AMOs to borrow collateral
    function amoMinterBorrow(uint256 collateral_amount) external onlyAMOMinters {
        // Checks the col_idx of the minter as an additional safety check
        uint256 minter_col_idx = IHayekAMOMinter(msg.sender).col_idx();

        // Checks to see if borrowing is paused
        require(borrowingPaused[minter_col_idx] == false, "Borrowing is paused");

        // Ensure collateral is enabled
        require(enabled_collaterals[collateral_addresses[minter_col_idx]], "Collateral disabled");

        // Transfer
        TransferHelper.safeTransfer(collateral_addresses[minter_col_idx], msg.sender, collateral_amount);
    }

    /* ========== RESTRICTED FUNCTIONS, CUSTODIAN CAN CALL TOO ========== */

    function toggleMRBR(uint256 col_idx, uint8 tog_idx) external onlyByOwnGovCust {
        if (tog_idx == 0) mintPaused[col_idx] = !mintPaused[col_idx];
        else if (tog_idx == 1) redeemPaused[col_idx] = !redeemPaused[col_idx];
        else if (tog_idx == 2) buyBackPaused[col_idx] = !buyBackPaused[col_idx];
        else if (tog_idx == 3) recollateralizePaused[col_idx] = !recollateralizePaused[col_idx];
        else if (tog_idx == 4) borrowingPaused[col_idx] = !borrowingPaused[col_idx];

        emit MRBRToggled(col_idx, tog_idx);
    }

    /* ========== RESTRICTED FUNCTIONS, GOVERNANCE ONLY ========== */

    // Add an AMO Minter
    function addAMOMinter(address amo_minter_addr) external onlyByOwnGov {
        require(amo_minter_addr != address(0), "Zero address detected");

        // Make sure the AMO Minter has collatDollarBalance()
        uint256 collat_val_e18 = IHayekAMOMinter(amo_minter_addr).collatDollarBalance();
        require(collat_val_e18 >= 0, "Invalid AMO");

        amo_minter_addresses[amo_minter_addr] = true;

        emit AMOMinterAdded(amo_minter_addr);
    }

    // Remove an AMO Minter 
    function removeAMOMinter(address amo_minter_addr) external onlyByOwnGov {
        amo_minter_addresses[amo_minter_addr] = false;
        
        emit AMOMinterRemoved(amo_minter_addr);
    }

    function setCollateralPrice(uint256 col_idx, uint256 _new_price) external onlyByOwnGov {
        // CONSIDER ORACLES EVENTUALLY!!!
        collateral_prices[col_idx] = _new_price;

        emit CollateralPriceSet(col_idx, _new_price);
    }

    // Could also be called toggleCollateral
    function toggleCollateral(uint256 col_idx) external onlyByOwnGov {
        address col_address = collateral_addresses[col_idx];
        enabled_collaterals[col_address] = !enabled_collaterals[col_address];

        emit CollateralToggled(col_idx, enabled_collaterals[col_address]);
    }

    function setPoolCeiling(uint256 col_idx, uint256 new_ceiling) external onlyByOwnGov {
        pool_ceilings[col_idx] = new_ceiling;

        emit PoolCeilingSet(col_idx, new_ceiling);
    }

    function setFees(uint256 col_idx, uint256 new_mint_fee, uint256 new_redeem_fee, uint256 new_buyback_fee, uint256 new_recollat_fee) external onlyByOwnGov {
        minting_fee[col_idx] = new_mint_fee;
        redemption_fee[col_idx] = new_redeem_fee;
        buyback_fee[col_idx] = new_buyback_fee;
        recollat_fee[col_idx] = new_recollat_fee;

        emit FeesSet(col_idx, new_mint_fee, new_redeem_fee, new_buyback_fee, new_recollat_fee);
    }

    // NOTE: new
    function setMintRedeemPaneltyParameters(uint256 new_mint_redeem_panelty, bool new_fiat_panelty_paused) external onlyByOwnGov {
        mint_redeem_panelty = new_mint_redeem_panelty;
        fiat_panelty_paused = new_fiat_panelty_paused;

        emit MintRedeemParatersSet(new_mint_redeem_panelty, new_fiat_panelty_paused);
    }

    function setPoolParameters(uint256 new_bonus_rate, uint256 new_redemption_delay) external onlyByOwnGov {
        bonus_rate = new_bonus_rate;
        redemption_delay = new_redemption_delay;
        emit PoolParametersSet(new_bonus_rate, new_redemption_delay);
    }

    function setPriceThresholds(uint256 new_mint_price_threshold, uint256 new_redeem_price_threshold) external onlyByOwnGov {
        mint_price_threshold = new_mint_price_threshold;
        redeem_price_threshold = new_redeem_price_threshold;
        emit PriceThresholdsSet(new_mint_price_threshold, new_redeem_price_threshold);
    }

    function setBbkRctPerHour(uint256 _bbkMaxColE18OutPerHour, uint256 _rctMaxHasOutPerHour) external onlyByOwnGov {
        bbkMaxColE18OutPerHour = _bbkMaxColE18OutPerHour;
        rctMaxHasOutPerHour = _rctMaxHasOutPerHour;
        emit BbkRctPerHourSet(_bbkMaxColE18OutPerHour, _rctMaxHasOutPerHour);
    }

    // TODO
    // Set the Chainlink oracles
    function setOracles(address _stablecoin_usd_chainlink_addr, address _has_usd_chainlink_addr, address _fiat_usd_chainlink_addr) external onlyByOwnGov {
        // Set the instances
        priceFeedStablecoinUSD = AggregatorV3Interface(_stablecoin_usd_chainlink_addr);
        priceFeedHASUSD = AggregatorV3Interface(_has_usd_chainlink_addr);
        priceFeedFiatUSD = AggregatorV3Interface(_fiat_usd_chainlink_addr);

        // Set the decimals
        chainlink_stablecoin_usd_decimals = priceFeedStablecoinUSD.decimals();
        chainlink_has_usd_decimals = priceFeedHASUSD.decimals();
        chainlink_fiat_usd_decimals = priceFeedFiatUSD.decimals();
        
        emit OraclesSet(_stablecoin_usd_chainlink_addr, _has_usd_chainlink_addr, _fiat_usd_chainlink_addr);
    }

    function setCustodian(address new_custodian) external onlyByOwnGov {
        custodian_address = new_custodian;

        emit CustodianSet(new_custodian);
    }

    function setTimelock(address new_timelock) external onlyByOwnGov {
        timelock_address = new_timelock;

        emit TimelockSet(new_timelock);
    }

    /* ========== EVENTS ========== */
    event CollateralToggled(uint256 col_idx, bool new_state);
    event PoolCeilingSet(uint256 col_idx, uint256 new_ceiling);
    event FeesSet(uint256 col_idx, uint256 new_mint_fee, uint256 new_redeem_fee, uint256 new_buyback_fee, uint256 new_recollat_fee);
    event MintRedeemParatersSet(uint256 new_mint_redeem_panelty, bool new_fiat_panelty_paused);
    event PoolParametersSet(uint256 new_bonus_rate, uint256 new_redemption_delay);
    event PriceThresholdsSet(uint256 new_bonus_rate, uint256 new_redemption_delay);
    event BbkRctPerHourSet(uint256 bbkMaxColE18OutPerHour, uint256 rctMaxHasOutPerHour);
    event AMOMinterAdded(address amo_minter_addr);
    event AMOMinterRemoved(address amo_minter_addr);
    event OraclesSet(address stablecoin_usd_chainlink_addr, address has_usd_chainlink_addr, address _fiat_usd_chainlink_addr);
    event CustodianSet(address new_custodian);
    event TimelockSet(address new_timelock);
    event MRBRToggled(uint256 col_idx, uint8 tog_idx);
    event CollateralPriceSet(uint256 col_idx, uint256 new_price);
}


// contract HayekPoolFactory is Owned {
//     HayekPool[] public pools;

//     constructor (
//         address _creator_address
//     ) public Owned(_creator_address) {
//         creator_address = _creator_address;
//     }

//     modifier onlyByOwner() {
//         require(msg.sender == owner, "Not the owner");
//         _;
//     }
    

//     function CreatePool(
//         address _pool_manager_address,
//         address _custodian_address,
//         address _timelock_address,
//         address[] memory _collateral_addresses,
//         uint256[] memory _pool_ceilings,
//         uint256[] memory _initial_fees
//     ) public onlyByOwner {
//         HayekPool pool = new HayekPool(
//             _pool_manager_address,
//             _custodian_address,
//             _timelock_address,
//             _collateral_addresses,
//             _pool_ceilings,
//             _initial_fees
//         );
//         pools.push(pool);

//         emit HayekPoolCreated(_pool_manager_address, _custodian_address, _timelock_address, _collateral_addresses, _pool_ceilings, _initial_fees);
//     }

//     event HayekPoolCreated(address _pool_manager_address, address _custodian_address, address _timelock_address, address[] _collateral_addresses, uint256[] _pool_ceilings, uint256[] _initial_fees);
// }