// SPDX-License-Identifier: MIT
// Sepolia address: 0xddc2e9aae870617c91fa417809b14cfde4f76181
// Sepolia automation upkeep address: 0xddc2e9aae870617c91fa417809b14cfde4f76181 

pragma solidity ^0.8.19;

import { FunctionsClient } from "chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import { ConfirmedOwner } from "chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import { FunctionsRequest } from "chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

contract FunctionsConsumer is FunctionsClient, ConfirmedOwner {
    using FunctionsRequest for FunctionsRequest.Request;

    struct PriceData {
        string price;
        uint256 timestamp;
    }

    // State variables to store the last request ID, response, and error
    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;

    // Custom error type
    error UnexpectedRequestID(bytes32 requestId);

    // Event to log responses
    event Response(
        bytes32 indexed requestId,
        string price,
        bytes response,
        bytes err
    );

    string public source = 
        "const apiResponse = await Functions.makeHttpRequest({"
        "url: `https://min-api.cryptocompare.com/data/pricemultifull?fsyms=ETH&tsyms=USD`" 
        "});"
        "if (apiResponse.error) {" 
        "throw Error('Request failed');"
        "}" 
        "const { data } = apiResponse;"
        "const price = String(data.RAW.ETH.USD.PRICE).split('.');"
        "const priceParsed = `${price[0]}${price[1]}`;"
        "return Functions.encodeString(priceParsed)";

    // Callback gas limit
    uint32 public gasLimit = 300_000;

    // Check to get the donID for your supported network https://docs.chain.link/chainlink-functions/supported-networks
    bytes32 public donID;

    // State variable to store the returned price information
    PriceData public priceData;

    /**
     * @notice Initializes the contract with the Chainlink router address and sets the contract owner
     */
    constructor(address _router, bytes32 _donID) FunctionsClient(_router) ConfirmedOwner(msg.sender) {
      donID = _donID;
    }

    /**
     * @notice Sends an HTTP request for price information
     * @param subscriptionId The ID for the Chainlink subscription
     * @param args The arguments to pass to the HTTP request
     * @return requestId The ID of the request
     */
    function sendRequest(
        uint64 subscriptionId,
        string[] calldata args
    ) external returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source); // Initialize the request with JS code
        if (args.length > 0) req.setArgs(args); // Set the arguments for the request

        // Send the request and store the request ID
        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            gasLimit,
            donID
        );

        return s_lastRequestId;
    }

    /**
     * @notice Callback function for fulfilling a request
     * @param requestId The ID of the request to fulfill
     * @param response The HTTP response data
     * @param err Any errors from the Functions request
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (s_lastRequestId != requestId) {
            revert UnexpectedRequestID(requestId); // Check if request IDs match
        }
        // Update the contract's state variables with the response and any errors
        s_lastResponse = response;
        string memory _price = string(response);
        priceData = PriceData(_price, block.timestamp);
        s_lastError = err;

        // Emit an event to log the response
        emit Response(requestId, _price, s_lastResponse, s_lastError);
    }


}
