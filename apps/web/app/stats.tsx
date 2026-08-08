"use client";

import {useCallback, useEffect, useRef, useState} from "react";
import {usePublicClient, useReadContracts} from "wagmi";
import type {Address} from "viem";
import {blackjackTableV2Abi, tableChatAbi, DEPLOYMENTS, megaethTestnet} from "@blackjack/config";
import {OutcomeNames} from "@blackjack/sdk";
import {TABLE_ADDRESS, V2_TABLES} from "../lib/config.ts";
import {fmt} from "./ui.tsx";

const live = DEPLOYMENTS[megaethTestnet.id];
const CHAT_ADDRESS = (live?.chat ?? "") as Address;
const SCAN_FROM = live?.deployBlock ?? 0n;
const CHUNK = 100_000n;
const CACHE_KEY = "bj-stats-v1";

/** All tables the scoreboard aggregates (v1 + curated v2). */
const TABLES: {name: string; address: Address}[] = [
    {name: "Original", address: TABLE_ADDRESS},
    ...V2_TABLES,
];

type PlayerStats = {
    hands: number;
    wins: number;
    pushes: number;
    losses: number;
    surrenders: number;
    staked: bigint;
    paid: bigint;
};
type HandRow = {
    table: string;
    gameId: string;
    player: string;
    outcome: number;
    payout: bigint;
    block: string;
};
type Store = {
    lastBlock: bigint;
    players: Map<string, PlayerStats>;
    // per game: wager + doubled (joined into stats at settlement time)
    wagers: Map<string, {wager: bigint; doubled: boolean; player: string}>;
    hands: HandRow[]; // newest-first, all players (filtered per viewer at render)
};

const blank = (): Store => ({lastBlock: 0n, players: new Map(), wagers: new Map(), hands: []});

function serialize(s: Store): string {
    return JSON.stringify({
        lastBlock: s.lastBlock.toString(),
        players: [...s.players.entries()].map(([k, v]) => [
            k,
            {...v, staked: v.staked.toString(), paid: v.paid.toString()},
        ]),
        hands: s.hands.slice(0, 400).map((h) => ({...h, payout: h.payout.toString()})),
        // Unsettled games only (settled entries are deleted at join time) — must
        // survive reloads so stakes aren't lost for hands that settle later.
        wagers: [...s.wagers.entries()].map(([k, v]) => [
            k,
            {wager: v.wager.toString(), doubled: v.doubled, player: v.player},
        ]),
    });
}

function deserialize(raw: string): Store | null {
    try {
        const p = JSON.parse(raw) as {
            lastBlock: string;
            players: [string, {hands: number; wins: number; pushes: number; losses: number; surrenders: number; staked: string; paid: string}][];
            hands: (Omit<HandRow, "payout"> & {payout: string})[];
            wagers?: [string, {wager: string; doubled: boolean; player: string}][];
        };
        return {
            lastBlock: BigInt(p.lastBlock),
            players: new Map(
                p.players.map(([k, v]) => [
                    k,
                    {...v, staked: BigInt(v.staked), paid: BigInt(v.paid)},
                ]),
            ),
            wagers: new Map(
                (p.wagers ?? []).map(([k, v]) => [
                    k,
                    {wager: BigInt(v.wager), doubled: v.doubled, player: v.player},
                ]),
            ),
            hands: p.hands.map((h) => ({...h, payout: BigInt(h.payout)})),
        };
    } catch {
        return null;
    }
}

const WIN = new Set([1, 2]);
const LOSS = new Set([4, 5, 6]);

/** Onchain scoreboard: leaderboard + the viewer's recent hands, from events. */
export function StatsPanel({address}: {address: Address | undefined}) {
    const publicClient = usePublicClient();
    const store = useRef<Store>(blank());
    const [version, setVersion] = useState(0);
    const [scanning, setScanning] = useState(true);

    const scan = useCallback(async () => {
        const pub = publicClient;
        if (!pub || SCAN_FROM === 0n) return;
        const s = store.current;
        const latest = await pub.getBlockNumber();
        let from = s.lastBlock > 0n ? s.lastBlock + 1n : SCAN_FROM;
        if (from > latest) return;
        for (; from <= latest; from += CHUNK) {
            const to = from + CHUNK - 1n < latest ? from + CHUNK - 1n : latest;
            for (const t of TABLES) {
                // Same event shapes on v1 and v2 — the v2 ABI decodes both.
                const [created, doubled, settled] = await Promise.all([
                    pub.getContractEvents({
                        address: t.address, abi: blackjackTableV2Abi,
                        eventName: "GameCreated", fromBlock: from, toBlock: to,
                    }),
                    pub.getContractEvents({
                        address: t.address, abi: blackjackTableV2Abi,
                        eventName: "PlayerDoubled", fromBlock: from, toBlock: to,
                    }),
                    pub.getContractEvents({
                        address: t.address, abi: blackjackTableV2Abi,
                        eventName: "GameSettled", fromBlock: from, toBlock: to,
                    }),
                ]);
                for (const log of created) {
                    const a = log.args as {gameId: bigint; player: Address; wager: bigint};
                    s.wagers.set(`${t.address}:${a.gameId}`, {
                        wager: a.wager, doubled: false, player: a.player.toLowerCase(),
                    });
                }
                for (const log of doubled) {
                    const a = log.args as {gameId: bigint};
                    const w = s.wagers.get(`${t.address}:${a.gameId}`);
                    if (w) w.doubled = true;
                }
                for (const log of settled) {
                    const a = log.args as {
                        gameId: bigint; player: Address; outcome: number; payout: bigint;
                    };
                    const key = a.player.toLowerCase();
                    const wagerKey = `${t.address}:${a.gameId}`;
                    const w = s.wagers.get(wagerKey);
                    s.wagers.delete(wagerKey);
                    const stake = w ? w.wager * (w.doubled ? 2n : 1n) : 0n;
                    const outcome = Number(a.outcome);
                    if (outcome === 7) continue; // cancelled refunds aren't hands
                    const p = s.players.get(key) ?? {
                        hands: 0, wins: 0, pushes: 0, losses: 0, surrenders: 0,
                        staked: 0n, paid: 0n,
                    };
                    p.hands++;
                    if (WIN.has(outcome)) p.wins++;
                    else if (outcome === 3) p.pushes++;
                    else if (LOSS.has(outcome)) p.losses++;
                    else if (outcome === 8) p.surrenders++;
                    p.staked += stake;
                    p.paid += a.payout;
                    s.players.set(key, p);
                    s.hands.unshift({
                        table: t.name,
                        gameId: a.gameId.toString(),
                        player: key,
                        outcome,
                        payout: a.payout,
                        block: (log.blockNumber ?? 0n).toString(),
                    });
                }
            }
            s.lastBlock = to;
        }
        s.hands = s.hands.slice(0, 400);
        try {
            localStorage.setItem(CACHE_KEY, serialize(s));
        } catch {
            /* storage full — cache is optional */
        }
        setVersion((v) => v + 1);
    }, [publicClient]);

    useEffect(() => {
        const cached = localStorage.getItem(CACHE_KEY);
        const parsed = cached ? deserialize(cached) : null;
        if (parsed) {
            store.current = parsed;
            setVersion((v) => v + 1);
        }
        let stop = false;
        const loop = async () => {
            try {
                await scan();
            } catch {
                /* transient RPC failure — retried on the next tick */
            }
            if (!stop) setScanning(false);
        };
        void loop();
        const t = setInterval(loop, 20_000);
        return () => {
            stop = true;
            clearInterval(t);
        };
    }, [scan]);

    // Leaderboard: top players by net, with chat nicknames where set.
    const board = [...store.current.players.entries()]
        .map(([addr, p]) => ({addr, ...p, net: p.paid - p.staked}))
        .sort((a, b) => (b.net > a.net ? 1 : b.net < a.net ? -1 : b.hands - a.hands))
        .slice(0, 8);
    const {data: nickData} = useReadContracts({
        contracts: board.map(
            (r) =>
                ({
                    address: CHAT_ADDRESS,
                    abi: tableChatAbi,
                    functionName: "nicknameOf",
                    args: [r.addr as Address],
                }) as const,
        ),
        query: {enabled: board.length > 0 && (CHAT_ADDRESS as string).length === 42},
    });
    const nameFor = (addr: string, i: number) => {
        const nick = nickData?.[i]?.result as string | undefined;
        if (nick && nick.length > 0) return nick;
        return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
    };

    const mine = address?.toLowerCase();
    const myStats = mine ? store.current.players.get(mine) : undefined;
    const myHands = mine ? store.current.hands.filter((h) => h.player === mine).slice(0, 10) : [];
    void version;

    return (
        <div className="panel">
            <div className="row">
                <div className="hand-title">🏆 Leaderboard — all onchain, all tables</div>
                {scanning && <span className="status">scanning chain…</span>}
            </div>
            {board.length === 0 ? (
                <div className="status">No settled hands yet.</div>
            ) : (
                <div className="board">
                    <div className="board-row board-head">
                        <span>#</span>
                        <span>player</span>
                        <span>hands</span>
                        <span>W / P / L</span>
                        <span>net CHIP</span>
                    </div>
                    {board.map((r, i) => (
                        <div
                            className={`board-row${mine === r.addr ? " board-me" : ""}`}
                            key={r.addr}
                        >
                            <span>{i + 1}</span>
                            <span className="board-name">{nameFor(r.addr, i)}</span>
                            <span>{r.hands}</span>
                            <span>
                                {r.wins} / {r.pushes} / {r.losses}
                            </span>
                            <span className={r.net >= 0n ? "pos" : "neg"}>
                                {r.net >= 0n ? "+" : "−"}
                                {fmt(r.net >= 0n ? r.net : -r.net)}
                            </span>
                        </div>
                    ))}
                </div>
            )}
            {myHands.length > 0 && (
                <div style={{marginTop: 10}}>
                    <div className="hand-title">Your recent hands</div>
                    <div className="history">
                        {myHands.map((h) => (
                            <div key={`${h.table}:${h.gameId}`}>
                                {h.table} #{h.gameId} — {outcomeLabel(h.outcome)}
                                {h.payout > 0n ? ` (paid ${fmt(h.payout)} CHIP)` : ""}
                            </div>
                        ))}
                    </div>
                </div>
            )}
            {myStats && (
                <div className="status" style={{marginTop: 8}}>
                    You: {myStats.hands} hands · {myStats.wins}W {myStats.pushes}P{" "}
                    {myStats.losses}L{myStats.surrenders > 0 ? ` ${myStats.surrenders}S` : ""} ·
                    net{" "}
                    {myStats.paid >= myStats.staked
                        ? `+${fmt(myStats.paid - myStats.staked)}`
                        : `−${fmt(myStats.staked - myStats.paid)}`}{" "}
                    CHIP
                </div>
            )}
        </div>
    );
}

export function outcomeLabel(outcome: number): string {
    return (OutcomeNames[outcome] ?? "?").replaceAll("_", " ");
}
