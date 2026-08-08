"use client";

import {useEffect, useRef, useState} from "react";
import type {Address} from "viem";
import {formatEther} from "viem";
import {blackjackTableV2Abi, infiniteBlackjackAbi} from "@blackjack/config";
import {
    TABLE_ADDRESS,
    V2_TABLES,
    V3_TABLES,
    ASSET_TABLES,
    INFINITE_TABLES,
    tableToken,
} from "../lib/config.ts";
import {burnerClients} from "../lib/burner.ts";

/**
 * Big-play ticker: derives "big win / big loss" lines from the game contracts'
 * OWN settlement events — verifiable onchain, impossible to fake in chat, and
 * free (nobody posts anything; every client derives the same feed).
 */
export interface Play {
    key: string; // table:txhash:logIndex — dedupe key
    table: Address;
    tableName: string;
    symbol: string;
    player: Address;
    kind: "win" | "loss";
    blackjack: boolean;
    /** Winner's collected payout, or the loser's forfeited wager (token units). */
    amount: bigint;
    timestamp: number;
}

/** Per-token thresholds (18-dec units): a loss >= loss, or a payout >= win, is "big". */
const THRESHOLDS: Record<string, {loss: bigint; win: bigint}> = {
    CHIP: {loss: 100n * 10n ** 18n, win: 200n * 10n ** 18n},
    USDm: {loss: 25n * 10n ** 18n, win: 50n * 10n ** 18n},
    MEGA: {loss: 25n * 10n ** 18n, win: 50n * 10n ** 18n},
    ETH: {loss: 5n * 10n ** 15n, win: 10n * 10n ** 15n},
};

const OUTCOME_BLACKJACK = 1;
const OUTCOME_PLAYER_WIN = 2;
const HISTORY_START = 26_317_836n; // first table deploy block
const CHUNK = 100_000n;

function perHandTables(): {address: Address; name: string}[] {
    return [
        ...(TABLE_ADDRESS ? [{address: TABLE_ADDRESS, name: "Original"}] : []),
        ...V2_TABLES.map((t) => ({address: t.address, name: t.name.split(" (")[0]!})),
        ...V3_TABLES.map((t) => ({address: t.address, name: t.name.split(" (")[0]!})),
        ...ASSET_TABLES.map((t) => ({address: t.table, name: `${t.symbol} Classic`})),
    ];
}

export function tickerTableName(addr: string): string {
    const ph = perHandTables().find((t) => t.address.toLowerCase() === addr.toLowerCase());
    if (ph) return ph.name;
    const inf = INFINITE_TABLES.find((t) => t.address.toLowerCase() === addr.toLowerCase());
    return inf ? `${inf.symbol} Infinite` : `${addr.slice(0, 6)}…`;
}

/** Stream of big plays across every curated table, newest last. */
export function useBigPlays(): Play[] {
    const [plays, setPlays] = useState<Play[]>([]);
    const seen = useRef<Set<string>>(new Set());
    const wagers = useRef<Map<string, bigint>>(new Map()); // per-hand: table:gameId, infinite: table:round:player
    const blockTimes = useRef<Map<string, number>>(new Map());
    const lastBlock = useRef<bigint>(0n);

    useEffect(() => {
        const {pub} = burnerClients();
        const tables = perHandTables();
        const tableAddrs = tables.map((t) => t.address);
        const infAddrs = INFINITE_TABLES.map((t) => t.address);
        let stopped = false;

        const timeOf = async (blockNumber: bigint): Promise<number> => {
            const k = blockNumber.toString();
            const cached = blockTimes.current.get(k);
            if (cached !== undefined) return cached;
            const b = await pub.getBlock({blockNumber});
            const t = Number(b.timestamp);
            blockTimes.current.set(k, t);
            return t;
        };

        const scan = async (fromBlock: bigint, toBlock: bigint) => {
            // Wager sources first, so settlement filtering can see stakes.
            const [created, betsPlaced, settled, seatSettled] = await Promise.all([
                pub.getContractEvents({
                    address: tableAddrs,
                    abi: blackjackTableV2Abi,
                    eventName: "GameCreated",
                    fromBlock,
                    toBlock,
                }),
                pub.getContractEvents({
                    address: infAddrs,
                    abi: infiniteBlackjackAbi,
                    eventName: "BetPlaced",
                    fromBlock,
                    toBlock,
                }),
                pub.getContractEvents({
                    address: tableAddrs,
                    abi: blackjackTableV2Abi,
                    eventName: "GameSettled",
                    fromBlock,
                    toBlock,
                }),
                pub.getContractEvents({
                    address: infAddrs,
                    abi: infiniteBlackjackAbi,
                    eventName: "PlayerSettled",
                    fromBlock,
                    toBlock,
                }),
            ]);
            for (const log of created) {
                const a = log.args as {gameId?: bigint; wager?: bigint};
                if (a.gameId !== undefined && a.wager !== undefined) {
                    wagers.current.set(`${log.address.toLowerCase()}:${a.gameId}`, a.wager);
                }
            }
            for (const log of betsPlaced) {
                const a = log.args as {roundId?: bigint; player?: Address; wager?: bigint};
                if (a.roundId !== undefined && a.player && a.wager !== undefined) {
                    wagers.current.set(
                        `${log.address.toLowerCase()}:${a.roundId}:${a.player.toLowerCase()}`,
                        a.wager,
                    );
                }
            }

            const fresh: Play[] = [];
            const consider = async (
                table: Address,
                player: Address,
                outcome: number,
                payout: bigint,
                wager: bigint | undefined,
                key: string,
                blockNumber: bigint,
            ) => {
                if (seen.current.has(key)) return;
                const symbol = tableToken(table).symbol;
                const th = THRESHOLDS[symbol] ?? THRESHOLDS.CHIP!;
                const isWin =
                    (outcome === OUTCOME_BLACKJACK || outcome === OUTCOME_PLAYER_WIN)
                    && payout >= th.win;
                const isLoss = payout === 0n && wager !== undefined && wager >= th.loss;
                if (!isWin && !isLoss) return;
                seen.current.add(key);
                fresh.push({
                    key,
                    table,
                    tableName: tickerTableName(table),
                    symbol,
                    player,
                    kind: isWin ? "win" : "loss",
                    blackjack: outcome === OUTCOME_BLACKJACK,
                    amount: isWin ? payout : wager!,
                    timestamp: await timeOf(blockNumber),
                });
            };

            for (const log of settled) {
                const a = log.args as {
                    gameId?: bigint;
                    player?: Address;
                    outcome?: number;
                    payout?: bigint;
                };
                if (!a.player || a.gameId === undefined || log.blockNumber === null) continue;
                await consider(
                    log.address as Address,
                    a.player,
                    Number(a.outcome ?? 0),
                    a.payout ?? 0n,
                    wagers.current.get(`${log.address.toLowerCase()}:${a.gameId}`),
                    `${log.address}:${log.transactionHash}:${log.logIndex}`,
                    log.blockNumber,
                );
            }
            for (const log of seatSettled) {
                const a = log.args as {
                    roundId?: bigint;
                    player?: Address;
                    outcome?: number;
                    payout?: bigint;
                };
                if (!a.player || a.roundId === undefined || log.blockNumber === null) continue;
                await consider(
                    log.address as Address,
                    a.player,
                    Number(a.outcome ?? 0),
                    a.payout ?? 0n,
                    wagers.current.get(
                        `${log.address.toLowerCase()}:${a.roundId}:${a.player.toLowerCase()}`,
                    ),
                    `${log.address}:${log.transactionHash}:${log.logIndex}`,
                    log.blockNumber,
                );
            }
            if (fresh.length > 0 && !stopped) {
                setPlays((p) => [...p, ...fresh].sort((x, y) => x.timestamp - y.timestamp));
            }
        };

        (async () => {
            try {
                const latest = await pub.getBlockNumber();
                for (let from = HISTORY_START; from <= latest && !stopped; from += CHUNK) {
                    const to = from + CHUNK - 1n < latest ? from + CHUNK - 1n : latest;
                    await scan(from, to);
                }
                lastBlock.current = latest;
            } catch {
                /* history load failed — live polling below still works from now on */
            }
        })();

        const t = setInterval(async () => {
            try {
                const latest = await pub.getBlockNumber();
                if (latest > lastBlock.current) {
                    const from = lastBlock.current + 1n;
                    lastBlock.current = latest;
                    await scan(from, latest);
                }
            } catch {
                /* transient RPC hiccup; next poll retries */
            }
        }, 4000);
        return () => {
            stopped = true;
            clearInterval(t);
        };
    }, []);

    return plays;
}

export function fmtAmount(x: bigint): string {
    const n = Number(formatEther(x));
    return n >= 1 ? n.toLocaleString(undefined, {maximumFractionDigits: 1}) : n.toPrecision(2);
}
