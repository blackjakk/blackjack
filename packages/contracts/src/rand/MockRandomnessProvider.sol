// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRandomnessProvider} from "../interfaces/IRandomnessProvider.sol";
import {IRandomnessConsumer} from "../interfaces/IRandomnessConsumer.sol";

/// @title MockRandomnessProvider
/// @notice Deterministic, test-controlled randomness provider for unit tests and local
///         development. Fulfillment is an explicit call with a chosen seed.
/// @dev NEVER configure this provider on a public network: anyone allowed to call
///      `fulfill` fully controls the cards. `fulfillUnchecked` exists solely so the
///      test suite can exercise the consumer's own duplicate-callback protection.
contract MockRandomnessProvider is IRandomnessProvider {
    struct Request {
        address consumer;
        uint256 gameId;
        bool fulfilled;
    }

    uint256 public nextRequestId = 1;
    mapping(uint256 => Request) public requests;

    event RandomnessRequested(
        uint256 indexed requestId, address indexed consumer, uint256 indexed gameId
    );
    event RandomnessFulfilled(uint256 indexed requestId, bytes32 seed);

    error UnknownRequest(uint256 requestId);
    error AlreadyFulfilled(uint256 requestId);

    /// @inheritdoc IRandomnessProvider
    function requestRandomness(uint256 gameId) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        requests[requestId] = Request({consumer: msg.sender, gameId: gameId, fulfilled: false});
        emit RandomnessRequested(requestId, msg.sender, gameId);
    }

    /// @notice Fulfill a pending request with a chosen seed (test/dev only).
    function fulfill(uint256 requestId, bytes32 seed) external {
        Request storage req = requests[requestId];
        if (req.consumer == address(0)) revert UnknownRequest(requestId);
        if (req.fulfilled) revert AlreadyFulfilled(requestId);
        req.fulfilled = true;
        IRandomnessConsumer(req.consumer).fulfillRandomness(requestId, seed);
        emit RandomnessFulfilled(requestId, seed);
    }

    /// @notice Test-only: attempt a callback WITHOUT the provider-side duplicate guard,
    ///         to prove the consumer rejects duplicates on its own.
    function fulfillUnchecked(uint256 requestId, bytes32 seed) external {
        Request storage req = requests[requestId];
        if (req.consumer == address(0)) revert UnknownRequest(requestId);
        IRandomnessConsumer(req.consumer).fulfillRandomness(requestId, seed);
    }
}
