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

## Split (V3 tables only)

* Any equal-VALUE first two cards may be split (K+10 qualifies) for a second
  wager equal to the first.
* Hands play sequentially — hand 1 to completion, then hand 2 — each card from
  its own committed drand seed.
* Split aces receive exactly ONE card each and auto-stand; a post-split 21 is
  NOT a natural (pays 1:1, loses to a dealer natural).
* No re-splits, no double-after-split, no surrender-after-split. These keep the
  2x-wager liability reservation exact: the worst case (both hands win 1:1)
  equals the doubled-win ceiling.
* ENHC: a dealer natural takes both stakes; if both hands bust, the dealer
  never draws.

## Infinite tables (shared multiplayer rounds)

* One common round: every player who bets during the betting window shares the
  SAME two starting cards and dealer up-card (beacon #1, requested only after
  betting closes).
* Each player then commits exactly ONE play before beacon #2 exists:
  * **stand**;
  * **hit to a target T (12–21)** — draw until the hand's best total reaches T
    or busts (the committed form of hitting; per-card decisions would leak the
    next card, so they don't exist here);
  * **double** (one card, second wager escrowed at commit time);
  * **surrender** (if the table allows it).
  No commitment by the decision deadline = stand, so an AFK player can never
  stall the table.
* Beacon #2 is requested only after decisions lock; every player's draw cards
  come from their own derivation stream of it (`keccak(seed, player)`) and the
  dealer's from `keccak(seed)`. One beacon pair serves any number of players.
* Outcomes and payouts per seat match the v2 table exactly (same ENHC rules,
  same 2x-wager liability reservation). A bust settles as PLAYER_BUST even when
  the dealer later shows a natural (same money). Surrender returns half the
  wager even against a dealer natural — the same player-friendly surrender the
  v2 tables settle early (documented deviation from live ENHC).
* Settlement and refunds are permissionless paginated sweeps; a payout whose
  token transfer fails is parked as a deferred credit (`withdrawDeferred`)
  instead of blocking the seats behind it.
