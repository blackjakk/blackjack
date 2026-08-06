# Local Development

## Prerequisites

* [Foundry](https://getfoundry.sh) (forge/cast/anvil) — tested with 1.5.x
* Node.js ≥ 22, pnpm ≥ 10

## Install

```bash
pnpm install           # workspace deps (OZ, forge-std come via npm)
```

Solidity dependencies are installed through npm (`@openzeppelin/contracts`,
`forge-std`) and wired up via `packages/contracts/remappings.txt` — no git
submodules.

## Contracts

```bash
cd packages/contracts
forge fmt              # format
forge build            # compile
forge test -vv         # unit + fuzz + invariant tests
forge coverage         # coverage report
```

Local end-to-end flow with the mock provider on anvil:

```bash
anvil &                                        # local chain
forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --sig "runLocal()" \
  --private-key <anvil default key>
```

`runLocal()` deploys TestChip, MockRandomnessProvider and BlackjackTable,
funds the house, and prints addresses. The mock provider requires an
explicit `fulfill(requestId, seed)` call (any dev account) to simulate the
beacon — the SDK's local helper does this automatically.

## SDK / web

```bash
pnpm --filter @blackjack/sdk build
pnpm --filter @blackjack/sdk test
pnpm --filter web dev            # Next.js dev server
```

Copy `.env.example` to `.env.local` in `apps/web` and fill in the deployed
addresses. **Never commit private keys.**
