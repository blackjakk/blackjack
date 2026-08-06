import type {Address, Chain} from "viem";
import {megaethTestnet, DEPLOYMENTS} from "@blackjack/config";

/**
 * Frontend deployment configuration. Defaults to the live MegaETH-testnet
 * deployment recorded in @blackjack/config, so `pnpm dev` works zero-config;
 * env vars override for local anvil or a redeploy (see .env.example).
 */
const live = DEPLOYMENTS[megaethTestnet.id];

export const TABLE_ADDRESS = (process.env.NEXT_PUBLIC_TABLE_ADDRESS ??
    live?.table ??
    "") as Address;
export const CHIP_ADDRESS = (process.env.NEXT_PUBLIC_CHIP_ADDRESS ?? live?.chip ?? "") as Address;
export const PROVIDER_ADDRESS = (process.env.NEXT_PUBLIC_PROVIDER_ADDRESS ??
    live?.randomnessProvider ??
    "") as Address;
/** "drand" on MegaETH testnet; "mock" only for local anvil dev. */
export const PROVIDER_KIND = process.env.NEXT_PUBLIC_PROVIDER_KIND ?? "drand";
export const EXPLORER_URL =
    process.env.NEXT_PUBLIC_EXPLORER_URL ?? "https://testnet-mega.etherscan.io";
/** Official MegaETH faucet for gas ETH (Turnstile-gated, humans only). */
export const GAS_FAUCET_URL = "https://testnet.megaeth.com";

const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 6343);
const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL ?? "https://carrot.megaeth.com/rpc";

export const anvilLocal = {
    id: 31337,
    name: "Anvil (local)",
    nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
    rpcUrls: {default: {http: [RPC_URL]}},
    testnet: true,
} as const satisfies Chain;

export const activeChain: Chain =
    CHAIN_ID === megaethTestnet.id
        ? {...megaethTestnet, rpcUrls: {default: {http: [RPC_URL]}}}
        : anvilLocal;

export const isConfigured =
    (TABLE_ADDRESS as string).length === 42 && (CHIP_ADDRESS as string).length === 42;

export function txUrl(hash: string): string {
    return `${EXPLORER_URL}/tx/${hash}`;
}
