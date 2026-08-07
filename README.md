# MegaETH Blackjack (Testnet MVP)

Single-player, fully onchain **European no-hole-card blackjack** against a
contract-controlled dealer, played with a valueless test ERC-20 chip on the
**MegaETH testnet** (chain ID **6343**).

> ⚠️ **Play money only.** This codebase is an MVP for validating game logic,
> transaction flow, randomness integration, bankroll accounting and MegaETH
> compatibility. It is **not audited**, **not production-ready**, and **must
> not** be used with real funds. Test chips have **no monetary value**.

## Monorepo layout

```
apps/web                 Next.js frontend (wagmi + viem)
packages/contracts       Foundry: Solidity contracts, tests, deploy scripts
packages/sdk             TypeScript SDK + deterministic basic-strategy bot
packages/config          Shared chain config, addresses, ABIs
docs                     Architecture, threat model, randomness, rules, ops
```

## Documentation

| Doc | Contents |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System overview, components, accounting model |
| [docs/STATE_MACHINE.md](docs/STATE_MACHINE.md) | Game state machine (normative) |
| [docs/RULES.md](docs/RULES.md) | Exact blackjack rule set implemented |
| [docs/RANDOMNESS.md](docs/RANDOMNESS.md) | Randomness design, drand adapter, trust assumptions |
| [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) | Actors, threats, mitigations, residual risks |
| [docs/LOCAL_DEVELOPMENT.md](docs/LOCAL_DEVELOPMENT.md) | Build & test locally |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | MegaETH testnet deployment |
| [docs/SECURITY_CHECKLIST.md](docs/SECURITY_CHECKLIST.md) | Pre-deploy checklist |
| [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md) | Explicit MVP limitations |

## Quick start

```bash
# contracts
cd packages/contracts
forge build && forge test

# workspace (sdk / web)
pnpm install
pnpm build
```

See [docs/LOCAL_DEVELOPMENT.md](docs/LOCAL_DEVELOPMENT.md) for details.

## Live testnet deployment (2026-08-06)

| Contract | Address |
| --- | --- |
| `TestChip` | [`0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711`](https://testnet-mega.etherscan.io/address/0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711) |
| `DrandRandomnessProvider` | [`0x801466769247D89B3d768C4Ad5B74D83466cD14b`](https://testnet-mega.etherscan.io/address/0x801466769247D89B3d768C4Ad5B74D83466cD14b) |
| `BlackjackTable` | [`0x261ab01D3c6F06BccBb49380bD27cd9303A4dB2f`](https://testnet-mega.etherscan.io/address/0x261ab01D3c6F06BccBb49380bD27cd9303A4dB2f) |
| `TableChat` | [`0x9768a366EAA389fAc374D0736fee4Cd07D02e180`](https://testnet-mega.etherscan.io/address/0x9768a366EAA389fAc374D0736fee4Cd07D02e180) |

All three are source-verified on [Sourcify](https://sourcify.dev) (exact match,
chain 6343); deploy block 26317836. House bankroll: 1,000,000 CHIP. Sanity-played
live via the SDK bot through real drand beacons. Testnet state may be rolled
back by network upgrades — redeploy with `docs/DEPLOYMENT.md` if so.

## Tables (Phase A)

The web app opens on a **table lobby**: three curated variant tables (Classic
S17 3:2 · Vegas H17 6:5 with surrender · Pro with double-9-11 and surrender)
plus any community tables created through the permissionless onchain
`TableFactory`. v2 tables support **multiple concurrent hands** per player
(up to 5), per-table rules enforced onchain, and **permissionless bankroll
deposits** (`fundHouse`) — LP shares are on the roadmap. The original v1
single-hand table remains available.

## Wallets

The web app offers two ways to connect:

* **MOSS** — MegaETH's official embedded wallet
  ([docs](https://docs.megaeth.com/moss-docs)): passkey sign-in in a hosted
  iframe, nothing to install, works on mobile. Integrated via the official
  `@megaeth-labs/wallet-wagmi-connector`.
* **Extension wallets** — MetaMask or any injected/EIP-6963 wallet.

Connection errors are surfaced in the picker; if no extension is detected the
UI says so instead of failing silently.

With MOSS connected, **1-click play** uses MOSS Smart Approvals: one passkey
approval grants a session scoped to exactly this deployment's contracts and
functions (chip faucet/approve, table placeBet/hit/stand/double/cancel,
provider fulfill), capped at 5,000 CHIP/day + 0.01 gas ETH/day, 24 h expiry,
revocable in-app or from the wallet. Game moves then execute without popups;
an expired grant falls back to normal approval dialogs.

## Network (verified against docs.megaeth.com)

| | Testnet |
| --- | --- |
| Chain ID | `6343` (`0x18c7`) |
| RPC | `https://carrot.megaeth.com/rpc` |
| Explorer | `https://testnet-mega.etherscan.io` |
| VRF | `DrandOracleQuicknet` @ `0x4e1673dcAA38136b5032F27ef93423162aF977Cc` |

RPC endpoints are rate-limited and may change; always re-check the
[official docs](https://docs.megaeth.com/user-guide/connect) before deploying.
