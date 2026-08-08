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

/** Short commit id baked in at build time, for verifying which deploy is live. */
export const BUILD_ID = (process.env.NEXT_PUBLIC_BUILD_ID ?? "dev").slice(0, 7);

// ---------------------------------------------------------------- v2 (Phase A)

/** Permissionless TableFactory (v2 variant tables). Empty when not deployed. */
export const FACTORY_ADDRESS = (process.env.NEXT_PUBLIC_FACTORY_ADDRESS ??
    live?.factory ??
    "") as Address;

/** Curated launch tables with display names; community tables come from the registry. */
export const V2_TABLES: {name: string; address: Address}[] = live?.v2Tables ?? [];

export const hasV2 = (FACTORY_ADDRESS as string).length === 42;

/** Phase D: per-asset SHARED vaults (one pool backs every game of the asset). */
export const SHARED_VAULTS = live?.sharedVaults ?? [];

/** Phase D: shared multiplayer Infinite tables, one per asset. */
export const INFINITE_TABLES = live?.infiniteTables ?? [];

export function isInfiniteTable(table: string): boolean {
    return INFINITE_TABLES.some((t) => t.address.toLowerCase() === table.toLowerCase());
}

export function isSharedVault(vault: string): boolean {
    return SHARED_VAULTS.some((v) => v.vault.toLowerCase() === vault.toLowerCase());
}

/** table (lowercase) -> its vault (legacy per-table vaults + shared-pool members). */
export const VAULTS: Record<string, Address> = Object.fromEntries([
    ...(live?.vaults ?? []).map((v) => [v.table.toLowerCase(), v.vault] as const),
    ...SHARED_VAULTS.flatMap((s) => s.tables.map((t) => [t.toLowerCase(), s.vault] as const)),
]);

/** Real-asset tables (USDm / ETH-as-WETH / MEGA), each with its own vault. */
export const ASSET_TABLES = live?.assetTables ?? [];

/** Split-capable V3 tables (extended ABI). */
export const V3_TABLES: {name: string; address: Address}[] = live?.v3Tables ?? [];

export function isV3Table(table: string): boolean {
    return V3_TABLES.some((t) => t.address.toLowerCase() === table.toLowerCase());
}

/** Wager token + display symbol for any known table. */
export function tableToken(table: string): {token: Address; symbol: string} {
    const at = ASSET_TABLES.find((t) => t.table.toLowerCase() === table.toLowerCase());
    if (at) return {token: at.token, symbol: at.symbol};
    return {token: CHIP_ADDRESS, symbol: "CHIP"};
}
