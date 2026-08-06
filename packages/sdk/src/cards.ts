/**
 * Card decoding + hand valuation, mirroring BlackjackLib.sol exactly.
 * A card is 0..51: rank = card % 13 (0 = Ace .. 12 = King), suit = card / 13.
 */

export const RANK_NAMES = [
    "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K",
] as const;
export const SUIT_SYMBOLS = ["♠", "♥", "♦", "♣"] as const;

export interface Card {
    id: number;
    rank: number; // 0..12
    suit: number; // 0..3
    label: string; // e.g. "A♠"
}

export function decodeCard(id: number): Card {
    if (id < 0 || id > 51) throw new Error(`invalid card id ${id}`);
    const rank = id % 13;
    const suit = Math.floor(id / 13);
    return {id, rank, suit, label: `${RANK_NAMES[rank]}${SUIT_SYMBOLS[suit]}`};
}

/** Unpack a hand stored as one byte per card in a uint256 (same layout as Solidity). */
export function unpackCards(packed: bigint, count: number): Card[] {
    const cards: Card[] = [];
    for (let i = 0; i < count; i++) {
        cards.push(decodeCard(Number((packed >> BigInt(8 * i)) & 0xffn)));
    }
    return cards;
}

export function cardValue(card: Card): number {
    if (card.rank === 0) return 1; // Ace (soft handling at hand level)
    if (card.rank >= 9) return 10; // 10/J/Q/K
    return card.rank + 1;
}

export interface HandValue {
    total: number;
    soft: boolean;
}

/** Best blackjack value; identical semantics to BlackjackLib.handValue. */
export function handValue(cards: Card[]): HandValue {
    let sum = 0;
    let hasAce = false;
    for (const c of cards) {
        const v = cardValue(c);
        if (v === 1) hasAce = true;
        sum += v;
    }
    if (hasAce && sum + 10 <= 21) return {total: sum + 10, soft: true};
    return {total: sum, soft: false};
}

export function isNatural(cards: Card[]): boolean {
    return cards.length === 2 && handValue(cards).total === 21;
}

export function formatHand(cards: Card[]): string {
    return cards.map((c) => c.label).join(" ");
}
