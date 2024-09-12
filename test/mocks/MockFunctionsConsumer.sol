// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

contract MockFunctionsConsumer {
    struct PriceData {
        string price;
        uint256 timestamp;
    }

    PriceData public priceData;

    constructor(string memory _initialPrice) {
        updateAnswer(_initialPrice);
    }

    function updateAnswer(string memory _price) public {
        priceData.price = _price;
        priceData.timestamp = block.timestamp;
    }
}
