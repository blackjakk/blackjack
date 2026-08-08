"use client";

import {formatEther} from "viem";
import {RANK_NAMES, SUIT_SYMBOLS, type Card} from "@blackjack/sdk";

/** A rendered playing card: corner indices, center pip / face medallion. */
export function CardView({card, hidden}: {card?: Card; hidden?: boolean}) {
    if (hidden || !card) {
        return (
            <div className="pcard back" aria-label="face-down card">
                <div className="back-inner" />
            </div>
        );
    }
    const red = card.suit === 1 || card.suit === 2;
    const rank = RANK_NAMES[card.rank]!;
    const suit = SUIT_SYMBOLS[card.suit]!;
    const face = rank === "J" || rank === "Q" || rank === "K";
    return (
        <div className={`pcard deal${red ? " red" : ""}`} aria-label={card.label}>
            <div className="corner tl">
                <span className="c-rank">{rank}</span>
                <span className="c-suit">{suit}</span>
            </div>
            {face ? (
                <div className="face-med">
                    <span className="face-letter">{rank}</span>
                    <span className="face-suit">{suit}</span>
                </div>
            ) : rank === "A" ? (
                <div className="pip ace">{suit}</div>
            ) : (
                <div className="pip">
                    <span className="pip-rank">{rank}</span>
                    <span className="pip-suit">{suit}</span>
                </div>
            )}
            <div className="corner br">
                <span className="c-rank">{rank}</span>
                <span className="c-suit">{suit}</span>
            </div>
        </div>
    );
}

/** Hand total badge shown next to DEALER / YOU labels. */
export function TotalBadge({total, soft, bust}: {total?: number; soft?: boolean; bust?: boolean}) {
    if (!total) return null;
    return (
        <span className={`total-badge${bust ? " bust" : total === 21 ? " tb21" : ""}`}>
            {total}
            {soft ? "s" : ""}
        </span>
    );
}

export function fmt(x: bigint | undefined): string {
    return x === undefined ? "…" : Number(formatEther(x)).toLocaleString();
}
