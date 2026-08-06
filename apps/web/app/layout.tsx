import type {Metadata} from "next";
import type {ReactNode} from "react";
import "./globals.css";
import {Providers} from "./providers.tsx";

export const metadata: Metadata = {
    title: "MegaETH Blackjack — Testnet Play Money",
    description:
        "Fully onchain European no-hole-card blackjack on MegaETH testnet. Test chips only — no monetary value.",
};

export default function RootLayout({children}: {children: ReactNode}) {
    return (
        <html lang="en">
            <body>
                <div className="warning-banner" role="alert">
                    ⚠️ TESTNET PLAY MONEY — CHIP tokens have <strong>no monetary value</strong>.
                    Unaudited MVP contracts; MegaETH testnet state may be reset at any time.
                </div>
                <Providers>{children}</Providers>
            </body>
        </html>
    );
}
