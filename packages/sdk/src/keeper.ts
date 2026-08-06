import type {Address, PublicClient, WalletClient, Chain, TransactionReceipt} from "viem";
import {
    drandRandomnessProviderAbi,
    mockRandomnessProviderAbi,
    drandRoundUrl,
    drandPublishTime,
    DRAND_API_BASES,
} from "@blackjack/config";

/**
 * Keeper helpers: submit drand beacons for pending randomness requests.
 *
 * Fulfillment is PERMISSIONLESS — anyone may run this. The house is expected to run
 * one continuously; without a live keeper, hands stall until someone (the player's
 * browser, a bystander) submits, or the onchain timeout allows a refund. This
 * liveness assumption is documented in docs/RANDOMNESS.md.
 */

export interface DrandRequest {
    requestId: bigint;
    consumer: Address;
    revealRound: bigint;
    fulfilled: boolean;
    gameId: bigint;
}

export async function readDrandRequest(
    pub: PublicClient,
    provider: Address,
    requestId: bigint,
): Promise<DrandRequest> {
    const [consumer, revealRound, fulfilled, gameId] = await pub.readContract({
        address: provider,
        abi: drandRandomnessProviderAbi,
        functionName: "requests",
        args: [requestId],
    });
    return {requestId, consumer, revealRound: BigInt(revealRound), fulfilled, gameId};
}

/** Fetch the beacon signature for a round, trying all public relays. */
export async function fetchBeaconSignature(round: bigint): Promise<`0x${string}`> {
    let lastError: unknown;
    for (const base of DRAND_API_BASES) {
        try {
            const res = await fetch(drandRoundUrl(round, base));
            if (!res.ok) throw new Error(`${base}: HTTP ${res.status}`);
            const body = (await res.json()) as {round: number; signature: string};
            if (BigInt(body.round) !== round) throw new Error(`${base}: round mismatch`);
            return `0x${body.signature}`;
        } catch (err) {
            lastError = err;
        }
    }
    throw new Error(`all drand relays failed for round ${round}: ${String(lastError)}`);
}

/** Sleep until `round` should be published (plus a small aggregation margin). */
export async function waitForRoundPublish(round: bigint, marginMs = 1000): Promise<void> {
    const at = Number(drandPublishTime(round)) * 1000 + marginMs;
    const delay = at - Date.now();
    if (delay > 0) await new Promise((r) => setTimeout(r, delay));
}

/**
 * Fulfill one pending request on the drand adapter: wait for the pinned round,
 * fetch its beacon and submit it. No-op (returns null) if already fulfilled.
 */
export async function fulfillDrandRequest(opts: {
    publicClient: PublicClient;
    walletClient: WalletClient;
    provider: Address;
    requestId: bigint;
    chain?: Chain;
}): Promise<TransactionReceipt | null> {
    const {publicClient: pub, walletClient, provider, requestId, chain} = opts;
    const req = await readDrandRequest(pub, provider, requestId);
    if (req.fulfilled) return null;

    await waitForRoundPublish(req.revealRound);
    const sig = await fetchBeaconSignature(req.revealRound);

    const {request} = await pub.simulateContract({
        address: provider,
        abi: drandRandomnessProviderAbi,
        functionName: "fulfill",
        args: [requestId, sig],
        account: walletClient.account!,
        chain,
    });
    const hash = await walletClient.writeContract(request);
    return pub.waitForTransactionReceipt({hash});
}

/**
 * LOCAL DEV ONLY: fulfill a MockRandomnessProvider request with a caller-chosen seed.
 * The mock is trivially manipulable and must never be the provider on a public network.
 */
export async function fulfillMockRequest(opts: {
    publicClient: PublicClient;
    walletClient: WalletClient;
    provider: Address;
    requestId: bigint;
    seed: `0x${string}`;
    chain?: Chain;
}): Promise<TransactionReceipt> {
    const {publicClient: pub, walletClient, provider, requestId, seed, chain} = opts;
    const {request} = await pub.simulateContract({
        address: provider,
        abi: mockRandomnessProviderAbi,
        functionName: "fulfill",
        args: [requestId, seed],
        account: walletClient.account!,
        chain,
    });
    const hash = await walletClient.writeContract(request);
    return pub.waitForTransactionReceipt({hash});
}

/**
 * Run a continuous keeper: watch RandomnessRequested events on the drand adapter and
 * fulfill each request as its round publishes. Returns an unsubscribe function.
 */
export function runDrandKeeper(opts: {
    publicClient: PublicClient;
    walletClient: WalletClient;
    provider: Address;
    chain?: Chain;
    onFulfilled?: (requestId: bigint, tx: `0x${string}`) => void;
    onError?: (requestId: bigint, err: unknown) => void;
    pollingInterval?: number;
}): () => void {
    const {publicClient: pub, provider} = opts;
    const inFlight = new Set<string>();

    return pub.watchContractEvent({
        address: provider,
        abi: drandRandomnessProviderAbi,
        eventName: "RandomnessRequested",
        pollingInterval: opts.pollingInterval ?? 1000,
        onLogs: (logs) => {
            for (const log of logs) {
                const requestId = log.args.requestId;
                if (requestId === undefined || inFlight.has(requestId.toString())) continue;
                inFlight.add(requestId.toString());
                fulfillDrandRequest({...opts, requestId})
                    .then((receipt) => {
                        if (receipt) opts.onFulfilled?.(requestId, receipt.transactionHash);
                    })
                    .catch((err) => opts.onError?.(requestId, err))
                    .finally(() => inFlight.delete(requestId.toString()));
            }
        },
    });
}
