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

## Network (verified against docs.megaeth.com)

| | Testnet |
| --- | --- |
| Chain ID | `6343` (`0x18c7`) |
| RPC | `https://carrot.megaeth.com/rpc` |
| Explorer | `https://testnet-mega.etherscan.io` |
| VRF | `DrandOracleQuicknet` @ `0x4e1673dcAA38136b5032F27ef93423162aF977Cc` |

RPC endpoints are rate-limited and may change; always re-check the
[official docs](https://docs.megaeth.com/user-guide/connect) before deploying.
