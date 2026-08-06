# Threat Model

Scope: `TestChip`, `BlackjackTable`, `MockRandomnessProvider`,
`DrandRandomnessProvider`, and their interaction with MegaETH testnet and
the drand quicknet beacon. Play-money deployment; the assets at stake are
valueless test chips, but the model is written as if they mattered.

## Actors

| Actor | Capabilities | Trust |
| --- | --- | --- |
| Player | Any EOA/contract; adaptive; may run many addresses; sees all public chain + drand data | Untrusted |
| Beacon submitter / keeper | Anyone; can submit or withhold fulfill txs | Untrusted individually; **liveness of at least one honest submitter is assumed** |
| drand network | Produces beacons; threshold-BLS | Trusted for unbiasability (BLS uniqueness); trusted-majority for liveness |
| Admin (`DEFAULT_ADMIN_ROLE`) | Pause, set limits/timeout/provider, cancel stuck games | Trusted for liveness, **not** trusted with player funds (enforced in code) |
| Treasury (`TREASURY_ROLE`) | Fund house, withdraw *available* house funds | Same |
| MegaETH sequencer | Orders txs, sets timestamps | Trusted for liveness/ordering; cannot bias pinned drand rounds |
| TestChip | Our own vanilla OZ ERC-20 | Trusted (no hooks, no fees, no rebasing) |

## Threats & mitigations

### T1 — Randomness prediction / bias
Player predicts or influences cards.
* Rounds pinned at request time to a provably unsigned future round
  (`+2` rounds, tripwire `require(publishTime > now)`).
* Wager and each action are locked in the same tx that requests the seed.
* Exact-round matching; chain-scoped normalized hash; BLS uniqueness makes
  the beacon unbiasable even by drand members.
* Fresh seed per decision point — no seed ever reveals cards for a later
  phase (T11 in RANDOMNESS.md: reusing the deal seed for the dealer would
  hand the player perfect information).
* Residual: none known beyond drand threshold collusion (withholding only).

### T2 — Free look via withheld fulfillment (main residual risk)
After the committed round publishes, the player can compute the pending
card(s) offchain. If the result is bad they can decline to submit and try to
reach the cancel timeout for a full refund.
* Fulfillment is permissionless; the house keeper submits every beacon
  within seconds; timeout is long (1 h default) — the player would need
  every other submitter to stay silent for the entire window.
* Cancel refunds the stake only — the player never extracts winnings this
  way; it converts a (probabilistically) losing hand into a push.
* **Accepted for play money; documented liveness assumption.** A bonded
  cancel or keeper incentives would be needed for real money.

### T3 — Double settlement / duplicate callbacks
* Adapter marks a request fulfilled before the callback (CEI).
* Table clears the pending request id and transitions state before dealing
  cards or paying out; terminal states reject everything.
* Settlement pays out exactly once inside the state transition to SETTLED.
* Invariant tests assert a game can never pay twice.

### T4 — Reentrancy
* `nonReentrant` on every external state-mutating entry point;
  checks-effects-interactions throughout; the only external calls are
  TestChip (vanilla OZ ERC-20, no hooks), the stored randomness provider,
  and the stateless verifier.
* Adversarial tests use a malicious consumer/provider and a hook-simulating
  token to attempt reentry.

### T5 — Admin/treasury abuse
* No function transfers escrowed wagers or reserved liabilities to any
  privileged account: `withdrawHouseFunds` is capped at
  `houseFunds − totalReservedLiability`, and escrow is not part of
  `houseFunds` at all.
* Admin cancel of a stuck game only **refunds the player** — it cannot
  redirect funds.
* Pause cannot trap funds (fulfill/stand/cancel remain open).
* Roles are separate: game/config admin vs treasury; deployer must be able
  to renounce either independently.
* Residual: admin can pause new games and set limits; a malicious admin can
  grief UX but not steal.

### T6 — Insolvency / unpayable wins
* Worst-case liability (`2×wager`) reserved at bet time; bets revert when
  `availableLiquidity` is insufficient; reservation released only at
  settlement/cancel. Invariant: reserved ≤ houseFunds.

### T7 — Stuck games (drand stall, keeper death, sequencer outage)
* Timeout + cancel path per game; player and admin can both trigger it.
* Pause does not block winding down.
* Residual: during a sequencer outage nothing moves (including timeouts) —
  inherited chain-level assumption.

### T8 — Multi-game / multi-address games
* One active game per address, enforced. Sybil addresses gain nothing:
  games are independent and the edge is the house's regardless of address
  count.

### T9 — Token-level attacks
* TestChip is a fixed, vanilla OZ ERC-20 with a rate-limited faucet; no
  fee-on-transfer/rebasing/hooks. SafeERC20 everywhere anyway. The table is
  not designed for arbitrary third-party tokens — deploying it with a
  nonstandard token is out of scope and unsupported.
* Faucet abuse: unlimited play money is the point; the faucet is
  rate-limited per address only to keep the UX sane. The house bankroll is
  funded by the same valueless token, so "draining" it has no monetary
  meaning.

### T10 — Griefing the beacon submitter
* An attacker could front-run a keeper's fulfill tx. Outcome: identical
  (the seed is the same beacon); wasted keeper gas only.

### T11 — MegaETH testnet rollbacks
* Official docs state contracts/state may be rolled back in rare cases.
  Game history and balances are not durable. Play-money accepted risk.

## Out of scope (v1)
Real-money economics, MEV on mainnet, LP/vault attacks, oracle-price
attacks (no prices used), governance attacks (no governance), upgradeability
(none), cross-chain replay (chain-scoped hashes already prevent beacon
replay).
