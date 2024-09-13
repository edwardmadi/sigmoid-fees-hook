// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {OracleLib} from "../src/libraries/OracleLib.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {DynamicSigmoidFeesHook} from "../src/DynamicSigmoidFeesHook.sol";
import {HelperConfig, MockV3Aggregator} from "../script/HelperConfig.s.sol";

contract TestDynamicSigmoidFeesHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    DynamicSigmoidFeesHook hook;
    HelperConfig public helperConfig;

    address ethUsdPriceFeed;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        helperConfig = new HelperConfig();

        // Deploy our hook with the proper flags
        address hookAddress = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));

        (address _ethUsdPriceFeed,,,, address functionsConsumer,) = helperConfig.activeNetworkConfig();
        // console.log("ETH/USD price feed:", ethUsdPriceFeed);
        // console.log("DEFAULT_BASE_FEE_HBPS:", helperConfig.DEFAULT_BASE_FEE_HBPS());
        ethUsdPriceFeed = _ethUsdPriceFeed;
        deployCodeTo(
            "DynamicSigmoidFeesHook",
            abi.encode(manager, ethUsdPriceFeed, functionsConsumer, helperConfig.DEFAULT_BASE_FEE_HBPS()),
            hookAddress
        );
        hook = DynamicSigmoidFeesHook(hookAddress);

        // Initialize a pool
        (key,) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1, // 79228162514264337593543950336
            ZERO_BYTES
        );

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -77640,
                tickUpper: -77580,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_feeUpdatesWithPriceChangeInConsecutiveBlocks() public {
        // Token0 = WETH
        // Token1 = USDC

        // starting oracle price: 1 USDC = 2374,380330 WETH
        // starting pool price: 1 USDC = 1,000000 WETH
        // STARTING WITH HUGE PRRICE DELTA -> AFTER 1st SWAP, POOL PRICE WILL MOVE TO THE LIQUIDITY RANGE PROVIDED - CLOSE TO ORACLE PRICE

        // 1. Conduct a swap that buys token1, increasing its price in pool (pool instantiation block)
        // Fee should be equal to `BASE_FEE` since it's the 1st swap and the fee wasn't yet updated

        // Swap 0.1 ether token 0 for token 1 (price token1 up)
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        uint24 initialFeeValue = hook.lastSwapFee();
        _executeSwap(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1);

        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint24 newFeeValue = hook.lastSwapFee();
        uint256 outputFromSameBlockBuySwap = balanceOfToken1After - balanceOfToken1Before;

        assertEq(initialFeeValue, 0);
        console.log("Fee value after 1st swap:", newFeeValue);

        assertEq(newFeeValue, hook.baseFeeHbps());
        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------

        // 2.1 Increase block
        vm.roll(block.number + 1);

        // 2.2 Conduct a (top of the block) swap that buys token1, increasing its price in pool
        // pool token1 price > oracle token1 price
        // Fee must be higher as the swap occurs in the arbitrage direction

        balanceOfToken1Before = currency1.balanceOfSelf();
        initialFeeValue = hook.lastSwapFee();
        _executeSwap(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1);
        balanceOfToken1After = currency1.balanceOfSelf();
        newFeeValue = hook.lastSwapFee();
        uint256 outputFromTopOfBlockBuySwap = balanceOfToken1After - balanceOfToken1Before;

        console.log("Fee value after 2nd swap:", newFeeValue);

        assertGt(newFeeValue, initialFeeValue);
        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // As the 1st swap fee was lower and the swapped amount was the same, the output from the 1st swap should be higher
        assertGt(outputFromSameBlockBuySwap, outputFromTopOfBlockBuySwap);

        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------

        // 3.1 Increase block
        vm.roll(block.number + 1);
        // 3.2 Conduct a (top of the block) swap that sells token1, lowering its price in pool
        // pool token1 price > oracle token1 price
        // Fee must be lower as the swap occurs aggainst the arbitrage direction

        balanceOfToken1Before = currency1.balanceOfSelf();
        initialFeeValue = hook.lastSwapFee();
        _executeSwap(false, -0.1 ether, TickMath.MAX_SQRT_PRICE - 1);
        balanceOfToken1After = currency1.balanceOfSelf();
        newFeeValue = hook.lastSwapFee();

        console.log("Fee value after 3rd swap:", newFeeValue);

        assertLt(newFeeValue, initialFeeValue);
        assertLt(balanceOfToken1After, balanceOfToken1Before);
    }

    function test_constantFeeForSwapsInTheSameBlock() public {
        // 1. Increase block number
        vm.roll(block.number + 1);

        // 2. Conduct a (top of the block) swap that buys token1, increasing its price in pool
        // pool token1 price > oracle token1 price
        // Fee should be higher than base fee as the swap occurs in the arbitrage direction
        _executeSwap(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1);
        uint24 firstSwapFeeValue = hook.lastSwapFee();

        // 3 Conduct another swap in the same block with the same conditions as the previous one
        _executeSwap(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1);
        uint24 secondSwapFeeValue = hook.lastSwapFee();

        assertEq(firstSwapFeeValue, secondSwapFeeValue);
    }

    function test_feeEqualsBaseFeeIfOraclePriceIsDeprecated() public {
        // 1.1 Increase block number
        vm.roll(block.number + 1);
        // 1.2 Increase current timestamp to timeout value + 10 seconds
        vm.warp(OracleLib.getTimeout() + 10);

        // 2.1 Conduct a (top of the block) swap that buys token1, increasing its price in pool
        // pool token1 price > oracle token1 price
        // Normally, the fee would be higher than base fee as the swap occurs in the arbitrage direction
        // However, as the oracle price is deprecated, the fee should be equal to the base fee
        _executeSwap(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1);

        uint24 swapFeeValue = hook.lastSwapFee();
        assertEq(swapFeeValue, hook.baseFeeHbps());
    }

    function test_poolInstantiationFailsIfDynamicFeeFlagIsNotSet() public {
        vm.expectRevert();
        (key,) = initPool(currency0, currency1, hook, 500, SQRT_PRICE_1_1, ZERO_BYTES);
    }

    function test_useChainlinkPriceFeedIfCustomOraclePriceIsDeprecated() public {
        // 1. Increase block number
        vm.roll(block.number + 1);
        // 2. Increase timestamp to a value that makes chainlink price feed and custom oracle prices deprectaed
        vm.warp(10 minutes);
        // 3. Update chainlink price feed price
        int256 newChainlinkPriceFeedPrice = 3000e8;
        MockV3Aggregator priceFeed = MockV3Aggregator(ethUsdPriceFeed);
        priceFeed.updateAnswer(newChainlinkPriceFeedPrice);

        // 4. Conduct a (top of the block) swap that buys token1, increasing its price in pool
        // pool token1 price > oracle token1 price
        // Fee should be higher than base fee as the swap occurs in the arbitrage direction
        _executeSwap(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1);

        int256 lastOraclePriceUsed = int256(hook.lastPriceFromOracle());
        int256 decimalAdjustment = int256(
            10 ** (hook.BASE_TOKEN_DECIMALS() - hook.QUOTE_TOKEN_DECIMALS() - helperConfig.MOCK_ORACLE_DECIMALS())
        );
        int256 lastOraclePriceUsedAdjusted = lastOraclePriceUsed / decimalAdjustment;
        assertEq(lastOraclePriceUsedAdjusted, newChainlinkPriceFeedPrice);
    }

    function _executeSwap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) private {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    }
}
