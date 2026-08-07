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
import {megaethTestnet, DEPLOYMENTS, drandRandomnessProviderAbi} from "@blackjack/config";
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
