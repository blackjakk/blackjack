# Game State Machine (normative)

One active game per player address. `gameId` is a monotonically increasing
counter; a player's active game is tracked in `activeGameOf[player]`.

## States

```
NONE                          no active game for this player
AWAITING_INITIAL_RANDOMNESS   wager escrowed + liability reserved; waiting for deal seed
PLAYER_TURN                   player may hit / stand / double (double: first two cards only)
AWAITING_HIT_RANDOMNESS       waiting for one card (hit or double-down card)
AWAITING_DEALER_RANDOMNESS    player done; waiting for dealer draw seed
SETTLED                       terminal; payout transferred; reservation released
CANCELLED                     terminal; randomness timed out; full escrow refunded
```

## Transitions

| From | Trigger | Guard | Effect | To |
| --- | --- | --- | --- | --- |
| NONE | `placeBet(wager)` | not paused; `min ≤ wager ≤ max`; no active game; `2·wager ≤ availableLiquidity`; transferFrom succeeds | escrow `wager`; reserve `2·wager`; request seed | AWAITING_INITIAL_RANDOMNESS |
| AWAITING_INITIAL_RANDOMNESS | `fulfillRandomness` | caller = stored provider; requestId matches; not yet fulfilled | deal player 2 cards + dealer up-card from seed | PLAYER_TURN, or AWAITING_DEALER_RANDOMNESS if player has a natural (auto-stand, new seed requested) |
| PLAYER_TURN | `hit()` | caller = game owner; not paused | request seed | AWAITING_HIT_RANDOMNESS |
| PLAYER_TURN | `double()` | caller = owner; not paused; exactly 2 cards; transferFrom extra `wager` succeeds | escrow +`wager` (stake = 2W; reservation of 2W already covers it); mark doubled; request seed | AWAITING_HIT_RANDOMNESS |
| PLAYER_TURN | `stand()` | caller = owner | request seed | AWAITING_DEALER_RANDOMNESS |
| AWAITING_HIT_RANDOMNESS | `fulfillRandomness` | provider + requestId guards | deal 1 card | bust → SETTLED (dealer wins, no dealer draw); doubled or 21 → AWAITING_DEALER_RANDOMNESS (auto, new seed); else → PLAYER_TURN |
| AWAITING_DEALER_RANDOMNESS | `fulfillRandomness` | provider + requestId guards | dealer draws to ≥ 17 (stands on all 17s); compare; pay | SETTLED |
| AWAITING_* | `cancelTimedOutGame()` | now ≥ requestTime + timeout; caller = game owner or admin | refund full escrow; release reservation | CANCELLED |

Terminal states clear `activeGameOf[player]`, so the player can start a new
game. Full game records are kept in storage by `gameId` and in events.

## Guards that apply everywhere

* Any action on a game in a state not listed above **reverts**
  (`InvalidState`).
* `fulfillRandomness` from any address except the provider stored **on the
  game at request time** reverts; a `requestId` that is not the game's
  current pending request reverts; a second fulfillment of the same request
  reverts (request cleared before card effects — checks-effects-interactions).
* `hit`/`stand`/`double` by any address except the game's player revert.
* After SETTLED or CANCELLED every game-scoped action reverts.

## Pause semantics

`pause()` blocks **new risk**: `placeBet`, `hit`, `double`. It does NOT block
`stand`, `fulfillRandomness`, settlement, or `cancelTimedOutGame` — in-flight
games can always wind down and players are never locked out of escrowed
funds. This is deliberate: an emergency pause that also froze fulfillment
would convert every active game into a stuck game.

Note: with fulfillment allowed during pause, a paused-mid-hand player in
PLAYER_TURN can still `stand` (no new risk) or wait out the timeout; they
cannot `hit`/`double` until unpaused.

## Why busting skips the dealer draw

Under European no-hole-card rules the dealer draws after the player acts; if
the player busts the dealer wins regardless of the dealer's final hand, so
the game settles immediately and saves one randomness round-trip.

## Why natural blackjack auto-stands

With A+10 the player has no meaningful decision (hit/double are strictly
bad; stand is forced). Auto-requesting the dealer seed removes a pointless
transaction and removes the temptation to add player choices after the
outcome-relevant commitment.
