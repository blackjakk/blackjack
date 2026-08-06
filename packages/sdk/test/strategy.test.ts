import {test} from "node:test";
import assert from "node:assert/strict";
import {decodeCard} from "../src/cards.ts";
import {decideAction} from "../src/strategy.ts";

const card = (rank: number) => decodeCard(rank);
// rank helpers: A=0, 2=1 ... 9=8, T=9, J=10, Q=11, K=12
const A = 0, TWO = 1, THREE = 2, FOUR = 3, FIVE = 4, SIX = 5, SEVEN = 6, EIGHT = 7, NINE = 8, TEN = 9;

test("hard totals follow the basic-strategy matrix", () => {
    // 16 vs 10 hits; 16 vs 6 stands.
    assert.equal(decideAction([card(TEN), card(SIX)], card(TEN)), "hit");
    assert.equal(decideAction([card(TEN), card(SIX)], card(SIX)), "stand");
    // 12 vs 2 hits, 12 vs 4 stands.
    assert.equal(decideAction([card(TEN), card(TWO)], card(TWO)), "hit");
    assert.equal(decideAction([card(TEN), card(TWO)], card(FOUR)), "stand");
    // 17 always stands.
    assert.equal(decideAction([card(TEN), card(SEVEN)], card(A)), "stand");
});

test("doubles only on two cards, with ENHC restraint vs ace", () => {
    // 11 vs 6 doubles; 11 vs A does not (ENHC).
    assert.equal(decideAction([card(FIVE), card(SIX)], card(SIX)), "double");
    assert.equal(decideAction([card(FIVE), card(SIX)], card(A)), "hit");
    // 10 vs 9 doubles, 10 vs 10 hits.
    assert.equal(decideAction([card(FIVE), card(FIVE)], card(NINE)), "double");
    assert.equal(decideAction([card(FIVE), card(FIVE)], card(TEN)), "hit");
    // 9 vs 3-6 doubles, else hit.
    assert.equal(decideAction([card(FOUR), card(FIVE)], card(THREE)), "double");
    assert.equal(decideAction([card(FOUR), card(FIVE)], card(TWO)), "hit");
    // Three-card 11 can no longer double.
    assert.equal(decideAction([card(TWO), card(THREE), card(SIX)], card(SIX)), "hit");
});

test("soft totals", () => {
    // Soft 18 stands vs 2-8, hits vs 9/10/A, doubles vs 3-6.
    assert.equal(decideAction([card(A), card(SEVEN)], card(EIGHT)), "stand");
    assert.equal(decideAction([card(A), card(SEVEN)], card(NINE)), "hit");
    assert.equal(decideAction([card(A), card(SEVEN)], card(FOUR)), "double");
    // Soft 19 stands.
    assert.equal(decideAction([card(A), card(EIGHT)], card(SIX)), "stand");
    // Soft 17 doubles vs 3-6, else hits.
    assert.equal(decideAction([card(A), card(SIX)], card(FOUR)), "double");
    assert.equal(decideAction([card(A), card(SIX)], card(TEN)), "hit");
});

test("determinism: same inputs give same action", () => {
    for (let i = 0; i < 5; i++) {
        assert.equal(decideAction([card(TEN), card(SIX)], card(TEN)), "hit");
    }
});
