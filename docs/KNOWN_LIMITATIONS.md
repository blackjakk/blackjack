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
15. **Shared-pool membership: timelocked, bonded, float-capped, objectively
    slashable — MITIGATED, residuals documented.** While a pool has LPs,
    adding a game takes a PUBLIC two-step: proposeTable posts a MEGA bond and
    commits to a per-game float cap, then a timelock runs — 48 h for novel
    code, 12 h for tables whose bytecode a trusted factory attests it
    deployed (provable byte-identity with the reviewed engine); activation is
    permissionless after it. Delays are enforced far above the 1 h exit
    queue, so every LP exits at a fair price first if they disagree; pending
    proposals are shown in the pool panel. Exposure is BOUNDED: fundTable
    never pushes more than the float cap, and totalAssets counts a member's
    reported houseFunds only up to 2x its cap, so a lying game cannot inflate
    the pool's books beyond a known bound. claimDefault lets ANYONE make the
    pool test a member's reported liquidity in a single transaction — honest
    game code cannot fail it; a member that cannot deliver is ejected and its
    bond forfeits to governance for LP compensation. Instant bond-free adds
    exist ONLY while a pool has zero shares (nobody to protect; depositors
    see the member list up front). Unapproved games run on their own
    per-table BankrollVault. Residuals: bond sizes vs float caps are a
    governance judgment (no MEGA price oracle onchain), and a malicious
    tier-2 proposal still activates if every LP ignores the public window.

15a. **Admin keys live behind a 12 h public timelock.** DEFAULT_ADMIN_ROLE of
    every table and pool is an OZ TimelockController (12 h min delay, open
    execution): rule changes, provider swaps, pauses, factory-trust changes
    and membership proposals are all visible half a day before they can
    execute. Costs: the emergency pause is slow too (acceptable here — pause
    only blocks NEW bets, and settlement/cancel work while paused, so no
    funds can be trapped); the deployer key remains the timelock's sole
    PROPOSER and keeps the pools' operational REBALANCER role (fund/defund
    between pool and members — totalAssets-neutral) until a governance token
    takes both over. TestChip's mint also stays with the deployer (valueless
    faucet token).
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
