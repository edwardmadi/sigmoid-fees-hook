// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {DynamicSigmoidFeesHook} from "../src/DynamicSigmoidFeesHook.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";

contract TestDynamicSigmoidFeesHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    DynamicSigmoidFeesHook hook;
    HelperConfig public helperConfig;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        helperConfig = new HelperConfig();

        // Deploy our hook with the proper flags
        address hookAddress = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));

        (address ethUsdPriceFeed, address weth,,, address functionsConsumer, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        // console.log("ETH/USD price feed:", ethUsdPriceFeed);
        // console.log("DEFAULT_BASE_FEE_HBPS:", helperConfig.DEFAULT_BASE_FEE_HBPS());
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

        // starting pool price: 1 USDC = 2374,380330 WETH
        // starting oracle price: 1 USDC = 1,000000 WETH
        // STARTING WITH HUGE PRRICE DELTA -> AFTER 1st SWAP, POOL PRICE WILL MOVE TO THE LIQUIDITY RANGE PROVIDED - CLOSE TO ORACLE PRICE

        // 1. Conduct a swap that buys token1, increasing its price in pool (pool instantiation block)
        // Fee should be equal to `BASE_FEE` since it's the 1st swap and the fee wasn't yet updated

        // Set up our swap parameters
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap 0.1 ether token 0 for token 1 (price token1 up)
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        uint24 initialFeeValue = hook.lastSwapFee();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
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
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
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
        IPoolManager.SwapParams memory sellParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        balanceOfToken1Before = currency1.balanceOfSelf();
        initialFeeValue = hook.lastSwapFee();
        swapRouter.swap(key, sellParams, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();
        newFeeValue = hook.lastSwapFee();

        console.log("Fee value after 3rd swap:", newFeeValue);

        assertLt(newFeeValue, initialFeeValue);
        assertLt(balanceOfToken1After, balanceOfToken1Before);
    }
}
