/**
 * Sample basic-strategy bot runner. TEST CHIPS ONLY — no monetary value.
 *
 * Local (anvil + MockRandomnessProvider):
 *   RPC_URL=http://127.0.0.1:8545 \
 *   PRIVATE_KEY=0x... TABLE=0x... CHIP=0x... PROVIDER=0x... PROVIDER_KIND=mock \
 *   pnpm bot
 *
 * MegaETH testnet (DrandRandomnessProvider): same variables with
 *   RPC_URL=https://carrot.megaeth.com/rpc PROVIDER_KIND=drand
 * The bot then submits drand beacons itself (permissionless keeper role).
 */
import {createPublicClient, createWalletClient, http, parseEther, type Address} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {BlackjackClient, OutcomeNames} from "./client.ts";
import {playOneGame} from "./bot.ts";
import {fulfillDrandRequest, fulfillMockRequest} from "./keeper.ts";

function env(name: string, fallback?: string): string {
    const v = process.env[name] ?? fallback;
    if (v === undefined) throw new Error(`missing env var ${name}`);
    return v;
}

async function main() {
    const rpcUrl = env("RPC_URL", "http://127.0.0.1:8545");
    const account = privateKeyToAccount(env("PRIVATE_KEY") as `0x${string}`);
    const table = env("TABLE") as Address;
    const chip = env("CHIP") as Address;
    const provider = env("PROVIDER") as Address;
    const providerKind = env("PROVIDER_KIND", "mock"); // "mock" | "drand"
    const games = Number(env("GAMES", "5"));
    const wager = parseEther(env("WAGER_CHIPS", "10"));

    const publicClient = createPublicClient({transport: http(rpcUrl)});
    const walletClient = createWalletClient({account, transport: http(rpcUrl)});
    const client = new BlackjackClient({publicClient, walletClient, table, chip});

    console.log(`bot ${account.address} on ${rpcUrl} (${providerKind} randomness)`);
    console.log("NOTE: play-money test chips only — tokens have no monetary value.");

    // Top up and approve.
    const balance = await client.getChipBalance(account.address);
    if (balance < wager * BigInt(games) * 2n) {
        console.log("claiming faucet chips...");
        await client.claimFaucet();
    }
    await client.approveChips(wager * BigInt(games) * 4n);

    // Resume any game left over from a previous run.
    const leftover = await client.getActiveGameId(account.address);
    if (leftover) {
        console.log(`resuming active game ${leftover}...`);
    }

    const ensureRandomness = async (game: {pendingRequestId: bigint}) => {
        if (providerKind === "drand") {
            await fulfillDrandRequest({
                publicClient,
                walletClient,
                provider,
                requestId: game.pendingRequestId,
            });
        } else {
            // Local dev only: the mock provider takes a caller-chosen seed.
            const seed = `0x${Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex")}` as const;
            await fulfillMockRequest({
                publicClient,
                walletClient,
                provider,
                requestId: game.pendingRequestId,
                seed,
            });
        }
    };

    const tally = new Map<string, number>();
    let net = 0n;
    for (let i = 0; i < games; i++) {
        const result = await playOneGame(client, wager, {
            ensureRandomness,
            log: (m) => console.log(`  ${m}`),
        });
        const name = OutcomeNames[result.outcome];
        tally.set(name, (tally.get(name) ?? 0) + 1);
        net += result.payout - result.stake;
    }

    console.log("\n== session summary (test chips) ==");
    for (const [outcome, count] of tally) console.log(`${outcome}: ${count}`);
    console.log(`net chips: ${net}`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
