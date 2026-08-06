# @blackjack/sdk — agent interface

TypeScript SDK for driving the MegaETH blackjack table programmatically.
**Test chips only — no monetary value.** All state comes from the chain; the
SDK never trusts a backend.

## Capabilities

| Need | API |
| --- | --- |
| Read table configuration | `client.getTableConfig()` — min/max wager, timeout, provider, paused |
| Read available liquidity | `client.getLiquidity()` — bankroll, reserved, available |
| Start a game | `client.startGame(wager)` → `{gameId, receipt}` (waits for confirmation) |
| Read current cards & state | `client.getGame(gameId)` → decoded cards, hand values, state, outcome |
| Hit / Stand / Double | `client.hit()` / `client.stand()` / `client.double()` (wait for confirmation) |
| Wait for tx confirmation | built into every write (returns the receipt) |
| Wait for randomness fulfillment | `client.waitForRandomness(gameId)` / `client.waitUntil(gameId, predicate)` |
| Retrieve final result | `client.waitForResult(gameId)` → outcome, payout, final hands |
| Claim test chips | `client.claimFaucet()`, `client.approveChips(amount)` |
| Submit drand beacons (keeper) | `fulfillDrandRequest(...)`, `runDrandKeeper(...)`, `fetchBeaconSignature(round)` |
| Local-dev randomness | `fulfillMockRequest(...)` (mock provider, anvil only) |
| Basic strategy | `decideAction(playerCards, dealerUpCard)` → `"hit" \| "stand" \| "double"` (deterministic) |
| Play a full game | `playOneGame(client, wager, hooks)` |

## Quick start

```ts
import {createPublicClient, createWalletClient, http, parseEther} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {megaethTestnet} from "@blackjack/config";
import {BlackjackClient, playOneGame, fulfillDrandRequest} from "@blackjack/sdk";

const publicClient = createPublicClient({chain: megaethTestnet, transport: http()});
const walletClient = createWalletClient({
    account: privateKeyToAccount(process.env.PRIVATE_KEY as `0x${string}`),
    chain: megaethTestnet,
    transport: http(),
});

const client = new BlackjackClient({publicClient, walletClient, table: TABLE, chip: CHIP});

await client.claimFaucet();
await client.approveChips(parseEther("100"));

const result = await playOneGame(client, parseEther("10"), {
    // the bot doubles as its own keeper: fetches the public beacon and submits it
    ensureRandomness: (g) =>
        fulfillDrandRequest({publicClient, walletClient, provider: PROVIDER, requestId: g.pendingRequestId})
            .then(() => {}),
});
console.log(result);
```

## Sample bot & keeper

```bash
# deterministic basic-strategy bot (local anvil, mock randomness)
RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=0x... TABLE=0x... CHIP=0x... \
  PROVIDER=0x... PROVIDER_KIND=mock GAMES=10 pnpm bot

# standalone drand keeper for the testnet deployment
RPC_URL=https://carrot.megaeth.com/rpc KEEPER_PRIVATE_KEY=0x... PROVIDER=0x... pnpm keeper
```

The bot implements the standard basic-strategy matrix restricted to
hit/stand/double under ENHC rules (see `src/strategy.ts`); it is deterministic:
identical inputs always produce the identical action.
