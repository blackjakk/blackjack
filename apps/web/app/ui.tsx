"use client";

import {formatEther} from "viem";
import type {Card} from "@blackjack/sdk";

export function CardView({card, hidden}: {card?: Card; hidden?: boolean}) {
    if (hidden || !card) return <div className="card back">?</div>;
    const red = card.suit === 1 || card.suit === 2;
    return <div className={`card${red ? " red" : ""}`}>{card.label}</div>;
}

export function fmt(x: bigint | undefined): string {
    return x === undefined ? "…" : Number(formatEther(x)).toLocaleString();
}
