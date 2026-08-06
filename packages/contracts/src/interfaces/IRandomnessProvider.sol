// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IRandomnessProvider
/// @notice Modular randomness source. A consumer requests randomness for a game and is
///         later called back exactly once via {IRandomnessConsumer.fulfillRandomness}.
interface IRandomnessProvider {
    function requestRandomness(uint256 gameId) external returns (uint256 requestId);
}
