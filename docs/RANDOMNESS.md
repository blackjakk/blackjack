# Randomness Design & Trust Assumptions

## Requirements

* No timestamps, blockhashes, `block.prevrandao`, or other
  sequencer-influenced values as a source of card entropy.
* The wager (and every subsequent action) must be committed and locked
  **before** the randomness that resolves it becomes available.
* Modular: the table talks to an `IRandomnessProvider`; providers are
  swappable without touching game logic.

## Interface

```solidity
interface IRandomnessProvider {
    function requestRandomness(uint256 gameId) external returns (uint256 requestId);
}

interface IRandomnessConsumer {
    function fulfillRandomness(uint256 requestId, bytes32 seed) external;
}
```

The table stores, per game, the provider address used at request time and the
pending `requestId`. Fulfillment must come from exactly that provider with
exactly that id, once. Swapping the table's provider (admin) affects only
future requests; in-flight requests still settle through the provider that
created them, so a swap cannot strand or hijack a live hand.

## Providers

### 1. `MockRandomnessProvider` (local dev + tests)

Deterministic and test-controlled: `requestRandomness` records the request;
the test (or a dev script) calls `fulfill(requestId, seed)` with a chosen
seed, which calls back into the consumer. Never deploy to a public network
as the table's provider — it is trivially manipulable by whoever may call
`fulfill`.

### 2. `DrandRandomnessProvider` (MegaETH testnet adapter)

Built on **`DrandOracleQuicknet`**, the VRF verifier MegaETH preinstalls at a
fixed address on every network (verified against
[docs.megaeth.com/developer-docs/vrf](https://docs.megaeth.com/developer-docs/vrf),
2026-08):

| Network | Chain ID | Address |
| --- | --- | --- |
| MegaETH Testnet | 6343 | `0x4e1673dcAA38136b5032F27ef93423162aF977Cc` |
| MegaETH Mainnet | 4326 | `0x7a53a6eFA81c426838fcf4824E6e207923969b36` |

It is a stateless BLS12-381 pairing verifier (via EIP-2537 precompiles) for
the public **drand quicknet** beacon: a new 48-byte G1 signature every 3
seconds, produced by the League of Entropy threshold network, downloadable
by anyone from `api.drand.sh` (chain hash
`52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971`).

Adapter behavior:

1. **Request** (called by the table, same tx as the player's committed
   action): compute `currentRound` from the verifier's
   `GENESIS_TIMESTAMP()`/`PERIOD_SECONDS()`, pin
   `revealRound = currentRound + MIN_FUTURE_ROUNDS` (`≥ 2`, per official
   guidance, so the round is provably unsigned at commit time), and
   `require(publishTime(revealRound) > block.timestamp)` as a tripwire.
   Store `{consumer, gameId, revealRound}`; emit `RandomnessRequested`.
2. **Fulfill** (permissionless): anyone submits
   `fulfill(requestId, signature)`. The adapter requires
   `block.timestamp ≥ publishTime(revealRound)` (freshness), requires the
   request to be unfulfilled, **marks it fulfilled before any external
   call**, verifies via `verifyNormalized(revealRound, sig)` and passes the
   returned **chain-scoped hash** (3rd return value) to the consumer. The
   chain-scoped hash binds the seed to (chain, verifier), preventing
   cross-chain/cross-contract replay; `verifyNormalized` also canonicalizes
   compressed vs uncompressed signature encodings so a submitter cannot
   choose between two different seeds for the same beacon.
3. **Exact round only.** The stored round is the only round accepted —
   a submitter can never pick among several published rounds.

### Seed → cards

Each fulfillment delivers one 32-byte seed. The table derives the i-th card
of that phase as `uint8(uint256(keccak256(abi.encodePacked(seed, i))) % 52)`.

* Modulo bias: `2^256 mod 52 ≠ 0`, but the bias is < 2^-250 — cryptographically
  irrelevant. Documented for completeness.
* Sampling is **with replacement** (an "infinite shoe"): duplicate cards
  beyond a real 6-deck shoe's counts are possible. Accepted MVP limitation —
  see KNOWN_LIMITATIONS.md — isolated behind `BlackjackLib.drawCard` so a
  finite-shoe implementation can replace it.
* **Fresh seed per decision point.** Initial deal, every hit, the double
  card, and the dealer's draw each consume a separate committed seed. A seed
  is never reused across phases: reusing (say) the initial seed for dealer
  cards would let the player compute the dealer's final hand before choosing
  to hit or stand.

## Timing (drand quicknet + MegaETH)

Commit tx → round published: 3–6 s (round cadence is fixed at 3 s; +2 round
safety margin). Beacon on API: <1 s later. Fulfill tx: one mini-block
(~10 ms). Practical end-to-end: **~4–7 s per randomness round-trip**.

## Failure cases & designed behavior

| Failure | Behavior |
| --- | --- |
| Beacon never submitted (keeper down, drand stalled) | After `randomnessTimeout` (default 1 hour) the player or admin can `cancelTimedOutGame`: full escrow refund, reservation released, game CANCELLED. No cards are ever revealed onchain for that request. |
| Duplicate fulfillment | Second call reverts: the request is marked fulfilled before the callback (adapter) and the pending request id is cleared before card effects (table). |
| Fulfillment for a cancelled/settled game | Table reverts (`InvalidState` / stale request id); the adapter's callback attempt fails loudly and changes nothing. |
| Invalid signature | `verifyNormalized` returns false → fulfill reverts; request stays open for a correct submission. |
| drand round missed / drand outage | Round signatures are eventually produced or the timeout path applies. The adapter never re-targets a different round for an existing request. |
| Provider swapped mid-game | In-flight requests still fulfill via the provider bound at request time. |

## Trust assumptions (read before relying on this)

1. **drand threshold honesty.** Card entropy is exactly as good as drand
   quicknet: if a threshold of League of Entropy nodes colluded they could
   withhold (not bias — BLS signatures are unique) beacons. Withholding maps
   to the timeout/refund path, not to biased cards.
2. **Beacon publicity ⇒ free-look liveness assumption.** Once the committed
   round publishes, the resulting cards are computable **offchain by
   anyone** — including the player — before the fulfill tx lands. A player
   whose pending card is bad could refuse to submit and hope to reach the
   cancel timeout for a refund ("free look"). Mitigations: fulfillment is
   permissionless, the house is expected to run a keeper that submits every
   beacon within seconds, and the timeout is long (default 1 hour). **The
   house-keeper-liveness assumption is the main unresolved liveness
   assumption of this MVP** and is inherent to any public-beacon design
   without slashing. It is player-favorable only; the house cannot use it to
   escape a losing hand, because anyone may submit the beacon and cancelling
   refunds the player in full.
3. **MegaETH sequencer liveness & timestamp sanity.** Round arithmetic uses
   `block.timestamp`. A sequencer outage delays fulfillment and timeouts but
   cannot create card bias (the round is pinned). Official docs warn testnet
   state may be rolled back during upgrades.
4. **`DrandOracleQuicknet` correctness.** We treat the preinstalled verifier
   like a precompile (as the official docs recommend). It is stateless, has
   no owner/upgrade path, and its source is published (Zodomo/DrandVerifier),
   but we have not audited it.

## Production readiness

**Not production-ready.** The drand adapter follows the officially documented
MegaETH integration pattern, but neither the adapter, the table, nor the
verifier has been audited; the free-look/keeper assumption above is
acceptable for play money only. For a real-money deployment you would need,
at minimum: an audit, an incentivized/redundant keeper design, a bonded or
penalized cancel path, and a finite-shoe fairness review.
