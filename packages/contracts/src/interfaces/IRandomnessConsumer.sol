// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IRandomnessConsumer
/// @notice Implemented by contracts that consume randomness (the blackjack table).
///         The provider that served `requestId` calls back exactly once with the seed.
interface IRandomnessConsumer {
    function fulfillRandomness(uint256 requestId, bytes32 seed) external;
}
