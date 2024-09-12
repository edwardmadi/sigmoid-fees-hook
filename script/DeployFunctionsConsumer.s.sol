// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {FunctionsConsumer} from "../src/FunctionsConsumer.sol";

contract DeployFunctionsConsumer is Script {
    function run() external returns (FunctionsConsumer, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();

        (,, address router, bytes32 donID,, uint256 deployerKey) = helperConfig.activeNetworkConfig();
        vm.startBroadcast(deployerKey);
        FunctionsConsumer functionsConsumer = new FunctionsConsumer(router, donID);
        vm.stopBroadcast();
        return (functionsConsumer, helperConfig);
    }
}
