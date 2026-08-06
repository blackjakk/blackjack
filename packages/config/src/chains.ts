import type {Chain} from "viem";

/**
 * MegaETH testnet chain definition.
 *
 * Values verified against the official docs (docs.megaeth.com/user-guide/connect)
 * and the live RPC (eth_chainId == 0x18c7) on 2026-08-06. RPC endpoints are
 * rate-limited and may change — re-check the docs before deployments.
 */
export const megaethTestnet = {
    id: 6343,
    name: "MegaETH Testnet",
    nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
    rpcUrls: {
        default: {http: ["https://carrot.megaeth.com/rpc"]},
    },
    blockExplorers: {
        default: {name: "MegaETH Testnet Explorer", url: "https://testnet-mega.etherscan.io"},
    },
    testnet: true,
} as const satisfies Chain;

/** Mini-blocks land in ~10 ms; EVM blocks every 1 s (official docs). */
export const MEGAETH_MINIBLOCK_MS = 10;
export const MEGAETH_EVM_BLOCK_MS = 1000;
