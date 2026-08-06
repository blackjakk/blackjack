# Blackjack web UI

Next.js + wagmi frontend for the MegaETH testnet blackjack table.
**Zero-config**: it defaults to the live testnet deployment recorded in
`@blackjack/config`, so you can test immediately.

## Test it in 5 minutes

```bash
pnpm install         # repo root, once
pnpm --filter web dev
# open http://localhost:3000
```

1. **Connect wallet** (MetaMask/Rabby). If you're on another network the app
   shows a *Switch / add MegaETH Testnet* button — one click adds chain 6343
   with the right RPC.
2. **Gas:** you need a little testnet ETH (free, no value) from the official
   faucet at [testnet.megaeth.com](https://testnet.megaeth.com) — the app links
   you there if your balance is empty.
3. **Chips:** click *Claim faucet chips* (1000 CHIP per hour, free).
4. **Play:** enter a wager, *Place bet* (first bet asks for an ERC-20 approval
   too), and when the app says the drand round has published, click the pulsing
   **Submit beacon** — that's you delivering the public randomness on-chain;
   anyone may do it, and a house keeper can do it for you if one is running.
5. Hit / Stand / Double, submit the dealer's beacon, and the result banner +
   explorer link appear. Recent results are reconstructed from onchain events.

Every step is a real transaction on MegaETH testnet; the page holds no game
logic — it only reads chain state and sends your signed actions.

## Pointing at another deployment

Set env vars in `.env.local` (see `/.env.example`): `NEXT_PUBLIC_TABLE_ADDRESS`,
`NEXT_PUBLIC_CHIP_ADDRESS`, `NEXT_PUBLIC_PROVIDER_ADDRESS`,
`NEXT_PUBLIC_RPC_URL`, `NEXT_PUBLIC_CHAIN_ID`, and
`NEXT_PUBLIC_PROVIDER_KIND=mock` for a local anvil run (adds a dev-seed reveal
button instead of the drand beacon flow).

> ⚠️ Testnet play money only. CHIP has no monetary value; contracts are
> unaudited; MegaETH testnet state may be rolled back at any time.
