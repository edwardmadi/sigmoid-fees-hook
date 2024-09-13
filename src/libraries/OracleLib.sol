// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// TODO:
// 1 - Create MockFunctionsCosumemer + adapt oracle lib to use it - OK
// 2 - Fine tune the timeout - OK
// 3 - Set up automation for chainlink function as oracle - OK
// 4 - Add tests for price correctness/ failsafe mechanisms - OK
// 5 - Deploy univ4 (?) + hooks to sepolia and test there
// 6 - Create tests for testnet/testnetfork(?)
// 7 - Clean up code + add comments
// 8 - Add POC for protocol fees
// ---------- Sunday ----------
// 9 - Gather some analytics cool charts and prepare presentation
// 10 - Record presentation

import {FunctionsConsumer} from "../FunctionsConsumer.sol";
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/*
 * @title OracleLib
 * @notice This library is used to check the Chainlink Oracle for stale data.
 * If a price is stale, functions will revert, and render the DSCEngine unusable - this is by design.
 *
 * So if the Chainlink network explodes and you have a lot of money locked in the protocol... too bad.
 */

library OracleLib {
    error OracleLib__InvalidCharInString();

    uint256 private constant TIMEOUT = 5 minutes;
    uint8 private constant CUSTOM_ORACLE_DECIMALS = 8;

    function checkChainlinkLatestRoundData(AggregatorV3Interface chainlinkFeed) public view returns (bool) {
        (uint80 roundId,,, uint256 updatedAt, uint80 answeredInRound) = chainlinkFeed.latestRoundData();

        if (updatedAt == 0 || answeredInRound < roundId) {
            return false;
        }

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) return false;

        return true;
    }

    function checkCustomOracleLatestRoundData(FunctionsConsumer functionsConsumer) public view returns (bool) {
        (, uint256 timestamp) = functionsConsumer.priceData();

        uint256 secondsSince = block.timestamp - timestamp; // block.timestamp can be manipulated. This is a POC.
        if (secondsSince > TIMEOUT) return false;

        return true;
    }

    function getCustomOracleLatestPrice(FunctionsConsumer functionsConsumer) public view returns (uint256) {
        (string memory _priceStr,) = functionsConsumer.priceData();
        return stringToUint(_priceStr);
    }

    function getCustomOracleDecimals() public pure returns (uint8) {
        return CUSTOM_ORACLE_DECIMALS;
    }

    function getTimeout() public pure returns (uint256) {
        return TIMEOUT;
    }

    function stringToUint(string memory s) public pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint256 c = uint256(uint8(b[i]));
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
        return result;
    }
}
