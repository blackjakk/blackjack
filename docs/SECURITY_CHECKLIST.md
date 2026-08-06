# Security Checklist (pre-testnet-deploy)

Status legend: [ ] open, [x] done, [~] partially / documented residual.

## Contracts
- [x] All state-mutating externals `nonReentrant`; CEI ordering verified (Adversarial.t.sol)
- [x] No `tx.origin`
- [x] No delegatecall / arbitrary external calls (only chip, bound provider, stateless verifier)
- [x] SafeERC20 for every token transfer; return values checked
- [x] All state transitions guarded (`InvalidState` on everything else) (StateMachine.t.sol)
- [x] One pending randomness request per game; exact requestId + provider match
- [x] Request cleared before card effects; adapter marks fulfilled before callback
- [x] Settlement reachable exactly once per game (invariant + unit tests)
- [x] Reserved liabilities ≥ worst-case payout path for every live game (2x wager upfront)
- [x] `withdrawHouseFunds` capped at available liquidity (escrow + reserved untouchable)
- [x] No admin path that moves player escrow anywhere but back to the player
- [x] Pause blocks new risk only; wind-down and refunds always possible (PauseAccess/Timeout tests)
- [x] Timeout cancel cannot fire before fulfillment is possible; no cancel/fulfill double-spend race (both paths terminal-guarded, race tested both directions)
- [x] Wager min/max bounds enforced; zero-wager rejected
- [x] Events on every state transition, funding change, config change

## Randomness
- [x] Future round ≥ current + 2 with publish-time tripwire require (enforced in constructor + request)
- [x] Exact round pinned; chain-scoped normalized hash used
- [x] Freshness check on fulfill
- [ ] Mock provider never configured on a public deployment (operational — verify at deploy time)
- [x] Seed never reused across decision points

## Testing
- [x] Unit: hand values (multi-ace), naturals, bust, push, dealer draw, soft-17, double accounting, payout table
- [x] Fuzz: wagers, seeds, action sequences (FuzzGameFlow.t.sol)
- [x] Invariants: solvency, reservation ≤ houseFunds, single settlement, withdraw cap, payout cap (TableInvariants.t.sol)
- [x] Adversarial: reentrancy (provider/consumer), duplicate callbacks, stale requests, unauthorized roles, paused behavior, transfer-failure paths, timeout races
- [~] Reentrancy via token hooks: TestChip has none by construction; BlockableToken covers transfer-failure atomicity. A hook-token reentrancy test would only apply to unsupported tokens.

## Ops
- [ ] Deployer key is a throwaway testnet key; no secrets in repo (.env.example only)
- [ ] Roles transferred/renounced per DEPLOYMENT.md after deploy
- [ ] Keeper running before opening the table (free-look window)
- [ ] Explorer verification completed where supported
- [ ] Frontend wallet write-path exercised on the live deployment (read-path verified headless against anvil; writes exercised via SDK/bot only so far)

## Explicit non-claims
This project is **not audited** and **not production-ready**; completing
this checklist does not make it suitable for real money.
