/**
 * Standalone drand keeper: watches the DrandRandomnessProvider for requests and
 * submits each beacon as soon as its round publishes. Permissionless; the house
 * should keep one of these running (see docs/RANDOMNESS.md liveness assumptions).
 *
 *   RPC_URL=https://carrot.megaeth.com/rpc \
 *   KEEPER_PRIVATE_KEY=0x... PROVIDER=0x... pnpm keeper
 */
import {createPublicClient, createWalletClient, http, type Address} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {runDrandKeeper} from "./keeper.ts";

function env(name: string, fallback?: string): string {
    const v = process.env[name] ?? fallback;
    if (v === undefined) throw new Error(`missing env var ${name}`);
    return v;
}

const rpcUrl = env("RPC_URL", "https://carrot.megaeth.com/rpc");
const account = privateKeyToAccount(env("KEEPER_PRIVATE_KEY") as `0x${string}`);
const provider = env("PROVIDER") as Address;

const publicClient = createPublicClient({transport: http(rpcUrl)});
const walletClient = createWalletClient({account, transport: http(rpcUrl)});

console.log(`drand keeper ${account.address} watching ${provider} via ${rpcUrl}`);
const stop = runDrandKeeper({
    publicClient,
    walletClient,
    provider,
    onFulfilled: (id, tx) => console.log(`fulfilled request ${id}: ${tx}`),
    onError: (id, err) => console.error(`request ${id} failed:`, err),
});

process.on("SIGINT", () => {
    stop();
    process.exit(0);
});
