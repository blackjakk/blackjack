import {
    BlackjackClient,
    GameState,
    GameStateNames,
    Outcome,
    OutcomeNames,
    type GameView,
} from "./client.ts";
import {decideAction} from "./strategy.ts";
import {formatHand} from "./cards.ts";

export interface BotHooks {
    /** Called whenever the game is stuck awaiting randomness; must get it fulfilled.
     *  (drand: submit/await the beacon; local mock: fulfill with a dev seed.) */
    ensureRandomness: (game: GameView) => Promise<void>;
    log?: (msg: string) => void;
}

export interface BotGameResult {
    gameId: bigint;
    outcome: Outcome;
    wager: bigint;
    stake: bigint;
    payout: bigint;
    playerHand: string;
    dealerHand: string;
}

/**
 * Play one full game with deterministic basic strategy through the SDK.
 * Test chips only — this bot has no notion of real money.
 */
export async function playOneGame(
    client: BlackjackClient,
    wager: bigint,
    hooks: BotHooks,
): Promise<BotGameResult> {
    const log = hooks.log ?? (() => {});
    const {gameId} = await client.startGame(wager);
    log(`game ${gameId}: bet placed (${wager} wei-chips)`);

    for (;;) {
        let game = await client.getGame(gameId);

        if (game.state === GameState.SETTLED || game.state === GameState.CANCELLED) {
            log(
                `game ${gameId}: ${OutcomeNames[game.outcome]} — player [${formatHand(game.playerCards)}] ` +
                    `dealer [${formatHand(game.dealerCards)}] payout ${game.payout}`,
            );
            return {
                gameId,
                outcome: game.outcome,
                wager: game.wager,
                stake: game.stake,
                payout: game.payout,
                playerHand: formatHand(game.playerCards),
                dealerHand: formatHand(game.dealerCards),
            };
        }

        if (game.pendingRequestId !== 0n) {
            const pending = game.pendingRequestId;
            await hooks.ensureRandomness(game);
            // Wait for THIS request to resolve; fulfilling it may immediately open a
            // new one (e.g. hit card -> 21 auto-requests the dealer seed), which the
            // next loop iteration handles.
            await client.waitUntil(gameId, (g) => g.pendingRequestId !== pending);
            continue;
        }

        if (game.state === GameState.PLAYER_TURN) {
            const action = decideAction(game.playerCards, game.dealerCards[0]!);
            log(
                `game ${gameId}: player ${game.playerValue.total}${game.playerValue.soft ? "s" : ""} ` +
                    `[${formatHand(game.playerCards)}] vs ${game.dealerCards[0]!.label} -> ${action}`,
            );
            if (action === "hit") await client.hit();
            else if (action === "double") await client.double();
            else await client.stand();
            continue;
        }

        throw new Error(`unexpected state ${GameStateNames[game.state]} for game ${gameId}`);
    }
}
