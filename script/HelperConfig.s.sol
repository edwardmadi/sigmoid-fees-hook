// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockFunctionsConsumer} from "../test/mocks/MockFunctionsConsumer.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    uint8 public constant MOCK_ORACLE_DECIMALS = 8;
    int256 public constant MOCK_PRICE_FEED_ETH_USD_PRICE = 2374e8;
    // string public constant MOCK_CUSTOM_ORACLE_ETH_USD_PRICE = "200042190196";
    string public constant MOCK_CUSTOM_ORACLE_ETH_USD_PRICE = "234242190196";

    address public constant SEPOLIA_FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    bytes32 public constant SEPOLIA_DON_ID = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;

    uint24 public constant DEFAULT_BASE_FEE_HBPS = 500;

    struct NetworkConfig {
        address ethUsdPriceFeed;
        address weth;
        address functionsRouter;
        bytes32 donID;
        address functionsConsumer;
        uint256 deployerKey;
    }

    uint256 public DEFAULT_ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    constructor() {
        if (block.chainid == 11_155_111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory sepoliaNetworkConfig) {
        sepoliaNetworkConfig = NetworkConfig({
            ethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // ETH / USD
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            functionsRouter: SEPOLIA_FUNCTIONS_ROUTER,
            donID: SEPOLIA_DON_ID,
            functionsConsumer: 0x2bf1e218991FdB116F4eB7A2ACD8ee067a5669DE,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory anvilNetworkConfig) {
        // Check to see if we set an active network config
        if (activeNetworkConfig.ethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(MOCK_ORACLE_DECIMALS, MOCK_PRICE_FEED_ETH_USD_PRICE);
        ERC20Mock wethMock = new ERC20Mock();
        MockFunctionsConsumer functionsConsumer = new MockFunctionsConsumer(MOCK_CUSTOM_ORACLE_ETH_USD_PRICE);

        vm.stopBroadcast();

        anvilNetworkConfig = NetworkConfig({
            ethUsdPriceFeed: address(ethUsdPriceFeed), // ETH / USD
            weth: address(wethMock),
            functionsRouter: 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0, // Does not exist in Anvil - mock addr
            donID: 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000, // Does not exist in Anvil - mock addr
            functionsConsumer: address(functionsConsumer),
            deployerKey: DEFAULT_ANVIL_PRIVATE_KEY
        });
    }
}
