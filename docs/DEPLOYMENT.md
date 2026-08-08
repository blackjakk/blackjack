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

### Delayed-exit migration — 2026-08-08 (supersedes the instant-exit vaults)

v1 instant-exit vaults unwound and replaced; treasury roles moved to the
delayed vaults (1 h exit queue, price struck at claim). All Sourcify
exact_match: bjClassic `0x87B2…D3c7`, bjVegas `0x7cb6…12A5`, bjPro
`0xb0a6…faD2`, bjUSDm `0x196A…e20D`, bjETH `0xB3A0…ef2c`, bjMEGA
`0xf853…7F26`.

### Split rollout — 2026-08-08 (chain 6343)

V3 engine (split pairs): TableFactoryV3 `0xEF80C2BDAF12059c0e750C6F19E88ed76c951a72`,
"Split" CHIP table `0x1d8DD0B8D825c939024582f31Dc512955187Dc2E` (S17, 3:2, split,
surrender; 200k CHIP via delayed vault `0xa103a0B75b591d77f32b479bdaD2869dc7F222B2`).
All Sourcify exact_match. 174 tests incl. 11 split scenarios + V3 invariants.

### Phase D rollout — 2026-08-08 (chain 6343): Infinite tables + shared per-asset pools

One shared multiplayer `InfiniteBlackjack` table per asset (S17, 3:2, double any
two, surrender; 45 s betting window, 40 s decision window, auto-stand) and one
`SharedBankrollVault` per asset (1 h exit queue) backing every member game of
that asset. All Sourcify exact_match.

| Asset | Infinite table | Shared pool (hp*) | Member tables |
| --- | --- | --- | --- |
| CHIP | `0x9103B9723e5BffbBcD70Bfb0785AADF64E2D0E35` | `0xDD796fb9BfDCAb8210884Ccc8634B8f8a2324Bc0` | Infinite (200k CHIP seed) |
| USDm | `0x70D3f02A850c197Bc339ba9F8530aBcCb4217Aac` | `0x8F88B2FfDEF4F79f9a7C7Ac3429b4A0439965c2E` | Infinite + USDm classic (re-pointed) |
| ETH | `0xb25Fd4A3dEFF1926e6B17B1fF8Eb2beBDd807286` | `0x6558427457B8bf3C36Ab1E1be88F2a5223cd55D4` | Infinite + ETH classic (0.25 WETH, 0.125 per table) |
| MEGA | `0x6EF4dEf337D24631efEe0e0ffb145Ef835430644` | `0x03C399f63755e04f4E3D56a92972d3f37e93a51C` | Infinite + MEGA classic (re-pointed) |

Migration notes, all verified onchain before acting: legacy bjUSDm/bjMEGA vaults
held ZERO LP shares, so their classic tables were re-pointed directly (legacy
treasury roles revoked). bjETH's sole LP was the deployer (0.25 WETH): its
delayed exit was requested in the deploy tx and `FinishEthMigration` completed
the move once the 1 h queue matured (claimed 0.25 WETH, re-pointed the ETH
classic table to hpETH, legacy treasury revoked, WETH re-deposited and split
across both ETH tables; legacy bjETH now has zero supply and zero role). Legacy
CHIP per-table vaults (Classic/Vegas/Pro/Split) keep their tables and stay
fully functional — their LPs migrate self-serve (requestRedeem there, deposit
into hpCHIP) whenever they choose.

### Governed pools — 2026-08-08 (supersedes the same-day v1 hp\* pools)

Pool membership became a GOVERNANCE ACTION: while a pool has LPs, adding a
game takes `proposeTable` -> 48 h public timelock -> permissionless
`activateTable` (delay enforced >= 2x the 1 h exit queue, so dissenting LPs
always exit at a fair price first). Instant adds only while a pool has zero
shares. Unapproved games run on their own per-table `BankrollVault`. The v1
pools (deployer-instant `addTable`) were unwound while the deployer was still
their sole LP — verified onchain — and replaced. All Sourcify exact_match:

| Governed pool | Address | Members |
| --- | --- | --- |
| hpCHIP | `0x9360f0d73cE4f982b56434e85459550Aa0791fDA` | CHIP Infinite (200k CHIP) |
| hpUSDm | `0xFb26980EBE8BcEdcaa40aD5B561Da33f8894cdAD` | USDm Infinite + classic |
| hpETH | `0xbae7289F86E4893a69c6bD73E46EC2547C6FA829` | ETH Infinite + classic (0.25 WETH) |
| hpMEGA | `0x5d151dDb5ef6Fb2F9F2a290411F44eD77014c550` | MEGA Infinite + classic |

CHIP/ETH funds moved through the v1 pools' own 1 h exit queues
(`GovernedPools.runTestnet` started the exits, `finishFunded` claimed,
re-pointed treasuries and re-deposited). Retired v1 pools: 0xDD79…4Bc0,
0x8F88…5c2E, 0x6558…55D4, 0x03C3…a51C (zero supply, zero roles).

### Decentralization phase — 2026-08-08 (chain 6343): timelock + provenance + bonds

Executed while the deployer was the sole LP of every pool (verified onchain);
the intermediate v2 governed pools (0x9360…, 0xFb26…, 0xbae7…, 0x5d15…) were
skipped over before ever holding third-party funds and are retired alongside
the v1 pools. All Sourcify-verified.

| Contract | Address |
| --- | --- |
| TimelockController (12 h, deployer = sole proposer, open execution) | `0xeD7d0351Fdc1aa7c5aE6395e393fcA43BE25d3f3` |
| hpCHIP v3 (200,025 CHIP; member: CHIP Infinite, float cap 500k) | `0xbf0064b3a503e62d447002210aF1e60150301f25` |
| hpUSDm v3 (members: USDm Infinite + classic, caps 50k) | `0x7B10E47a92a0D571898eC54e9f677f2bC82495fd` |
| hpETH v3 (0.25 WETH; members: ETH Infinite + classic, caps 1) | `0x70eE7F053cB6a203326Ff4a014e6586B3B3E4dcF` |
| hpMEGA v3 (members: MEGA Infinite + classic, caps 50k) | `0x85258F50d27d1F171a6564081fd62ec9eeB19D8e` |
| TableFactory CHIP (provenance-recording) | `0xA29cafeD124864D38dabFe8Fe803cdE61b111Fd0` |
| TableFactoryV3 CHIP | `0x8Ee93Fcc41e712589ea1Bf878a02eD2b6f16d23C` |
| TableFactory USDm / ETH / MEGA | `0x83fa…e60B` / `0xCB76…00De` / `0x57C8…D368` |

Membership model (see KNOWN_LIMITATIONS 15/15a): proposals post a 1,000-MEGA
tier-2 bond (tier-1/factory-provenanced: 0, quarter delay), commit to a float
cap that bounds both funding and the member's counted share of totalAssets
(2x cap), and are objectively slashable via permissionless `claimDefault`.
DEFAULT_ADMIN_ROLE of ALL 12 tables and 4 pools = the TimelockController;
deployer retains: timelock proposer, pool REBALANCER, TestChip mint (play
token), keeper key. Next decentralization rung: governance token takes the
proposer + rebalancer roles.
