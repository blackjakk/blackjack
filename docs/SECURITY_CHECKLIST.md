# Security Checklist (pre-testnet-deploy)

Status legend: [ ] open, [x] done, [~] partially / documented residual.

## Contracts
- [ ] All state-mutating externals `nonReentrant`; CEI ordering verified
- [ ] No `tx.origin`
- [ ] No delegatecall / arbitrary external calls (only chip, bound provider, stateless verifier)
- [ ] SafeERC20 for every token transfer; return values checked
- [ ] All state transitions guarded (`InvalidState` on everything else)
- [ ] One pending randomness request per game; exact requestId + provider match
- [ ] Request cleared before card effects; adapter marks fulfilled before callback
- [ ] Settlement reachable exactly once per game
- [ ] Reserved liabilities ≥ worst-case payout path for every live game
- [ ] `withdrawHouseFunds` capped at available liquidity (escrow + reserved untouchable)
- [ ] No admin path that moves player escrow anywhere but back to the player
- [ ] Pause blocks new risk only; wind-down and refunds always possible
- [ ] Timeout cancel cannot fire before fulfillment is possible; no cancel/fulfill double-spend race (both paths terminal-guarded)
- [ ] Wager min/max bounds enforced; zero-wager rejected
- [ ] Events on every state transition, funding change, config change

## Randomness
- [ ] Future round ≥ current + 2 with publish-time tripwire require
- [ ] Exact round pinned; chain-scoped normalized hash used
- [ ] Freshness check on fulfill
- [ ] Mock provider never configured on a public deployment
- [ ] Seed never reused across decision points

## Testing
- [ ] Unit: hand values (multi-ace), naturals, bust, push, dealer draw, soft-17, double accounting, payout table
- [ ] Fuzz: wagers, seeds, action sequences
- [ ] Invariants: solvency, reservation ≤ houseFunds, single settlement, withdraw cap, payout cap
- [ ] Adversarial: reentrancy (token/provider/consumer), duplicate callbacks, stale requests, unauthorized roles, paused behavior, transfer-failure paths, timeout races

## Ops
- [ ] Deployer key is a throwaway testnet key; no secrets in repo (.env.example only)
- [ ] Roles transferred/renounced per DEPLOYMENT.md after deploy
- [ ] Keeper running before opening the table (free-look window)
- [ ] Explorer verification completed where supported

## Explicit non-claims
This project is **not audited** and **not production-ready**; completing
this checklist does not make it suitable for real money.
