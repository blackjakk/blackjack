import {type Card, cardValue, handValue} from "./cards.ts";

export type Action = "hit" | "stand" | "double";

/**
 * Deterministic basic blackjack strategy for the table's rule set (ENHC, dealer
 * stands on all 17s, hit/stand/double only — no split/surrender/insurance).
 *
 * This is the standard published basic-strategy matrix restricted to the available
 * actions; where double is unavailable (3+ cards) the fallback is the matrix's
 * hit/stand line. Under ENHC, 11-vs-Ace/Ten doubles are avoided (dealer blackjack
 * takes the doubled stake), matching common ENHC charts. Deterministic by
 * construction: same inputs → same action.
 */
export function decideAction(playerCards: Card[], dealerUpCard: Card): Action {
    const {total, soft} = handValue(playerCards);
    const canDouble = playerCards.length === 2;
    // Dealer up-card value with Ace as 11 for chart lookup (2..11).
    const up = dealerUpCard.rank === 0 ? 11 : cardValue(dealerUpCard);

    if (total >= 21) return "stand";

    if (soft) {
        // Soft totals (A counted as 11).
        if (total >= 19) return "stand";
        if (total === 18) {
            if (canDouble && up >= 3 && up <= 6) return "double";
            if (up >= 9) return "hit"; // 9, 10, A
            return "stand"; // 2-8
        }
        // Soft 13-17.
        if (canDouble) {
            if ((total === 17 || total === 16) && up >= 3 && up <= 6) return "double";
            if ((total === 15 || total === 14) && up >= 4 && up <= 6) return "double";
            if (total === 13 && up >= 5 && up <= 6) return "double";
        }
        return "hit";
    }

    // Hard totals.
    if (total >= 17) return "stand";
    if (total >= 13) return up <= 6 ? "stand" : "hit";
    if (total === 12) return up >= 4 && up <= 6 ? "stand" : "hit";
    if (total === 11) return canDouble && up <= 10 ? "double" : "hit"; // no double vs A (ENHC)
    if (total === 10) return canDouble && up <= 9 ? "double" : "hit";
    if (total === 9) return canDouble && up >= 3 && up <= 6 ? "double" : "hit";
    return "hit"; // 4-8
}
