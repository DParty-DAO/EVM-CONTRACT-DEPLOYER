// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "../Math/SafeMath.sol";
import "../HAS/IHas.sol";
import "../ERC20/ERC20.sol";
import "../Stablecoins/IStablecoin.sol";
import "../Stablecoins/IHayekAMOMinter.sol";
import "../Stablecoins/Pools/HayekPool.sol";
import "../Oracle/UniswapPairOracle.sol";
import "../Uniswap/TransferHelper.sol";
import "../Uniswap/Interfaces/IUniswapV2Router02.sol";
import "../Proxy/Initializable.sol";
import "../Staking/Owned.sol";
// TODO: change name
// import "../Staking/veFXSYieldDistributorV4.sol";

contract AMO is Owned {
    using SafeMath for uint256;
    // SafeMath automatically included in Solidity >= 8.0.0

    /* ========== STATE VARIABLES ========== */

    ERC20 private collateral_token;
    IStablecoin private Stablecoin;
    IHas private HAS;
    IUniswapV2Router02 private UniRouterV2;
    IHayekAMOMinter public amo_minter;
    // TODO: new address
    HayekPool public pool = HayekPool(0x2fE065e6FFEf9ac95ab39E5042744d695F560729);
    // TODO: change name
    // veFXSYieldDistributorV4 public yieldDistributor;
    
    address private constant collateral_address = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public timelock_address;
    address public custodian_address;
    address private constant stablecoin_address = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
    address private constant has_address = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
    address payable public constant UNISWAP_ROUTER_ADDRESS = payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public amo_minter_address;

    uint256 private missing_decimals;
    uint256 private constant PRICE_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1e6;

    // Stablecoin -> HAS max slippage
    uint256 public max_slippage;

    // Burned vs given to yield distributor
    uint256 public burn_fraction; // E6. Fraction of HAS burned vs transferred to the yield distributor

    /* ========== CONSTRUCTOR ========== */
    
    constructor (
        address _owner_address,
        address _yield_distributor_address,
        address _amo_minter_address
    ) Owned(_owner_address) {
        owner = _owner_address;
        Stablecoin = IStablecoin(stablecoin_address);
        HAS = IHas(has_address);
        // TODO
        collateral_token = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        missing_decimals = uint(18).sub(collateral_token.decimals());
        // yieldDistributor = veFXSYieldDistributorV4(_yield_distributor_address);
        
        // Initializations
        UniRouterV2 = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        amo_minter = IHayekAMOMinter(_amo_minter_address);

        // NOTE: burn_fraction is the fraction of yield burned to Uniswap pools
        max_slippage = 50000; // 5%
        burn_fraction = 0; // Give all to veHAS initially

        // Get the custodian and timelock addresses from the minter
        custodian_address = amo_minter.custodian_address();
        timelock_address = amo_minter.timelock_address();
    }

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier onlyByOwnGovCust() {
        require(msg.sender == timelock_address || msg.sender == owner || msg.sender == custodian_address, "Not owner, tlck, or custd");
        _;
    }

    modifier onlyByMinter() {
        require(msg.sender == address(amo_minter), "Not minter");
        _;
    }

    /* ========== VIEWS ========== */
    // TODO: check
    function dollarBalances() public view returns (uint256 stablecoin_val_e18, uint256 collat_val_e18) {
        uint256 fiat_price = Stablecoin.fiat_usd_price();
        stablecoin_val_e18 = Stablecoin.balanceOf(address(this)).mul(fiat_price).div(PRICE_PRECISION); // actual value * 1e18
        collat_val_e18 = stablecoin_val_e18.mul(COLLATERAL_RATIO_PRECISION).div(Stablecoin.global_collateral_ratio());
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    // TODO: check price
    function _swapStablecoinforHAS(uint256 stablecoin_amount) internal returns (uint256 stablecoin_spent, uint256 has_received) {
        // Get the HAS price
        uint256 has_price = pool.getHASPrice(); 
        uint256 fiat_price = pool.getFiatPrice();

        // Approve the Stablecoin for the router
        Stablecoin.approve(UNISWAP_ROUTER_ADDRESS, stablecoin_amount);

        address[] memory STABLECOIN_HAS_PATH = new address[](2);
        STABLECOIN_HAS_PATH[0] = stablecoin_address;
        STABLECOIN_HAS_PATH[1] = has_address;
        // NOTE: here the min_has_out is calculated according to the fiat coin price instead of stablecoin price
        uint256 min_has_out = stablecoin_amount.mul(fiat_price).div(has_price);
        min_has_out = min_has_out.sub(min_has_out.mul(max_slippage).div(PRICE_PRECISION));

        // Buy some HAS with Stablecoin
        (uint[] memory amounts) = UniRouterV2.swapExactTokensForTokens(
            stablecoin_amount,
            min_has_out,
            STABLECOIN_HAS_PATH,
            address(this),
            block.timestamp + 604800 // Expiration: 7 days from now TODO: check
        );
        return (amounts[0], amounts[1]);
    }


    // Burn unneeded or excess Stablecoin
    function swapBurn(uint256 override_stablecoin_amount, bool use_override) public onlyByOwnGov {
        uint256 mintable_stablecoin;
        if (use_override){
            // mintable_stablecoin = override_USDC_amount.mul(10 ** missing_decimals).mul(COLLATERAL_RATIO_PRECISION).div(Stablecoin.global_collateral_ratio());
            mintable_stablecoin = override_stablecoin_amount;
        }
        else {
            mintable_stablecoin = pool.buybackAvailableCollat();
        }

        (, uint256 has_received ) = _swapStablecoinforHAS(mintable_stablecoin);

        // Calculate the amount to burn vs give to the yield distributor
        uint256 amt_to_burn = has_received.mul(burn_fraction).div(PRICE_PRECISION);
        uint256 amt_to_yield_distributor = has_received.sub(amt_to_burn);

        // Burn some of the HAS
        burnHAS(amt_to_burn);

        // Give the rest to the yield distributor
        // HAS.approve(address(yieldDistributor), amt_to_yield_distributor);
        // TODO
        // yieldDistributor.notifyRewardAmount(amt_to_yield_distributor);
    }

    /* ========== Burns and givebacks ========== */

    // Burn unneeded or excess Stablecoin. Goes through the minter
    function burnStablecoin(uint256 stablecoin_amount) public onlyByOwnGovCust {
        Stablecoin.approve(address(amo_minter), stablecoin_amount);
        amo_minter.burnStablecoinFromAMO(stablecoin_amount);
    }

    // Burn unneeded HAS. Goes through the minter
    function burnHAS(uint256 has_amount) public onlyByOwnGovCust {
        HAS.approve(address(amo_minter), has_amount);
        amo_minter.burnHasFromAMO(has_amount);
    }

    /* ========== RESTRICTED GOVERNANCE FUNCTIONS ========== */

    function setBurnFraction(uint256 _burn_fraction) external onlyByOwnGov {
        burn_fraction = _burn_fraction;
    }

    function setHayekPool(address _pool_address) external onlyByOwnGov {
        pool = HayekPool(_pool_address);
    }

    function setAMOMinter(address _amo_minter_address) external onlyByOwnGov {
        amo_minter = IHayekAMOMinter(_amo_minter_address);

        // Get the timelock address from the minter
        timelock_address = amo_minter.timelock_address();

        // Make sure the new address is not address(0)
        require(timelock_address != address(0), "Invalid timelock");
    }

    function setSafetyParams(uint256 _max_slippage) external onlyByOwnGov {
        max_slippage = _max_slippage;
    }

    function setYieldDistributor(address _yield_distributor_address) external onlyByOwnGov {
        // yieldDistributor = veFXSYieldDistributorV4(_yield_distributor_address);
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyByOwnGov {
        TransferHelper.safeTransfer(address(tokenAddress), msg.sender, tokenAmount);
    }

    // Generic proxy
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyByOwnGov returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{value:_value}(_data);
        return (success, result);
    }
}