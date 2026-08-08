"use client";

import type {ReactNode} from "react";
import {WagmiProvider, createConfig, http} from "wagmi";
// `injected` from @wagmi/core rather than wagmi/connectors: the connectors bundle
// drags in coinbase/base SDKs with unresolved optional deps we don't use.
import {injected} from "@wagmi/core";
import {mossWallet} from "@megaeth-labs/wallet-wagmi-connector";
import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {megaethTestnet} from "@blackjack/config";
import {activeChain} from "../lib/config.ts";

// MOSS (MegaETH's embedded wallet) only serves the hosted networks, so the
// connector is omitted when the app points at a local anvil chain.
const wagmiConfig = createConfig({
    chains: [activeChain],
    connectors:
        activeChain.id === megaethTestnet.id
            ? [
                  injected(),
                  // The hosted wallet app can take longer than the SDK's 10s
                  // default handshake window to boot on a cold cache.
                  mossWallet({network: "testnet", handshakeTimeoutMs: 30_000}),
              ]
            : [injected()],
    transports: {[activeChain.id]: http()},
    // MegaETH mini-blocks confirm in ~10 ms; viem's default 4 s receipt/watch
    // polling would make every action FEEL 4 s slow. Poll fast instead.
    pollingInterval: 250,
});

const queryClient = new QueryClient();

export function Providers({children}: {children: ReactNode}) {
    return (
        <WagmiProvider config={wagmiConfig}>
            <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
        </WagmiProvider>
    );
}
