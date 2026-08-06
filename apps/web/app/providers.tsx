"use client";

import type {ReactNode} from "react";
import {WagmiProvider, createConfig, http} from "wagmi";
// `injected` from @wagmi/core rather than wagmi/connectors: the connectors bundle
// drags in coinbase/base SDKs with unresolved optional deps we don't use.
import {injected} from "@wagmi/core";
import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {activeChain} from "../lib/config.ts";

const wagmiConfig = createConfig({
    chains: [activeChain],
    connectors: [injected()],
    transports: {[activeChain.id]: http()},
});

const queryClient = new QueryClient();

export function Providers({children}: {children: ReactNode}) {
    return (
        <WagmiProvider config={wagmiConfig}>
            <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
        </WagmiProvider>
    );
}
