// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FunctionsConsumer} from "./FunctionsConsumer.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {ABDKMath64x64} from "abdk-libraries-solidity/ABDKMath64x64.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

// POC FOR WETH/USDC POOL
//
// SWAP FEE INCREASE AT TOP OF THE BLOCK IF SWAP IS IN THE SAME DIRECTION OF LAST PRICE CHANGE OR DECREASE OTHERWISE
// (DEFINED BY THE TICK BEFORE THE SWAP AND THE PREVIOUS ONE)
//
// SWAP FEE = TOP OF THE BLOCK FEE FOR REMAINING BLOCKS
// NOTE: EFFICIENT ARBITRAGE OCCURS AT TOP OF THE BLOCK

contract DynamicSigmoidFeesHook is BaseHook {
    ///////////////////
    // Types
    ///////////////////
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using OracleLib for AggregatorV3Interface;
    using OracleLib for FunctionsConsumer;

    ///////////////////
    // Errors
    ///////////////////
    error DynamicSigmoidFeesHook__MustUseDynamicFee();
    error DynamicSigmoidFeesHook__MustOnlyBeUsedForUSDCToWETHPool(); // TODO: Comment or Remove
    error DynamicSigmoidFeesHook__DivisionByZero();
    error DynamicSigmoidFeesHook__NegativeFee();

    ///////////////////
    // State Variables
    ///////////////////
    // address constant WETH_ADDRESS_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // address constant USDC_ADDRESS_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // address ETH_USD_PRICE_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    //uint24 public constant BASE_FEE_HBPS = 500; // The default base fees in hundredths of a bip - TODO: Define at constructor

    FunctionsConsumer private baseTokenFunctionsConsumer;
    AggregatorV3Interface private baseTokenPriceFeed;

    uint24 public baseFeeHbps;

    uint8 public constant BASE_TOKEN_DECIMALS = 18; // WETH
    uint8 public constant QUOTE_TOKEN_DECIMALS = 6; // USDC

    int128 private ONE_PERCENT = ABDKMath64x64.fromInt(1); // Represent 1 in 64.64 format

    // Sigmoid S-Curve Parameters
    int128 private C0 = 0; // Represent 0 in 64.64 fixed-point format
    int128 private C1 = ABDKMath64x64.fromInt(1); // Represent 1 in 64.64 format
    int128 private C2 = ABDKMath64x64.fromInt(600); // Represent 600 in 64.64 format
    int128 private C3;

    uint256 public lastBlockNumber;
    int128 public poolOraclePriceDelta;
    uint24 public blockSwapFee;
    uint24 public blockSwapFeeDeltaPerc;

    // Testing purposes only:
    uint24 public lastSwapFee;
    uint256 public lastPriceFromOracle;

    ///////////////////
    // Events
    ///////////////////
    event SwapFeeUpdated(uint24 newSwapFee);

    event SwapFeeCalculated(
        int128 base_swap_fee,
        int128 poolOraclePriceDelta,
        int128 _blockSwapFeeDeltaPerc,
        int128 dynamicFee6464,
        uint24 newDynamicFee
    ); // Testing purposes only

    event PriceFromOracle(uint256 price); // Testing purposes only
    event PriceFromPool(uint64 price); // Testing purposes only

    ///////////////////
    // Functions
    ///////////////////
    // Initialize BaseHook parent contract in the constructor
    constructor(
        IPoolManager _poolManager,
        address _baseTokenPriceFeed,
        address _baseTokenFunctionsConsumer,
        uint24 _baseFeeHbps
    ) BaseHook(_poolManager) {
        C3 = ABDKMath64x64.divu(1, 100); // Represent 0.01 in 64.64 format
        baseTokenPriceFeed = AggregatorV3Interface(_baseTokenPriceFeed);
        baseTokenFunctionsConsumer = FunctionsConsumer(_baseTokenFunctionsConsumer);
        baseFeeHbps = _baseFeeHbps;
    }

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert DynamicSigmoidFeesHook__MustUseDynamicFee();
        lastBlockNumber = block.number;
        return this.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyByPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        //takeCommission(key, swapParams);

        uint160 _sqrtPriceX96;
        uint24 _swapFeePerc;
        (_sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        if (block.number > lastBlockNumber) {
            // Update oracle price delta and swap fee for a new block
            poolOraclePriceDelta = computePoolVsCexPriceDeltaPercentage(_sqrtPriceX96);
            _swapFeePerc = calculateFee(params);
            emit SwapFeeUpdated(_swapFeePerc);
            lastBlockNumber = block.number;
        } else {
            // Calculate fee without updating the oracle price delta
            _swapFeePerc = calculateFee(params);
        }

        // Update the dynamic LP fee again with the newly calculated value
        // poolManager.updateDynamicLPFee(key, _swapFeePerc);
        updatePoolFee(key, _swapFeePerc);
        emit SwapFeeUpdated(_swapFeePerc);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    //////////////////////////////
    // Private & Internal View & Pure Functions
    //////////////////////////////

    /// @notice Computes the price delta percentage between pool price and CEX price using 64.64 fixed-point arithmetic
    /// @return The absolute price delta percentage in 64.64 fixed-point format
    function computePoolVsCexPriceDeltaPercentage(uint160 sqrtPriceX96) internal returns (int128) {
        // Proper conversion from Q96 to 64.64 format
        int128 _poolPrice = sqrtPriceX96ToPrice(sqrtPriceX96);
        emit PriceFromPool(ABDKMath64x64.toUInt(_poolPrice));

        // Get the CEX price in 64.64 fixed-point format
        int128 cexPrice = getPriceFromOracle64x64(); // Assumes the oracle returns a 64.64 format price
        lastPriceFromOracle = uint256(ABDKMath64x64.toUInt(cexPrice));

        // Calculate the absolute price delta in 64.64 fixed-point format
        int128 priceDelta;
        if (cexPrice > _poolPrice) {
            priceDelta = ABDKMath64x64.sub(cexPrice, _poolPrice);
        } else {
            priceDelta = ABDKMath64x64.sub(_poolPrice, cexPrice);
        }

        // Calculate the percentage delta: (absPriceDelta / poolPrice) in 64.64 format
        int128 priceDeltaPercentage = ABDKMath64x64.div(priceDelta, _poolPrice);

        return priceDeltaPercentage; // Return in 64.64 format
    }

    function updatePoolFee(PoolKey calldata key, uint24 newFee) internal {
        uint24 _appliedFee;
        if (
            baseTokenFunctionsConsumer.checkCustomOracleLatestRoundData()
                || baseTokenPriceFeed.checkChainlinkLatestRoundData()
        ) {
            _appliedFee = newFee;
        } else {
            _appliedFee = baseFeeHbps;
        }
        poolManager.updateDynamicLPFee(key, _appliedFee);
        lastSwapFee = _appliedFee;
    }

    /// @notice Mock function to get the price from an oracle in 64.64 fixed-point format
    /// Replace this function with your actual oracle call.
    function getPriceFromOracle64x64() internal returns (int128) {
        uint256 latestPrice;
        uint8 priceDecimals;
        if (baseTokenFunctionsConsumer.checkCustomOracleLatestRoundData()) {
            latestPrice = baseTokenFunctionsConsumer.getCustomOracleLatestPrice();
            priceDecimals = OracleLib.getCustomOracleDecimals();
        } else {
            (, int256 answer,,,) = baseTokenPriceFeed.latestRoundData();
            latestPrice = uint256(answer);
            priceDecimals = baseTokenPriceFeed.decimals();
        }
        // (, int256 answer,,,) = baseTokenPriceFeed.latestRoundData();
        // uint8 priceDecimals = baseTokenPriceFeed.decimals();
        uint256 decimalAdjustment = 10 ** (BASE_TOKEN_DECIMALS - QUOTE_TOKEN_DECIMALS - priceDecimals);
        uint256 cexPrice = latestPrice * decimalAdjustment;
        emit PriceFromOracle(cexPrice);
        return ABDKMath64x64.fromUInt(cexPrice);
    }

    /// @notice Converts sqrtPriceX96 to price considering token decimals with 18 decimals precision
    /// @param sqrtPriceX96 The square root of the price in Q96 format
    /// @return price The price adjusted for token decimals with 18 decimal precision in 64.64 format
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (int128) {
        // Convert sqrtPriceX96 from Q96 format to 64.64 fixed-point format
        uint256 sqrtPriceX96Uint = uint256(sqrtPriceX96);
        int128 sqrtPrice = ABDKMath64x64.divu(sqrtPriceX96Uint, 2 ** 96);

        // Calculate the price in 64.64 fixed-point format as (1 / (sqrtPrice^2)) -> Assuming token0 is quote token and token1 is base token (USDC/WETH)
        int128 sqrtPriceSquared = ABDKMath64x64.mul(sqrtPrice, sqrtPrice);
        if (sqrtPriceSquared == 0) revert DynamicSigmoidFeesHook__DivisionByZero();
        int128 price = ABDKMath64x64.div(ABDKMath64x64.fromUInt(1), sqrtPriceSquared);
        // return price;

        // Calculate the adjustment factor for decimals in 64.64 format - decimal adjusted + 6 digits precision
        int128 decimalAdjustment = ABDKMath64x64.fromUInt(10 ** (BASE_TOKEN_DECIMALS - QUOTE_TOKEN_DECIMALS));
        // int128 decimalAdjustment =
        //     ABDKMath64x64.fromUInt(10 ** (BASE_TOKEN_DECIMALS - QUOTE_TOKEN_DECIMALS + PRICE_PRECISION));

        // Adjust the price for token decimals
        price = ABDKMath64x64.mul(price, decimalAdjustment);

        return price;
    }

    /// @notice Calculate the absolute fee percentage based on price delta using sigmoid function
    /// @param priceDelta The price delta as a 64.64 fixed-point number
    /// @return fee The calculated fee percentage as a 64.64 fixed-point number
    function calculateAbsSigFeePercentage(int128 priceDelta) internal view returns (int128) {
        // Calculate exponent: -C2 * (priceDelta - C3)
        int128 exponent = ABDKMath64x64.neg(ABDKMath64x64.mul(C2, ABDKMath64x64.sub(priceDelta, C3)));

        // Calculate sigmoid using exp function from ABDKMath64x64
        int128 sigmoid = ABDKMath64x64.div(C1, ABDKMath64x64.add(C1, ABDKMath64x64.exp(exponent)));

        // Calculate fee: C0 + C1 * sigmoid
        int128 fee = ABDKMath64x64.add(C0, ABDKMath64x64.mul(C1, sigmoid));

        return fee;
    }

    function calculateFee(IPoolManager.SwapParams calldata params) internal returns (uint24) {
        int128 dynamicFee;
        // int128 base_swap_fee = ABDKMath64x64.divu(BASE_FEE_HBPS, 10000); // 5 bps = 0.05%  (64.64 format)
        int128 base_swap_fee = ABDKMath64x64.fromUInt(baseFeeHbps);
        int128 _absPoolOraclePriceDelta = ABDKMath64x64.abs(poolOraclePriceDelta);
        int128 _blockSwapFeeDeltaPerc = calculateAbsSigFeePercentage(_absPoolOraclePriceDelta);
        int128 _one_perc = ONE_PERCENT;

        // Check the price delta direction and calculate the fee accordingly
        if (poolOraclePriceDelta < 0) {
            // AMM_PRICE > BINANCE PRICE -> ARBITRAGE DIRECTION: SELL WETH
            if (!params.zeroForOne) {
                // SELL WETH
                dynamicFee = ABDKMath64x64.mul(base_swap_fee, ABDKMath64x64.add(_one_perc, _blockSwapFeeDeltaPerc));
            } else {
                dynamicFee = ABDKMath64x64.mul(base_swap_fee, ABDKMath64x64.sub(_one_perc, _blockSwapFeeDeltaPerc));
            }
        } else if (poolOraclePriceDelta > 0) {
            // AMM_PRICE < BINANCE PRICE -> ARBITRAGE DIRECTION: BUY WETH
            if (params.zeroForOne) {
                // BUY WETH
                dynamicFee = ABDKMath64x64.mul(base_swap_fee, ABDKMath64x64.add(_one_perc, _blockSwapFeeDeltaPerc));
            } else {
                dynamicFee = ABDKMath64x64.mul(base_swap_fee, ABDKMath64x64.sub(_one_perc, _blockSwapFeeDeltaPerc));
            }
        } else {
            dynamicFee = base_swap_fee; // Default to base swap fee if price delta is zero
        }

        if (dynamicFee < 0) revert DynamicSigmoidFeesHook__NegativeFee();

        uint24 newDynamicFee = uint24(ABDKMath64x64.toUInt(dynamicFee));

        emit SwapFeeCalculated(base_swap_fee, poolOraclePriceDelta, _blockSwapFeeDeltaPerc, dynamicFee, newDynamicFee);

        return newDynamicFee;
    }

    function getPriceFromOracle() external returns (uint64) {
        int128 _oraclePrice64x64 = getPriceFromOracle64x64();
        return ABDKMath64x64.toUInt(_oraclePrice64x64);
    }

    /// POC taking commissions to cover Chainlink costs
    // function takeCommission(PoolKey calldata key, IPoolManager.SwapParams calldata swapParams) internal {
    //     uint256 tokenAmount =
    //         swapParams.amountSpecified < 0 ? uint256(-swapParams.amountSpecified) : uint256(swapParams.amountSpecified);

    //     uint256 commissionAmt = Math.mulDiv(tokenAmount, HOOK_COMMISSION, 10000);

    //     // determine inbound token based on 0->1 or 1->0 swap
    //     Currency inbound = swapParams.zeroForOne ? key.currency0 : key.currency1;

    //     // take the inbound token from the PoolManager, debt is paid by the swapper via the swap router
    //     // (inbound token is added to hook's reserves)
    //     poolManager.take(inbound, address(this), commissionAmt);
    // }
}
