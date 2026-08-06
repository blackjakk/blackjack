# MegaETH Testnet Deployment

Network facts verified against [docs.megaeth.com](https://docs.megaeth.com)
(2026-08). Re-verify before every deploy — RPC endpoints are rate-limited
and may change, and testnet state can be rolled back during upgrades.

| Parameter | Value |
| --- | --- |
| Chain ID | `6343` (`0x18c7`) |
| RPC | `https://carrot.megaeth.com/rpc` |
| Explorer | `https://testnet-mega.etherscan.io` |
| Gas token | testnet ETH (official faucet: docs.megaeth.com → user-guide/faucet) |
| `DrandOracleQuicknet` | `0x4e1673dcAA38136b5032F27ef93423162aF977Cc` |

## Prerequisites

1. A **throwaway** deployer key funded with testnet ETH from the official
   MegaETH faucet. Never reuse a key that holds real assets.
2. `.env` (from `.env.example`) with `MEGAETH_TESTNET_RPC` and
   `DEPLOYER_PRIVATE_KEY`. `.env` is gitignored — never commit it.

## Deploy

```bash
cd packages/contracts
source .env
forge script script/Deploy.s.sol \
  --rpc-url "$MEGAETH_TESTNET_RPC" \
  --broadcast \
  --sig "runTestnet()" \
  --private-key "$DEPLOYER_PRIVATE_KEY"
```

`runTestnet()`:
1. deploys `TestChip`;
2. deploys `DrandRandomnessProvider` pointed at the preinstalled
   `DrandOracleQuicknet`;
3. deploys `BlackjackTable` (chip, provider, min/max wager, timeout);
4. authorizes the table on the provider;
5. mints an initial house bankroll to the deployer and calls `fundHouse`.

Record the printed addresses into `packages/config/src/addresses.ts` and
`apps/web/.env.local`.

## Verify contracts

MegaETH testnet is served by Etherscan (`testnet-mega.etherscan.io`).
Verification (requires an Etherscan-family API key; check the explorer's
current instructions):

```bash
forge verify-contract <address> src/BlackjackTable.sol:BlackjackTable \
  --chain-id 6343 \
  --verifier etherscan \
  --verifier-url https://api.etherscan.io/v2/api \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args $(cast abi-encode "constructor(address,address,uint256,uint256,uint256)" ...)
```

If verification is unsupported or the endpoint has changed, publish the
flattened source alongside the deployment record instead — do not claim
verification that did not happen.

## Post-deploy

1. Start the keeper (`pnpm --filter @blackjack/sdk keeper`) **before**
   announcing the table — fulfillment liveness is a documented assumption.
2. Sanity-play one full game (bet → deal → stand → settle) and check events
   on the explorer.
3. Review role assignments: transfer `DEFAULT_ADMIN_ROLE` / `TREASURY_ROLE`
   to the operating accounts; the deployer renounces what it doesn't need.
4. Run through docs/SECURITY_CHECKLIST.md.

## MegaETH-specific gas gotchas (learned from the live deploy)

* MegaETH charges **storage gas** on top of compute gas; Foundry's local EVM
  only models compute gas, so `forge script` under-estimates and fails with
  `intrinsic gas too low`. Fix (per official docs): pass `--skip-simulation`
  so gas is estimated by the remote RPC.
* Mini-blocks confirm in ~10 ms — faster than `forge script` tracks nonces, so
  batched broadcast can abort with "EOA nonce changed unexpectedly" after the
  CREATEs land, and the remaining calls may be mined-but-reverted. If
  `liquidity()` reads 0 after deploy, finish funding manually (`cast send`
  estimates via the remote RPC by default):
  `cast send $CHIP 'mint(address,uint256)' …`, `approve`, then
  `cast send $TABLE 'fundHouse(uint256)' …`.

## Deployment record — 2026-08-06 (chain 6343)

| Contract | Address | Verification |
| --- | --- | --- |
| TestChip | `0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711` | Sourcify exact_match |
| DrandRandomnessProvider (`minFutureRounds=2`) | `0x801466769247D89B3d768C4Ad5B74D83466cD14b` | Sourcify exact_match |
| BlackjackTable (min 1 / max 1000 CHIP) | `0x261ab01D3c6F06BccBb49380bD27cd9303A4dB2f` | Sourcify exact_match |

Deploy block 26317836; admin/treasury = deployer `0x97eB…a476` (throwaway
testnet key). House funded with 1,000,000 CHIP. Etherscan-side verification was
not performed (requires an Etherscan API key); Sourcify verification succeeded
for all three contracts. Post-deploy sanity: two full hands played live through
real drand quicknet beacons (faucet → bet → hit/stand → beacon fulfill →
settlement), including a dealer-natural ENHC settlement.

## Realtime API note

MegaETH mini-blocks land in ~10 ms. Standard `eth_sendRawTransaction` +
receipt polling works fine; the frontend/SDK use viem defaults. (MegaETH
also exposes a realtime API for sub-block receipts — an optional
optimization, not required for correctness.)
