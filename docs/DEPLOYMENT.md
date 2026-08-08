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

1. Ensure beacon fulfillment liveness — a documented assumption. Either run
   the continuous keeper (`pnpm --filter @blackjack/sdk keeper`) or rely on
   the scheduled sweep (`.github/workflows/keeper.yml`: every 15 min, well
   inside the 1 h cancel timeout). The sweep needs a `KEEPER_PRIVATE_KEY`
   repository secret — a throwaway, testnet-only key holding a little gas
   ETH; fulfillment is permissionless so the key needs no roles. One-shot
   run: `KEEPER_PRIVATE_KEY=0x… pnpm --filter @blackjack/sdk keeper:sweep`.
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
| TableChat (onchain chat, block 26320341) | `0x9768a366EAA389fAc374D0736fee4Cd07D02e180` | Sourcify exact_match |

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

## Phase A deployment record — 2026-08-07 (chain 6343)

| Contract | Address | Verification |
| --- | --- | --- |
| TableFactory | `0xD45f27a746E2073aE97e599378845B1F8370c8a5` | Sourcify exact_match |
| BlackjackTableV2 "Classic" (S17, 3:2, double any two; 500k CHIP bankroll) | `0x457e5eb30973af0654aE3f6b5E1ba62d5c97C1cF` | Sourcify exact_match |
| BlackjackTableV2 "Vegas" (H17, 6:5, double 10-11, surrender; 300k) | `0xe4eDc43D1cD0cC5370fAB275EcB1c50C1CC0b6Ee` | Sourcify exact_match |
| BlackjackTableV2 "Pro" (S17, 3:2, double 9-11, surrender, 10 CHIP min; 200k) | `0xb414D2B3AAe5Da85813Ea3680895a457e0a08577` | Sourcify exact_match |

Deployed via `script/DeployV2.s.sol` reusing the live TestChip and
DrandRandomnessProvider (fulfillment is permissionless, so the existing
keeper sweep covers v2 tables automatically). Funding done via `cast`
(mint → approve → permissionless `fundHouse`). Admin/treasury on all
three tables = deployer `0x97eB…a476`. v1 table remains live.

## LP-vault deployment record — 2026-08-08 (chain 6343)

ERC-4626 `BankrollVault` per table (vault = the table's ONLY treasury; deployer
treasury role revoked; deployer holds first-LP shares for migrated bankrolls).
All Sourcify exact_match.

| Vault | Address | Backing table |
| --- | --- | --- |
| bjClassic (CHIP) | `0xF4f1726687BcE9C5285Bc9Ab6bacb0Dca9F2E65F` | Classic |
| bjVegas (CHIP) | `0xC1D56cD890a84B2Bd433421C177b7C1f524A5de4` | Vegas |
| bjPro (CHIP) | `0xa8332EdB9999A300Acb1e35E8F4A313375aB97a8` | Pro |
| bjUSDm | `0xee8f3d40060290e959f285a8BA866c4FAF28eA67` | USDm table `0x7007…4003` (empty — awaits LPs) |
| bjETH | `0x7686DEf9ac25dfE608e27A13c1678Cf9df19E21a` | WETH table `0x7565…d116` (0.25 WETH seed) |
| bjMEGA | `0xb0FC29344A1AdeE8FbcE46a0B913F3CEa3698C29` | MEGA table `0x480F…D272` (empty — awaits LPs) |

Real-asset tokens verified onchain + docs 2026-08-08: USDm
`0x15e9…1e5C`, canonical WETH `0x4200…0006`, MEGA `0xc903…e6c2`. Per-asset
factories: USDm `0x028b…A914`, ETH `0x8aCf…c4a5`, MEGA `0xf865…34a3`.
LP free-look window (exit-timing around a computable pending beacon) is
documented in KNOWN_LIMITATIONS.
