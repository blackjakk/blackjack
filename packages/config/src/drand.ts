/**
 * drand quicknet beacon constants.
 *
 * Chain hash and parameters are fixed by the drand quicknet network and verified
 * against docs.megaeth.com/developer-docs/vrf and the live onchain verifier
 * (PERIOD_SECONDS() == 3, GENESIS_TIMESTAMP() == 1692803367).
 */
export const DRAND_QUICKNET_CHAIN_HASH =
    "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971";

export const DRAND_QUICKNET_PERIOD_SECONDS = 3;
export const DRAND_QUICKNET_GENESIS_TIMESTAMP = 1692803367;

/** Public, unauthenticated relay endpoints serving identical JSON. */
export const DRAND_API_BASES = [
    "https://api.drand.sh",
    "https://api2.drand.sh",
    "https://api3.drand.sh",
] as const;

export function drandRoundUrl(round: bigint | number, base: string = DRAND_API_BASES[0]): string {
    return `${base}/v2/chains/${DRAND_QUICKNET_CHAIN_HASH}/rounds/${round}`;
}

/** Unix seconds at which `round` becomes producible. */
export function drandPublishTime(round: bigint): bigint {
    return (
        BigInt(DRAND_QUICKNET_GENESIS_TIMESTAMP) +
        (round - 1n) * BigInt(DRAND_QUICKNET_PERIOD_SECONDS)
    );
}
