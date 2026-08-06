import type {
    Address,
    Hash,
    PublicClient,
    WalletClient,
    Account,
    Chain,
    TransactionReceipt,
} from "viem";
import {decodeEventLog} from "viem";
import {blackjackTableAbi, testChipAbi} from "@blackjack/config";
import {unpackCards, handValue, type Card, type HandValue} from "./cards.ts";

// Const objects instead of TS enums: this package runs under Node's type stripping,
// which only supports erasable syntax.
export const GameState = {
    NONE: 0,
    AWAITING_INITIAL_RANDOMNESS: 1,
    PLAYER_TURN: 2,
    AWAITING_HIT_RANDOMNESS: 3,
    AWAITING_DEALER_RANDOMNESS: 4,
    SETTLED: 5,
    CANCELLED: 6,
} as const;
export type GameState = (typeof GameState)[keyof typeof GameState];
export const GameStateNames = [
    "NONE",
    "AWAITING_INITIAL_RANDOMNESS",
    "PLAYER_TURN",
    "AWAITING_HIT_RANDOMNESS",
    "AWAITING_DEALER_RANDOMNESS",
    "SETTLED",
    "CANCELLED",
] as const;

export const Outcome = {
    NONE: 0,
    PLAYER_BLACKJACK: 1,
    PLAYER_WIN: 2,
    PUSH: 3,
    DEALER_WIN: 4,
    PLAYER_BUST: 5,
    DEALER_BLACKJACK: 6,
    CANCELLED_REFUND: 7,
} as const;
export type Outcome = (typeof Outcome)[keyof typeof Outcome];
export const OutcomeNames = [
    "NONE",
    "PLAYER_BLACKJACK",
    "PLAYER_WIN",
    "PUSH",
    "DEALER_WIN",
    "PLAYER_BUST",
    "DEALER_BLACKJACK",
    "CANCELLED_REFUND",
] as const;

export const AWAITING_STATES = new Set<GameState>([
    GameState.AWAITING_INITIAL_RANDOMNESS,
    GameState.AWAITING_HIT_RANDOMNESS,
    GameState.AWAITING_DEALER_RANDOMNESS,
]);

export interface TableConfig {
    minWager: bigint;
    maxWager: bigint;
    randomnessTimeout: bigint;
    randomnessProvider: Address;
    chip: Address;
    paused: boolean;
}

export interface Liquidity {
    bankroll: bigint;
    reserved: bigint;
    available: bigint;
}

export interface GameView {
    gameId: bigint;
    player: Address;
    state: GameState;
    outcome: Outcome;
    wager: bigint;
    stake: bigint;
    doubled: boolean;
    payout: bigint;
    playerCards: Card[];
    dealerCards: Card[];
    playerValue: HandValue;
    dealerValue: HandValue;
    pendingRequestId: bigint;
    pendingProvider: Address;
    requestTimestamp: bigint;
}

export interface BlackjackClientOptions {
    publicClient: PublicClient;
    /** Required for state-changing calls (bets, actions, faucet, fulfill). */
    walletClient?: WalletClient;
    table: Address;
    chip: Address;
    chain?: Chain;
}

/**
 * Thin viem-based client for the BlackjackTable. All game state is read from the
 * chain — there is no trusted backend anywhere in this stack.
 */
export class BlackjackClient {
    readonly pub: PublicClient;
    readonly wallet?: WalletClient;
    readonly table: Address;
    readonly chip: Address;
    readonly chain?: Chain;

    constructor(opts: BlackjackClientOptions) {
        this.pub = opts.publicClient;
        this.wallet = opts.walletClient;
        this.table = opts.table;
        this.chip = opts.chip;
        this.chain = opts.chain;
    }

    private account(): Account {
        const account = this.wallet?.account;
        if (!account) throw new Error("walletClient with an account is required for writes");
        return account;
    }

    private async write(
        address: Address,
        abi: readonly unknown[],
        functionName: string,
        args: readonly unknown[] = [],
    ): Promise<TransactionReceipt> {
        const {request} = await this.pub.simulateContract({
            address,
            abi: abi as never,
            functionName: functionName as never,
            args: args as never,
            account: this.account(),
            chain: this.chain,
        } as never);
        const hash = await this.wallet!.writeContract(request as never);
        return this.pub.waitForTransactionReceipt({hash});
    }

    // ------------------------------------------------------------ reads

    async getTableConfig(): Promise<TableConfig> {
        const c = {address: this.table, abi: blackjackTableAbi} as const;
        const [minWager, maxWager, timeout, provider, chip, paused] = await Promise.all([
            this.pub.readContract({...c, functionName: "minWager"}),
            this.pub.readContract({...c, functionName: "maxWager"}),
            this.pub.readContract({...c, functionName: "randomnessTimeout"}),
            this.pub.readContract({...c, functionName: "randomnessProvider"}),
            this.pub.readContract({...c, functionName: "chip"}),
            this.pub.readContract({...c, functionName: "paused"}),
        ]);
        return {
            minWager,
            maxWager,
            randomnessTimeout: BigInt(timeout),
            randomnessProvider: provider,
            chip,
            paused,
        };
    }

    async getLiquidity(): Promise<Liquidity> {
        const [bankroll, reserved, available] = await this.pub.readContract({
            address: this.table,
            abi: blackjackTableAbi,
            functionName: "liquidity",
        });
        return {bankroll, reserved, available};
    }

    async getChipBalance(owner: Address): Promise<bigint> {
        return this.pub.readContract({
            address: this.chip,
            abi: testChipAbi,
            functionName: "balanceOf",
            args: [owner],
        });
    }

    async getActiveGameId(player: Address): Promise<bigint | null> {
        const id = await this.pub.readContract({
            address: this.table,
            abi: blackjackTableAbi,
            functionName: "activeGameOf",
            args: [player],
        });
        return id === 0n ? null : id;
    }

    async getGame(gameId: bigint): Promise<GameView> {
        const g = await this.pub.readContract({
            address: this.table,
            abi: blackjackTableAbi,
            functionName: "getGame",
            args: [gameId],
        });
        const playerCards = unpackCards(g.playerCards, g.playerCount);
        const dealerCards = unpackCards(g.dealerCards, g.dealerCount);
        const stake = g.doubled ? g.wager * 2n : BigInt(g.wager);
        return {
            gameId,
            player: g.player,
            state: g.state as GameState,
            outcome: g.outcome as Outcome,
            wager: BigInt(g.wager),
            stake,
            doubled: g.doubled,
            payout: BigInt(g.payout),
            playerCards,
            dealerCards,
            playerValue: handValue(playerCards),
            dealerValue: handValue(dealerCards),
            pendingRequestId: g.pendingRequestId,
            pendingProvider: g.pendingProvider,
            requestTimestamp: BigInt(g.requestTimestamp),
        };
    }

    // ------------------------------------------------------------ writes

    /** Claim play-money chips from the faucet (rate-limited per address onchain). */
    async claimFaucet(): Promise<TransactionReceipt> {
        return this.write(this.chip, testChipAbi, "faucet");
    }

    async approveChips(amount: bigint): Promise<TransactionReceipt> {
        return this.write(this.chip, testChipAbi, "approve", [this.table, amount]);
    }

    /** Place a bet and return the created gameId (parsed from the GameCreated event). */
    async startGame(wager: bigint): Promise<{gameId: bigint; receipt: TransactionReceipt}> {
        const receipt = await this.write(this.table, blackjackTableAbi, "placeBet", [wager]);
        for (const log of receipt.logs) {
            if (log.address.toLowerCase() !== this.table.toLowerCase()) continue;
            try {
                const ev = decodeEventLog({
                    abi: blackjackTableAbi,
                    data: log.data,
                    topics: log.topics,
                });
                if (ev.eventName === "GameCreated") {
                    return {gameId: (ev.args as {gameId: bigint}).gameId, receipt};
                }
            } catch {
                /* not our event */
            }
        }
        throw new Error("GameCreated event not found in receipt");
    }

    async hit(): Promise<TransactionReceipt> {
        return this.write(this.table, blackjackTableAbi, "hit");
    }

    async stand(): Promise<TransactionReceipt> {
        return this.write(this.table, blackjackTableAbi, "stand");
    }

    async double(): Promise<TransactionReceipt> {
        return this.write(this.table, blackjackTableAbi, "double");
    }

    async cancelTimedOutGame(gameId: bigint): Promise<TransactionReceipt> {
        return this.write(this.table, blackjackTableAbi, "cancelTimedOutGame", [gameId]);
    }

    // ------------------------------------------------------------ waiting

    /**
     * Poll until the game leaves all randomness-awaiting states (i.e. the pending
     * request was fulfilled or the game was cancelled). Resolves with the fresh view.
     */
    async waitForRandomness(
        gameId: bigint,
        opts: {pollMs?: number; timeoutMs?: number} = {},
    ): Promise<GameView> {
        return this.waitUntil(gameId, (g) => !AWAITING_STATES.has(g.state), opts);
    }

    /** Poll until the game is SETTLED or CANCELLED. */
    async waitForResult(
        gameId: bigint,
        opts: {pollMs?: number; timeoutMs?: number} = {},
    ): Promise<GameView> {
        return this.waitUntil(
            gameId,
            (g) => g.state === GameState.SETTLED || g.state === GameState.CANCELLED,
            opts,
        );
    }

    async waitUntil(
        gameId: bigint,
        predicate: (g: GameView) => boolean,
        {pollMs = 500, timeoutMs = 120_000}: {pollMs?: number; timeoutMs?: number} = {},
    ): Promise<GameView> {
        const deadline = Date.now() + timeoutMs;
        for (;;) {
            const g = await this.getGame(gameId);
            if (predicate(g)) return g;
            if (Date.now() > deadline) {
                throw new Error(
                    `timed out waiting on game ${gameId} (state=${GameStateNames[g.state]})`,
                );
            }
            await new Promise((r) => setTimeout(r, pollMs));
        }
    }
}
