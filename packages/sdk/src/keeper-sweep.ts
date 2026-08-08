/**
 * One-shot keeper sweep, built for cron use (e.g. a GitHub Actions schedule):
 * scan recent randomness requests on the drand adapter, fulfill any that are
 * pending and publishable, print a summary, exit.
 *
 * Purpose: close the free-look window (docs/THREAT_MODEL.md T2). The cancel
 * timeout is 1 hour, so a sweep every ~15 minutes guarantees no request can
 * sit unfulfilled long enough to be refund-cancelled after an offchain peek —
 * even with no live keeper and no player tabs open.
 *
 * Requests whose game was already settled or cancelled fail simulation and are
 * skipped without spending gas.
 */
import {createPublicClient, createWalletClient, http} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {
    megaethTestnet,
    DEPLOYMENTS,
    drandRandomnessProviderAbi,
    infiniteBlackjackAbi,
} from "@blackjack/config";
import {readDrandRequest, fulfillDrandRequest} from "./keeper.ts";

/** How many recent requests to examine; weeks of traffic at current volume. */
const SCAN_WINDOW = 300n;
const ZERO = "0x0000000000000000000000000000000000000000";

const pk = process.env.KEEPER_PRIVATE_KEY;
if (!pk) {
    console.log("KEEPER_PRIVATE_KEY not set — skipping sweep (nothing to do).");
    process.exit(0);
}

const rpc = process.env.MEGAETH_TESTNET_RPC ?? megaethTestnet.rpcUrls.default.http[0];
const providerAddr = (process.env.PROVIDER_ADDRESS ??
    DEPLOYMENTS[megaethTestnet.id]!.randomnessProvider) as `0x${string}`;
const account = privateKeyToAccount(pk as `0x${string}`);
const pub = createPublicClient({chain: megaethTestnet, transport: http(rpc)});
const wallet = createWalletClient({account, chain: megaethTestnet, transport: http(rpc)});

console.log(`keeper sweep: provider ${providerAddr}, submitter ${account.address}`);

const next = await pub.readContract({
    address: providerAddr,
    abi: drandRandomnessProviderAbi,
    functionName: "nextRequestId",
});
const from = next > SCAN_WINDOW ? next - SCAN_WINDOW : 1n;

let pending = 0;
let fulfilled = 0;
let skipped = 0;
for (let id = from; id < next; id++) {
    const req = await readDrandRequest(pub, providerAddr, id);
    if (req.fulfilled || req.consumer === ZERO) continue;
    pending++;
    try {
        const receipt = await fulfillDrandRequest({
            publicClient: pub,
            walletClient: wallet,
            provider: providerAddr,
            requestId: id,
            chain: megaethTestnet,
        });
        if (receipt) {
            fulfilled++;
            console.log(`fulfilled request ${id} (game ${req.gameId}): ${receipt.transactionHash}`);
        }
    } catch (err) {
        // Typically a settled/cancelled game whose callback binding is gone;
        // simulateContract rejects it before any gas is spent.
        skipped++;
        const msg = err instanceof Error ? err.message.split("\n")[0] : String(err);
        console.log(`skipped request ${id}: ${msg}`);
    }
}
console.log(
    `sweep done: scanned ${next - from}, pending ${pending}, fulfilled ${fulfilled}, skipped ${skipped}`,
);

// ---------------------------------------------------------------- infinite rounds
// The shared tables need their round lifecycle DRIVEN, not just their beacons
// fulfilled: close expired betting windows, lock decided rounds, sweep
// settlements/refunds, cancel rounds stuck past the randomness timeout.

/** RoundState enum indices (must match InfiniteBlackjack.sol). */
const BETTING = 1;
const DEAL_PENDING = 2;
const ACTING = 3;
const DRAW_PENDING = 4;
const SETTLING = 5;
const CANCELLED = 7;

const infiniteTables = DEPLOYMENTS[megaethTestnet.id]?.infiniteTables ?? [];

async function drive(
    table: `0x${string}`,
    functionName: "lockDeal" | "lockActions" | "settle" | "cancelRound" | "refund",
    args: bigint[],
    label: string,
): Promise<void> {
    try {
        const {request} = await pub.simulateContract({
            address: table,
            abi: infiniteBlackjackAbi,
            functionName,
            args: args as never,
            account,
        });
        const hash = await wallet.writeContract(request);
        await pub.waitForTransactionReceipt({hash});
        console.log(`${label}: ${hash}`);
    } catch (err) {
        // Losing a race with a player's frontend (someone else drove the round
        // first) fails simulation and costs nothing — that's working as intended.
        const msg = err instanceof Error ? err.message.split("\n")[0] : String(err);
        console.log(`${label} skipped: ${msg}`);
    }
}

for (const t of infiniteTables) {
    const table = t.address as `0x${string}`;
    const currentId = (await pub.readContract({
        address: table,
        abi: infiniteBlackjackAbi,
        functionName: "currentRoundId",
    })) as bigint;
    if (currentId === 0n) continue;
    const now = (await pub.getBlock()).timestamp;
    const timeout = (await pub.readContract({
        address: table,
        abi: infiniteBlackjackAbi,
        functionName: "randomnessTimeout",
    })) as bigint;

    // Recent CANCELLED rounds may still owe refunds (permissionless sweep).
    const fromId = currentId > 5n ? currentId - 5n : 1n;
    for (let id = fromId; id <= currentId; id++) {
        const r = (await pub.readContract({
            address: table,
            abi: infiniteBlackjackAbi,
            functionName: "getRound",
            args: [id],
        })) as {
            state: number;
            betDeadline: bigint;
            actDeadline: bigint;
            requestTimestamp: bigint;
            playerCount: number;
            actedCount: number;
            cursor: number;
        };
        const sym = `${t.symbol} infinite round ${id}`;
        if (r.state === CANCELLED && r.cursor < r.playerCount) {
            await drive(table, "refund", [id, 100n], `${sym}: refund sweep`);
        } else if (id === currentId) {
            if (r.state === BETTING && now >= r.betDeadline && r.playerCount > 0) {
                await drive(table, "lockDeal", [], `${sym}: lockDeal`);
            } else if (
                r.state === ACTING
                && (now >= r.actDeadline || r.actedCount >= r.playerCount)
            ) {
                await drive(table, "lockActions", [], `${sym}: lockActions`);
            } else if (r.state === SETTLING) {
                await drive(table, "settle", [100n], `${sym}: settle sweep`);
            } else if (
                (r.state === DEAL_PENDING || r.state === DRAW_PENDING)
                && r.requestTimestamp > 0n
                && now >= r.requestTimestamp + timeout
            ) {
                // Beacon never became fulfillable (see loop above) — free the escrows.
                await drive(table, "cancelRound", [id], `${sym}: cancel stuck round`);
            }
        }
    }
}
console.log("infinite-table drive done.");
