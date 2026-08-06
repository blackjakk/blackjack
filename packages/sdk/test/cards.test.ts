import {test} from "node:test";
import assert from "node:assert/strict";
import {decodeCard, unpackCards, handValue, isNatural} from "../src/cards.ts";

const card = (rank: number, suit = 0) => decodeCard(rank + 13 * suit);

test("decodeCard round-trips rank and suit", () => {
    const c = decodeCard(25); // 25 = rank 12 (K), suit 1 (♥)
    assert.equal(c.rank, 12);
    assert.equal(c.suit, 1);
    assert.equal(c.label, "K♥");
});

test("unpackCards mirrors Solidity byte layout", () => {
    // Cards 0 (A♠), 12 (K♠), 51 (K♣) packed little-endian byte-per-card.
    const packed = 0n | 0n | (12n << 8n) | (51n << 16n);
    const cards = unpackCards(packed, 3);
    assert.deepEqual(
        cards.map((c) => c.id),
        [0, 12, 51],
    );
});

test("handValue: soft/hard ace handling matches contract", () => {
    assert.deepEqual(handValue([card(0), card(5)]), {total: 17, soft: true}); // A+6
    assert.deepEqual(handValue([card(0), card(5), card(9)]), {total: 17, soft: false}); // A+6+10
    assert.deepEqual(handValue([card(0), card(0)]), {total: 12, soft: true}); // A+A
    assert.deepEqual(handValue(Array.from({length: 11}, () => card(0))), {
        total: 21,
        soft: true,
    }); // 11 aces
    assert.deepEqual(handValue(Array.from({length: 12}, () => card(0))), {
        total: 12,
        soft: false,
    }); // 12 aces
});

test("isNatural only on two-card 21", () => {
    assert.equal(isNatural([card(0), card(12)]), true); // A+K
    assert.equal(isNatural([card(0), card(0), card(8)]), false); // A+A+9 = 21, 3 cards
    assert.equal(isNatural([card(9), card(9)]), false); // 20
});
