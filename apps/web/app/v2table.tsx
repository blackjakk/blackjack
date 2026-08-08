"use client";

import {useCallback, useEffect, useMemo, useRef, useState} from "react";
import {usePublicClient, useReadContract, useReadContracts} from "wagmi";
import {useQueryClient} from "@tanstack/react-query";
import type {Address} from "viem";
import {parseEther} from "viem";
import {blackjackTableV2Abi, blackjackTableV3Abi, testChipAbi, drandRandomnessProviderAbi} from "@blackjack/config";
import {drandPublishTime} from "@blackjack/config";
import {
    unpackCards,
    handValue,
    cardValue,
    GameState,
    Outcome,
    OutcomeNames,
    fetchBeaconSignature,
} from "@blackjack/sdk";
import {PROVIDER_ADDRESS, txUrl} from "../lib/config.ts";
import {VaultPanel} from "./vault.tsx";
import {CardView, TotalBadge, fmt} from "./ui.tsx";
import {rulesSummary} from "./lobby.tsx";

const POLL = {refetchInterval: 1500} as const;

type Call = {
    address: Address;
    abi: unknown;
    functionName: string;
    args?: readonly unknown[];
};
type WriteTx = (args: Call) => Promise<`0x${string}`>;
type WriteBatch = (calls: Call[]) => Promise<`0x${string}`>;

type V2Game = {
    player: Address;
    requestTimestamp: bigint;
    state: number;
    outcome: number;
    doubled: boolean;
    playerCount: number;
    dealerCount: number;
    wager: bigint;
    reservedLiability: bigint;
    payout: bigint;
    playerCards: bigint;
    dealerCards: bigint;
    pendingRequestId: bigint;
    pendingProvider: Address;
    // V3 (split) extras — undefined on V2 tables.
    split?: boolean;
    splitAces?: boolean;
    activeHand?: number;
    hand2Count?: number;
    hand2Cards?: bigint;
    outcome2?: number;
};

type Rules = {
    dealerHitsSoft17: boolean;
    blackjackNum: number;
    blackjackDen: number;
    doubleRule: number;
    lateSurrender: boolean;
};

/** Multi-hand play view for one BlackjackTableV2. */
export function V2Table({
    table,
    name,
    address,
    isConnected,
    oneClickActive,
    isMoss,
    isV3,
    token,
    symbol,
    vault,
    writeTx,
    writeBatch,
}: {
    table: Address;
    name: string;
    address: Address | undefined;
    isConnected: boolean;
    oneClickActive: boolean;
    isMoss: boolean;
    isV3: boolean;
    token: Address;
    symbol: string;
    vault: Address | undefined;
    writeTx: WriteTx;
    writeBatch: WriteBatch;
}) {
    const publicClient = usePublicClient();
    const queryClient = useQueryClient();
    const tbl = {address: table, abi: isV3 ? blackjackTableV3Abi : blackjackTableV2Abi} as const;
    const chip = {address: token, abi: testChipAbi} as const;
    const zero = "0x0000000000000000000000000000000000000000" as const;

    const {data: rules} = useReadContract({...tbl, functionName: "rules"});
    const {data: liquidity} = useReadContract({...tbl, functionName: "liquidity", query: POLL});
    const {data: minWager} = useReadContract({...tbl, functionName: "minWager", query: POLL});
    const {data: maxWager} = useReadContract({...tbl, functionName: "maxWager", query: POLL});
    const {data: paused} = useReadContract({...tbl, functionName: "paused", query: POLL});
    const {data: maxConcurrent} = useReadContract({...tbl, functionName: "maxConcurrentGames"});
    const {data: allowance} = useReadContract({
        ...chip,
        functionName: "allowance",
        args: [address ?? zero, table],
        query: {...POLL, enabled: isConnected},
    });
    const {data: activeIds} = useReadContract({
        ...tbl,
        functionName: "activeGamesOf",
        args: [address ?? zero],
        query: {...POLL, enabled: isConnected},
    });

    // Keep recently finished hands on screen after they leave the active set.
    const [finished, setFinished] = useState<bigint[]>([]);
    const prevActive = useRef<bigint[]>([]);
    useEffect(() => {
        const now = (activeIds as readonly bigint[] | undefined) ?? [];
        const gone = prevActive.current.filter((id) => !now.includes(id));
        if (gone.length > 0) {
            setFinished((f) => [...gone, ...f.filter((id) => !gone.includes(id))].slice(0, 4));
        }
        prevActive.current = [...now];
    }, [activeIds]);

    const shownIds = useMemo(() => {
        const active = ((activeIds as readonly bigint[] | undefined) ?? []).slice().sort((a, b) =>
            a < b ? -1 : 1,
        );
        return [...active, ...finished.filter((id) => !active.includes(id))];
    }, [activeIds, finished]);

    const {data: gamesData} = useReadContracts({
        contracts: shownIds.map((id) => ({...tbl, functionName: "getGame", args: [id]}) as const),
        query: {...POLL, enabled: shownIds.length > 0},
    });

    // Per-pending-request drand round info (for countdowns + auto-reveal).
    const awaitingGames = useMemo(() => {
        const out: {id: bigint; g: V2Game}[] = [];
        shownIds.forEach((id, i) => {
            const g = gamesData?.[i]?.result as V2Game | undefined;
            if (g && g.pendingRequestId !== 0n) out.push({id, g});
        });
        return out;
    }, [shownIds, gamesData]);

    const [rounds, setRounds] = useState<Record<string, bigint>>({});
    useEffect(() => {
        if (!publicClient || awaitingGames.length === 0) return;
        let stop = false;
        (async () => {
            const next: Record<string, bigint> = {};
            for (const {g} of awaitingGames) {
                try {
                    const req = (await publicClient.readContract({
                        address: PROVIDER_ADDRESS,
                        abi: drandRandomnessProviderAbi,
                        functionName: "requests",
                        args: [g.pendingRequestId],
                    })) as readonly unknown[];
                    next[g.pendingRequestId.toString()] = BigInt(req[1] as bigint);
                } catch {
                    /* transient RPC error — retried on the next poll */
                }
            }
            if (!stop) setRounds((r) => ({...r, ...next}));
        })();
        return () => {
            stop = true;
        };
    }, [publicClient, awaitingGames]);

    const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
    useEffect(() => {
        const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
        return () => clearInterval(t);
    }, []);

    // ------------------------------------------------------------ actions

    const [busy, setBusy] = useState<string | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [lastTx, setLastTx] = useState<string | null>(null);

    const run = useCallback(
        async (label: string, fn: () => Promise<`0x${string}` | null>, ignore?: RegExp) => {
            setBusy(label);
            setError(null);
            try {
                const hash = await fn();
                if (hash) {
                    setLastTx(hash);
                    await publicClient?.waitForTransactionReceipt({hash});
                    // Refresh every polled read NOW instead of waiting out the
                    // next poll tick — actions register instantly.
                    void queryClient.invalidateQueries();
                }
            } catch (err) {
                const full = err instanceof Error ? err.message : String(err);
                if (!ignore?.test(full)) setError(full.split("\n")[0]!);
            } finally {
                setBusy(null);
            }
        },
        [publicClient, queryClient],
    );

    const [wagerInput, setWagerInput] = useState("10");
    /** Fresh allowance read: the polled hook can be stale, and MOSS auto-revokes
     *  standalone approvals — bundling approve+action into one atomic batch is
     *  the only reliable shape there. */
    const callsWithAllowance = async (wager: bigint, action: Call): Promise<Call[]> => {
        const live = (await publicClient!.readContract({
            ...chip,
            functionName: "allowance",
            args: [address!, table],
        })) as bigint;
        const calls: Call[] = [];
        if (live < wager) {
            calls.push({
                ...chip,
                functionName: "approve",
                args: [table, wager * (isMoss ? 1n : 100n)],
            });
        }
        calls.push(action);
        return calls;
    };

    const onBet = () =>
        run("bet", async () => {
            const wager = parseEther(wagerInput || "0");
            return writeBatch(
                await callsWithAllowance(wager, {...tbl, functionName: "placeBet", args: [wager]}),
            );
        });

    const onAct = (fn: "hit" | "stand" | "surrender", id: bigint) =>
        run(`${fn}:${id}`, () => writeTx({...tbl, functionName: fn, args: [id]}));

    const onSplit = (id: bigint, wager: bigint) =>
        run(`split:${id}`, async () =>
            writeBatch(
                await callsWithAllowance(wager, {...tbl, functionName: "split", args: [id]}),
            ),
        );

    const splitAllowedFor = (g: V2Game): boolean => {
        if (!isV3 || g.playerCount !== 2 || g.doubled || g.split) return false;
        const cards = unpackCards(g.playerCards, g.playerCount);
        return cardValue(cards[0]!) === cardValue(cards[1]!);
    };

    const onDouble = (id: bigint, wager: bigint) =>
        run(`double:${id}`, async () =>
            writeBatch(
                await callsWithAllowance(wager, {...tbl, functionName: "double", args: [id]}),
            ),
        );

    const onBeacon = (g: V2Game) =>
        run(
            `beacon:${g.pendingRequestId}`,
            async () => {
                const round = rounds[g.pendingRequestId.toString()];
                if (!round) return null;
                const sig = await fetchBeaconSignature(round);
                return writeTx({
                    address: PROVIDER_ADDRESS,
                    abi: drandRandomnessProviderAbi,
                    functionName: "fulfill",
                    args: [g.pendingRequestId, sig],
                });
            },
            /AlreadyFulfilled/i,
        );

    // Auto-reveal: as soon as a request's drand round publishes; RETRIES every
    // 8 s while the request stays pending (a failed submit must not strand the
    // hand until the keeper cron).
    const autoTried = useRef<Map<string, number>>(new Map());
    useEffect(() => {
        if (busy) return;
        for (const {g} of awaitingGames) {
            const key = g.pendingRequestId.toString();
            const round = rounds[key];
            if (!round) continue;
            if (BigInt(now) < drandPublishTime(round)) continue;
            const last = autoTried.current.get(key) ?? 0;
            if (now - last < 8) continue;
            autoTried.current.set(key, now);
            void onBeacon(g);
            break; // one at a time; the next poll picks up the rest
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [awaitingGames, rounds, now, busy]);

    // ------------------------------------------------------------ render

    const r = rules as Rules | undefined;
    const activeCount = ((activeIds as readonly bigint[] | undefined) ?? []).length;
    const canAddHand =
        isConnected && !paused && maxConcurrent !== undefined && activeCount < Number(maxConcurrent);

    const doubleAllowedFor = (g: V2Game): boolean => {
        if (!r || g.playerCount !== 2 || g.doubled) return false;
        if (r.doubleRule === 3) return false;
        if (r.doubleRule === 0) return true;
        const cards = unpackCards(g.playerCards, g.playerCount);
        const hv = handValue(cards);
        if (hv.soft) return false;
        return r.doubleRule === 1 ? hv.total >= 9 && hv.total <= 11 : hv.total >= 10 && hv.total <= 11;
    };

    return (
        <>
            <div className="panel">
                <div className="row">
                    <div>
                        <div className="hand-title">{name}</div>
                        <div className="status">{r ? rulesSummary(r) : "…"}</div>
                    </div>
                    <div className="status">
                        bets {fmt(minWager)}–{fmt(maxWager)} · bankroll {fmt(liquidity?.[0])} ·
                        available {fmt(liquidity?.[2])} {paused ? " · ⏸ paused" : ""}
                    </div>
                </div>
            </div>

            {vault && (
                <VaultPanel
                    vault={vault}
                    token={token}
                    symbol={symbol}
                    address={address}
                    isConnected={isConnected}
                    writeTx={writeTx}
                    writeBatch={writeBatch}
                    fundTarget={table}
                />
            )}

            {shownIds.length === 0 && (
                <div className="panel status">
                    No hands yet — place a bet to be dealt in. You can play up to{" "}
                    {maxConcurrent?.toString() ?? "…"} hands at once here.
                </div>
            )}

            {shownIds.map((id, i) => {
                const g = gamesData?.[i]?.result as V2Game | undefined;
                if (!g) return null;
                const playerCards = unpackCards(g.playerCards, g.playerCount);
                const dealerCards = unpackCards(g.dealerCards, g.dealerCount);
                const hand2Cards =
                    g.split && g.hand2Cards !== undefined
                        ? unpackCards(g.hand2Cards, g.hand2Count ?? 0)
                        : [];
                const pv = handValue(playerCards);
                const h2v = handValue(hand2Cards);
                const dv = handValue(dealerCards);
                const isOver = g.state === GameState.SETTLED || g.state === GameState.CANCELLED;
                const isTurn = g.state === GameState.PLAYER_TURN;
                const awaiting = g.pendingRequestId !== 0n;
                const round = rounds[g.pendingRequestId.toString()];
                const ready = round !== undefined && BigInt(now) >= drandPublishTime(round);
                const outcomeClass =
                    g.outcome === Outcome.PLAYER_BLACKJACK || g.outcome === Outcome.PLAYER_WIN
                        ? "win"
                        : g.outcome === Outcome.PUSH || g.outcome === Outcome.CANCELLED_REFUND
                          ? "push"
                          : "lose";

                return (
                    <div className="panel felt" key={id.toString()}>
                        <div className="row">
                            <div className="hand-title">
                                Hand #{id.toString()} · wager{" "}
                                {fmt(g.doubled ? g.wager * 2n : g.wager)} {symbol}
                                {g.doubled ? " (doubled)" : ""}
                            </div>
                        </div>
                        <div className="hand-title" style={{marginTop: 8}}>
                            Dealer
                            {dealerCards.length > 0 && (
                                <TotalBadge total={dv.total} soft={dv.soft} bust={dv.total > 21} />
                            )}
                        </div>
                        <div className="cards">
                            {dealerCards.map((c, j) => (
                                <CardView key={j} card={c} />
                            ))}
                            {!isOver && dealerCards.length === 1 && <CardView hidden />}
                            {dealerCards.length === 0 && <span className="status">no cards yet</span>}
                        </div>
                        <div className="hand-title" style={{marginTop: 8}}>
                            {g.split ? "You — hand 1" : "You"}
                            {playerCards.length > 0 && (
                                <TotalBadge total={pv.total} soft={pv.soft} bust={pv.total > 21} />
                            )}
                            {g.split && !isOver && g.activeHand === 0 && " ◀"}
                            {g.split && isOver && (
                                <span className="status">
                                    {" "}
                                    {(OutcomeNames[g.outcome] ?? "?").replaceAll("_", " ")}
                                </span>
                            )}
                        </div>
                        <div className="cards">
                            {playerCards.map((c, j) => (
                                <CardView key={j} card={c} />
                            ))}
                            {playerCards.length === 0 && <span className="status">dealing…</span>}
                        </div>
                        {g.split && (
                            <>
                                <div className="hand-title" style={{marginTop: 8}}>
                                    You — hand 2
                                    {hand2Cards.length > 0 && (
                                        <TotalBadge
                                            total={h2v.total}
                                            soft={h2v.soft}
                                            bust={h2v.total > 21}
                                        />
                                    )}
                                    {!isOver && g.activeHand === 1 && " ◀"}
                                    {isOver && (
                                        <span className="status">
                                            {" "}
                                            {(OutcomeNames[g.outcome2 ?? 0] ?? "?").replaceAll(
                                                "_",
                                                " ",
                                            )}
                                        </span>
                                    )}
                                </div>
                                <div className="cards">
                                    {hand2Cards.map((c, j) => (
                                        <CardView key={j} card={c} />
                                    ))}
                                    {hand2Cards.length === 0 && (
                                        <span className="status">waiting for hand 1…</span>
                                    )}
                                </div>
                            </>
                        )}

                        <div className="row" style={{marginTop: 10}}>
                            {isTurn && (
                                <div className="row" style={{gap: 8}}>
                                    <button disabled={!!busy} onClick={() => onAct("hit", id)}>
                                        {busy === `hit:${id}` ? "…" : "Hit"}
                                    </button>
                                    <button disabled={!!busy} onClick={() => onAct("stand", id)}>
                                        {busy === `stand:${id}` ? "…" : "Stand"}
                                    </button>
                                    {doubleAllowedFor(g) && (
                                        <button
                                            disabled={!!busy || paused === true}
                                            onClick={() => onDouble(id, g.wager)}
                                        >
                                            {busy === `double:${id}` ? "…" : "Double"}
                                        </button>
                                    )}
                                    {splitAllowedFor(g) && (
                                        <button
                                            disabled={!!busy || paused === true}
                                            onClick={() => onSplit(id, g.wager)}
                                        >
                                            {busy === `split:${id}` ? "…" : "Split"}
                                        </button>
                                    )}
                                    {r?.lateSurrender && g.playerCount === 2 && !g.doubled && !g.split && (
                                        <button
                                            className="secondary"
                                            disabled={!!busy}
                                            onClick={() => onAct("surrender", id)}
                                        >
                                            {busy === `surrender:${id}` ? "…" : "Surrender"}
                                        </button>
                                    )}
                                </div>
                            )}
                            {awaiting && (
                                <span className="status">
                                    🎲{" "}
                                    {ready
                                        ? "beacon published — revealing…"
                                        : round
                                          ? `cards locked to drand round ${round} — ~${Math.max(0, Number(drandPublishTime(round)) - now)}s`
                                          : "committing to a future drand round…"}
                                </span>
                            )}
                            {awaiting && ready && error && (
                                <button className="pulse" disabled={!!busy} onClick={() => onBeacon(g)}>
                                    Submit beacon
                                </button>
                            )}
                        </div>

                        {isOver && (
                            <div className={`result ${outcomeClass}`} style={{marginTop: 10}}>
                                {(OutcomeNames[g.outcome] ?? "?").replaceAll("_", " ")}
                                {g.payout > 0n ? ` — paid ${fmt(g.payout)} CHIP` : ""}
                            </div>
                        )}
                    </div>
                );
            })}

            {canAddHand && (
                <div className="panel row">
                    <span className="status">
                        {activeCount === 0 ? "Place a bet:" : `Add another hand (${activeCount}/${maxConcurrent?.toString()}):`}
                    </span>
                    <span className="row" style={{gap: 8}}>
                        <input
                            value={wagerInput}
                            onChange={(e) => setWagerInput(e.target.value)}
                            inputMode="decimal"
                            aria-label={`wager in ${symbol}`}
                            style={{width: 90}}
                        />
                        <button disabled={!!busy} onClick={onBet}>
                            {busy === "bet" ? "Placing…" : "Place bet"}
                        </button>
                    </span>
                </div>
            )}

            {lastTx && (
                <div className="status">
                    last tx:{" "}
                    <a href={txUrl(lastTx)} target="_blank" rel="noreferrer">
                        {lastTx.slice(0, 10)}…{lastTx.slice(-8)}
                    </a>
                </div>
            )}
            {error && <div className="error">{error}</div>}
        </>
    );
}
