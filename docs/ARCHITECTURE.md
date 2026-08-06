# Architecture

Status: MVP design, play-money only. Not audited, not production-ready.

## Goal

Validate, end to end on MegaETH testnet: onchain game logic, transaction
flow, verifiable randomness integration, bankroll accounting, frontend UX,
and an agent-facing SDK — using a valueless test ERC-20 chip.

## Components

```
┌─────────────┐   approve/bet/act    ┌──────────────────┐
│  Player     │─────────────────────▶│  BlackjackTable   │
│ (wallet/bot)│◀──── payouts ────────│  - state machine  │
└─────────────┘                      │  - escrow         │
                                     │  - house bankroll │
┌─────────────┐  requestRandomness   │  - settlement     │
│ Keeper (any │◀─────────────────────│                   │
│ EOA; house  │  fulfill(seed) ─────▶│                   │
│ runs one)   │                      └───────┬───────────┘
└──────┬──────┘                              │ transferFrom / transfer
       │ fetch beacon                ┌───────▼───────────┐
       ▼                             │  TestChip (ERC20) │
  api.drand.sh                       └───────────────────┘
       │ verify sig
       ▼
┌────────────────────────┐   verifyNormalized   ┌──────────────────────────┐
│ DrandRandomnessProvider │────────────────────▶│ DrandOracleQuicknet       │
│ (our adapter)           │                     │ (MegaETH preinstalled     │
└────────────────────────┘                     │  BLS12-381 verifier)      │
                                               └──────────────────────────┘
```

### Contracts (`packages/contracts`)

| Contract | Responsibility |
| --- | --- |
| `TestChip.sol` | Vanilla OZ ERC-20 with rate-limited public faucet. No transfer hooks, no fees. 18 decimals. |
| `BlackjackTable.sol` | Game state machine, wager escrow, house-liability reservation, dealer logic, settlement, timeouts, pause, roles. Holds the house bankroll. |
| `interfaces/IRandomnessProvider.sol` | `requestRandomness(uint256 gameId) → uint256 requestId`. |
| `interfaces/IRandomnessConsumer.sol` | Callback the table implements: `fulfillRandomness(uint256 requestId, bytes32 seed)`. |
| `rand/MockRandomnessProvider.sol` | Deterministic provider for unit tests and local dev. Fulfillment is an explicit test-controlled call. |
| `rand/DrandRandomnessProvider.sol` | Testnet adapter around MegaETH's preinstalled `DrandOracleQuicknet`. Commit-to-future-round on request; permissionless beacon submission fulfills. |
| `lib/BlackjackLib.sol` | Card derivation from seeds, packed hand storage, hand valuation (soft/hard), dealer draw rule, outcome comparison. Pure functions only. |

### Randomness flow (see RANDOMNESS.md for the full design)

1. `BlackjackTable` locks all outcome-relevant inputs (wager, action) and calls
   `requestRandomness(gameId)` in the same transaction.
2. The drand adapter pins `revealRound = currentRound + 2` (a round drand has
   **not yet signed**) and emits `RandomnessRequested`.
3. Once the round publishes (~3–6 s), **anyone** fetches the 48-byte BLS
   signature from `api.drand.sh` and calls `fulfill(requestId, sig)`.
4. The adapter verifies via `DrandOracleQuicknet.verifyNormalized` and calls
   the table back exactly once with a chain-scoped 32-byte seed.
5. The table expands one seed into as many cards as the phase needs via
   `keccak256(seed, nonce)`.

Rule: **every card-revealing phase uses a seed committed after the player's
latest irreversible action.** Otherwise a player could precompute future
cards (e.g. the dealer's whole hand) and play with perfect information.

### Accounting model

All chips sit in `BlackjackTable`. Three explicitly tracked quantities:

| Variable | Meaning |
| --- | --- |
| `houseFunds` | Chips owned by the house. Increased by `fundHouse` deposits and player losses; decreased by house-paid winnings and `withdrawHouseFunds`. |
| `totalPlayerEscrow` | Sum of all active wagers (player-owned until settlement). |
| `totalReservedLiability` | Sum of per-game worst-case house payouts for all unsettled games. |

Derived: `availableLiquidity = houseFunds − totalReservedLiability`.

* A bet of `W` reserves **`2 × W`** of house funds up front — the worst case
  across all future paths (3:2 natural pays `1.5 W`; a doubled win pays
  `2 W`). Conservative over-reservation is deliberate: **double down can
  never fail for liquidity reasons**, and the invariant set stays simple.
* Bets that cannot be fully covered (`2W > availableLiquidity`) revert.
* `withdrawHouseFunds` (treasury role) is capped at `availableLiquidity` —
  reserved and escrowed funds are unreachable by any privileged account.
* `balanceOf(table) ≥ houseFunds + totalPlayerEscrow` always (`≥` because
  anyone can donate tokens directly; donations are simply dead weight until
  swept by... nobody — they are not credited to `houseFunds`).

### Invariants (enforced in Foundry invariant tests)

1. `chip.balanceOf(table) ≥ totalPlayerEscrow + houseFunds`
2. `totalReservedLiability ≤ houseFunds`
3. A game settles at most once; settled/cancelled games accept no actions.
4. Treasury can never withdraw below `totalReservedLiability + totalPlayerEscrow`.
5. Per game: `payout ≤ escrow + reservedLiability` at settlement.

### Frontend (`apps/web`)

Next.js + wagmi + viem. Reads authoritative state **only** from the chain:
contract view calls + event logs (`eth_getLogs` / `watchContractEvent`).
There is no backend service that decides cards, outcomes or payouts; the only
offchain actor is the permissionless beacon submitter. The UI displays a
persistent "testnet play money" banner, wallet/chip balances, faucet, house
liquidity, bet limits, hand state, action buttons, transaction + randomness
status, final result, and explorer links.

### SDK (`packages/sdk`)

Thin viem-based client exposing: table config reads, liquidity reads, game
lifecycle (`startGame`, `hit`, `stand`, `double`), state polling/event
waiting, randomness-fulfillment waiting, result retrieval, and an optional
keeper helper (fetch drand beacon → submit `fulfill`). A deterministic
basic-strategy bot consumes only this SDK.

### Indexing

MVP uses direct event queries via viem (`getLogs` from the game's start
block). No separate indexer process. Event schema is designed so a future
indexer can reconstruct full game history from logs alone.

## MegaETH specifics (verified 2026-08 against docs.megaeth.com)

* Testnet chain ID **6343** (`0x18c7`), RPC `https://carrot.megaeth.com/rpc`,
  explorer `https://testnet-mega.etherscan.io`. (The 6342 testnet is
  deprecated.)
* Mini-blocks ~10 ms; EVM blocks 1 s; base-fee adjustment disabled.
* `DrandOracleQuicknet` preinstalled at
  `0x4e1673dcAA38136b5032F27ef93423162aF977Cc` (testnet) /
  `0x7a53a6eFA81c426838fcf4824E6e207923969b36` (mainnet).
* Testnet may be rolled back during upgrades (per official docs) — game
  history is not durable.

## Explicit non-goals (v1)

Splitting, insurance, surrender, tournaments, LP vaults, real-money deposits,
upgradeable contracts, a persistent finite shoe (see KNOWN_LIMITATIONS.md).
