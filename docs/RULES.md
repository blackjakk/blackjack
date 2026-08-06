# Blackjack Rules (v1)

European no-hole-card (ENHC), single player vs house dealer.

## Rule configuration

| Rule | Value |
| --- | --- |
| Shoe | Nominal six-deck shoe. **MVP samples with replacement** (see note) |
| Dealer | Stands on ALL 17s, including soft 17; hits below 17 |
| Hole card | None — dealer has only an up-card during the player's turn (ENHC) |
| Dealer draw timing | After the player stands / doubles / reaches 21; skipped if the player busts |
| Blackjack payout | 3:2 (natural on first two cards only) |
| Natural vs 21 | Natural blackjack beats any non-natural 21 |
| Dealer natural (ENHC) | Beats every non-natural player hand and takes the **entire** stake, including the doubled portion |
| Both naturals | Push |
| Ties | Push (stake returned) |
| Double down | First two cards only, any total; one card, then forced stand; doubles the stake |
| Hit | Allowed while total < 21 |
| Split / insurance / surrender | Not available in v1 |
| Ace | 1 or 11 (best non-busting value) |
| 2–9 | Face value |
| 10 / J / Q / K | 10 |

## Card representation

A card is `uint8 ∈ [0, 51]`: `rank = card % 13` (0 = Ace, 1 = Two, …,
9 = Ten, 10 = Jack, 11 = Queen, 12 = King), `suit = card / 13` (0–3, cosmetic
only). Hands are packed into a single `uint256` (one byte per card) plus a
count — no strings, no per-card storage slots.

## Hand valuation

Sum with every ace as 1; if the hand contains an ace and `total + 10 ≤ 21`,
the total is **soft** `total + 10`. A hand is a natural iff it is the first
two cards and totals 21.

## Payouts (stake S = wager W, or 2W after double)

| Outcome | Player receives | House delta |
| --- | --- | --- |
| Player natural, dealer not | `W + 1.5W` | `−1.5W` |
| Both naturals | `W` (push) | 0 |
| Dealer natural, player not | 0 | `+S` |
| Player busts | 0 | `+S` |
| Dealer busts (player didn't) | `2S` | `−S` |
| Player total > dealer total | `2S` | `−S` |
| Push | `S` | 0 |
| Dealer total > player total | 0 | `+S` |

(A doubled hand cannot be a natural — natural is first-two-cards only, and a
natural auto-stands before double is possible.)

## Infinite-shoe note

Deriving each card independently from committed randomness means card
removal has no effect (equivalent to an infinite number of decks). Basic
strategy EV differs slightly from a real 6-deck shoe and card counting is
meaningless. This is a documented, deliberate MVP simplification; the
drawing code is isolated so a persistent finite shoe can be added later
without changing the state machine.
