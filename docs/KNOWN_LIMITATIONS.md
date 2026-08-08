# Known Limitations (v1)

1. **Infinite shoe.** Cards are sampled independently from committed
   randomness (with replacement). A real six-deck shoe has card-removal
   effects; EV differs slightly. The draw primitive is isolated in
   `BlackjackLib` so a finite shoe can be added later.
2. **Free-look liveness assumption.** If *no one* submits a published drand
   beacon for an entire timeout window, the player may cancel for a full
   refund after having been able to compute the pending cards offchain.
   Player-favorable only; requires total keeper failure; documented in
   RANDOMNESS.md / THREAT_MODEL.md (T2). Mitigated in this repo by (a) the
   frontend's auto-reveal (any open tab submits beacons) and (b) the
   scheduled keeper sweep (`.github/workflows/keeper.yml`, every 15 min vs
   the 1 h timeout) when the `KEEPER_PRIVATE_KEY` secret is configured.
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
11. **Chat is unmoderated and permanent.** TableChat has no owner and no
    moderator by design: nothing can be censored, which also means spam and
    abuse can only be hidden client-side (per-device mute). Every message is
    public forever in chain logs — deletes/edits are tombstones/overlays, the
    original stays readable to anyone. Onchain rate limits: 2s per-address
    cooldown + size caps only.
12. **Chat burner key lives in localStorage.** Clearing site data discards
    the chat identity and any dust ETH on it. It must only ever hold testnet
    gas dust.
13. **Chat history loading grows with chain age.** The UI replays TableChat
    logs from the deploy block on each load (chunked getLogs); after months
    of activity an indexer would be needed.
14. **MOSS is a hosted embedded wallet.** The MOSS connect option
    (`@megaeth-labs/wallet-wagmi-connector`) embeds MegaETH's hosted wallet
    (`account.megaeth.com`) in an iframe; keys are managed by that hosted
    service and secured by passkeys, not by this app. Availability and
    security of MOSS are MegaETH's, not ours — acceptable here because chips
    are valueless play money. Extension wallets (EIP-6963/injected) remain
    fully supported alternatives.
14a. **LP exit free-look — MITIGATED.** BankrollVault exits are a delayed
    queue (requestRedeem escrows shares; claim() strikes the price >= 1 h
    later, beyond the randomness timeout), so foreknowledge of a pending
    beacon cannot be monetized by exiting. Residual: claims can be
    temporarily blocked while liabilities are reserved; retry after
    settlement.
15. **Shared-vault membership is an admin power (documented trust point).**
    A SharedBankrollVault's DEFAULT_ADMIN_ROLE decides which game tables the
    pool backs. A malicious or buggy member table would poison the WHOLE
    asset pool (totalAssets sums member houseFunds), so membership must only
    ever be verified game code; today that judgment rests with the deployer
    key, and this role is the natural first thing a future governance token
    takes over. `addTable` checks the vault actually holds the table's
    treasury role and that assets match; it cannot verify code intent.
16. **Infinite rounds need a driver.** lockDeal/lockActions/settle/refund are
    permissionless; player frontends auto-drive their own rounds and the
    keeper cron is the backstop (same liveness class as beacon fulfillment,
    limitation 2/3). Worst case a stuck round is cancellable for full refunds
    after the randomness timeout.
17. **Hit-to-target only on shared rounds.** Per-card hit decisions on a
    shared draw beacon would let players see their next card before deciding;
    the committed hit-to-target strategy is the sound (and standard-strategy-
    expressible) alternative. Play style is slightly less granular than the
    per-hand tables.
