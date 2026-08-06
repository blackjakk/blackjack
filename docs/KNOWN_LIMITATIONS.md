# Known Limitations (v1)

1. **Infinite shoe.** Cards are sampled independently from committed
   randomness (with replacement). A real six-deck shoe has card-removal
   effects; EV differs slightly. The draw primitive is isolated in
   `BlackjackLib` so a finite shoe can be added later.
2. **Free-look liveness assumption.** If *no one* submits a published drand
   beacon for an entire timeout window, the player may cancel for a full
   refund after having been able to compute the pending cards offchain.
   Player-favorable only; requires total keeper failure; documented in
   RANDOMNESS.md / THREAT_MODEL.md (T2).
3. **House keeper required for good UX.** Without a keeper, someone must
   manually submit beacons (the frontend can do it, but an abandoned tab
   stalls the hand until another submitter or the timeout).
4. **No slashing / bonding on cancel.** Timeout cancel refunds in full.
5. **Play money only. Not audited.** No real-money use under any
   circumstances.
6. **Testnet rollbacks.** MegaETH testnet state may be rolled back during
   upgrades (per official docs); history and balances are not durable.
7. **Single hand, no split/insurance/surrender.** Rule set is intentionally
   reduced; see RULES.md.
8. **Double-down liquidity is over-reserved.** 2× wager is reserved for
   every game up front so a double can never fail; this halves nominal
   bankroll capacity versus exact reservation.
9. **No persistent indexer.** The frontend/SDK reconstruct state from RPC
   logs each load; deep history depends on RPC log retention.
10. **Gas/fee UX.** Players need testnet ETH from the official MegaETH
    faucet for gas; the chip faucet does not provide gas.
