// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDrandOracleQuicknet} from "../../src/interfaces/IDrandOracleQuicknet.sol";

/// @notice Test double for MegaETH's DrandOracleQuicknet with the real quicknet
///         parameters (3 s period, genesis 1692803367). A signature is "valid" iff it
///         equals `sigFor(round)`; the chain-scoped hash derivation mirrors the real
///         verifier's shape (bound to round, verifier address and chainid).
contract MockDrandVerifier is IDrandOracleQuicknet {
    uint64 internal constant PERIOD = 3;
    uint64 internal constant GENESIS = 1692803367;

    function PERIOD_SECONDS() external pure returns (uint64) {
        return PERIOD;
    }

    function GENESIS_TIMESTAMP() external pure returns (uint64) {
        return GENESIS;
    }

    function roundMessageHash(uint64 round) public pure returns (bytes32) {
        return sha256(abi.encodePacked(round));
    }

    /// @notice The unique "signature" this mock accepts for a round.
    function sigFor(uint64 round) public pure returns (bytes memory) {
        return abi.encodePacked(keccak256(abi.encode("beacon", round)));
    }

    function verifyNormalized(uint64 round, bytes calldata sig)
        external
        view
        returns (bool ok, bytes32 normalizedRoundHash, bytes32 chainScopedHash)
    {
        ok = keccak256(sig) == keccak256(sigFor(round));
        if (ok) {
            normalizedRoundHash = keccak256(abi.encode("normalized", round));
            chainScopedHash =
                keccak256(abi.encode("scoped", round, address(this), block.chainid));
        }
    }
}
