// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IDrandOracleQuicknet
/// @notice Interface of MegaETH's preinstalled stateless drand quicknet verifier
///         (BLS12-381 via EIP-2537). Verified against the official MegaETH docs
///         (docs.megaeth.com/developer-docs/vrf) and the live testnet deployment:
///         testnet (6343): 0x4e1673dcAA38136b5032F27ef93423162aF977Cc
///         mainnet (4326): 0x7a53a6eFA81c426838fcf4824E6e207923969b36
interface IDrandOracleQuicknet {
    /// @notice drand quicknet round period — 3 seconds.
    function PERIOD_SECONDS() external pure returns (uint64);

    /// @notice Unix timestamp of quicknet round 1 — 1692803367.
    function GENESIS_TIMESTAMP() external pure returns (uint64);

    /// @notice The 32-byte digest drand signs for a given round.
    function roundMessageHash(uint64 round) external pure returns (bytes32);

    /// @notice Verify a beacon signature and return canonical randomness.
    /// @return ok            true iff `sig` is the valid beacon for `round`
    /// @return normalizedRoundHash encoding-invariant hash of the beacon
    /// @return chainScopedHash     normalized hash additionally bound to this chain and
    ///                             verifier — the correct value to consume as randomness
    function verifyNormalized(uint64 round, bytes calldata sig)
        external
        view
        returns (bool ok, bytes32 normalizedRoundHash, bytes32 chainScopedHash);
}
