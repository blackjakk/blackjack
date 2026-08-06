// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRandomnessProvider} from "../interfaces/IRandomnessProvider.sol";
import {IRandomnessConsumer} from "../interfaces/IRandomnessConsumer.sol";
import {IDrandOracleQuicknet} from "../interfaces/IDrandOracleQuicknet.sol";

/// @title DrandRandomnessProvider
/// @notice MegaETH testnet randomness adapter over the preinstalled DrandOracleQuicknet
///         verifier. Commit/reveal against the public drand quicknet beacon:
///
///         1. `requestRandomness` (called by the consumer in the same tx that locks all
///            outcome-relevant inputs) pins a FUTURE beacon round that drand has
///            provably not yet signed (current + minFutureRounds, official guidance
///            >= 2 on MegaETH), with an explicit publish-time tripwire.
///         2. Once the round publishes (~3-6 s), ANYONE fetches the 48-byte BLS
///            signature from api.drand.sh and calls `fulfill`.
///         3. The adapter verifies the beacon onchain and delivers the chain-scoped
///            canonical hash to the consumer exactly once.
///
///         Trust model, failure cases and the free-look liveness caveat are documented
///         in docs/RANDOMNESS.md. NOT audited; play-money use only.
contract DrandRandomnessProvider is IRandomnessProvider {
    struct Request {
        address consumer; // bound to msg.sender of requestRandomness
        uint64 revealRound; // exact round required — no other round is accepted
        bool fulfilled;
        uint256 gameId; // consumer-supplied tag, for offchain keepers/UIs
    }

    IDrandOracleQuicknet public immutable verifier;
    /// @notice Extra rounds of safety between commit time and the pinned round.
    ///         Official MegaETH guidance: >= 2 (one full round of slack against
    ///         timestamp races and mini-block reordering).
    uint64 public immutable minFutureRounds;

    uint256 public nextRequestId = 1;
    mapping(uint256 => Request) public requests;

    event RandomnessRequested(
        uint256 indexed requestId,
        address indexed consumer,
        uint256 indexed gameId,
        uint64 revealRound,
        uint256 publishTime
    );
    event RandomnessFulfilled(uint256 indexed requestId, uint64 revealRound, bytes32 seed);

    error ZeroAddress();
    error InvalidMinFutureRounds();
    error UnknownRequest(uint256 requestId);
    error AlreadyFulfilled(uint256 requestId);
    error RoundNotYetPublished(uint256 requestId, uint256 publishTime);
    error RoundAlreadyProducible(uint64 revealRound);
    error InvalidSignature(uint256 requestId, uint64 revealRound);

    constructor(IDrandOracleQuicknet verifier_, uint64 minFutureRounds_) {
        if (address(verifier_) == address(0)) revert ZeroAddress();
        if (minFutureRounds_ < 2) revert InvalidMinFutureRounds();
        verifier = verifier_;
        minFutureRounds = minFutureRounds_;
    }

    /// @notice Latest round drand may already have signed at the current timestamp.
    function currentRound() public view returns (uint64) {
        uint64 genesis = verifier.GENESIS_TIMESTAMP();
        uint64 period = verifier.PERIOD_SECONDS();
        if (block.timestamp < genesis) return 0;
        return uint64((block.timestamp - genesis) / period) + 1;
    }

    /// @notice Unix time at which `round` becomes producible by drand.
    function publishTime(uint64 round) public view returns (uint256) {
        return
            uint256(verifier.GENESIS_TIMESTAMP()) + uint256(round - 1) * verifier.PERIOD_SECONDS();
    }

    /// @inheritdoc IRandomnessProvider
    /// @dev Callable by anyone; the callback is bound to msg.sender, so requests from
    ///      other callers cannot affect the blackjack table. The caller must lock all
    ///      outcome-relevant inputs in this same transaction.
    function requestRandomness(uint256 gameId) external returns (uint256 requestId) {
        uint64 revealRound = currentRound() + minFutureRounds;

        // Official-guidance tripwire: the pinned round must be provably unsigned now.
        // Reverting loudly here beats silently committing to a producible round.
        if (publishTime(revealRound) <= block.timestamp) {
            revert RoundAlreadyProducible(revealRound);
        }

        requestId = nextRequestId++;
        requests[requestId] = Request({
            consumer: msg.sender, revealRound: revealRound, fulfilled: false, gameId: gameId
        });
        emit RandomnessRequested(
            requestId, msg.sender, gameId, revealRound, publishTime(revealRound)
        );
    }

    /// @notice Submit the drand beacon for a pending request. Permissionless: any
    ///         keeper, player, or bystander may fulfill; the seed is the same
    ///         regardless of who submits (beacon uniqueness + normalization).
    /// @param requestId The request to fulfill.
    /// @param sig       The beacon signature for the request's exact pinned round,
    ///                  as served by api.drand.sh (48-byte compressed G1 accepted;
    ///                  encoding differences are canonicalized by the verifier).
    function fulfill(uint256 requestId, bytes calldata sig) external {
        Request storage req = requests[requestId];
        if (req.consumer == address(0)) revert UnknownRequest(requestId);
        if (req.fulfilled) revert AlreadyFulfilled(requestId);

        // Freshness: a premature submission cannot succeed even with a forged sig path.
        uint256 pt = publishTime(req.revealRound);
        if (block.timestamp < pt) revert RoundNotYetPublished(requestId, pt);

        // Verify against the EXACT pinned round — never any other.
        (bool ok,, bytes32 chainScopedHash) = verifier.verifyNormalized(req.revealRound, sig);
        if (!ok) revert InvalidSignature(requestId, req.revealRound);

        // Effects before the external callback (CEI): a reentrant or duplicate call
        // now hits AlreadyFulfilled. If the consumer reverts (e.g. the game was
        // cancelled), the whole tx reverts atomically and the request stays open.
        req.fulfilled = true;

        IRandomnessConsumer(req.consumer).fulfillRandomness(requestId, chainScopedHash);
        emit RandomnessFulfilled(requestId, req.revealRound, chainScopedHash);
    }
}
