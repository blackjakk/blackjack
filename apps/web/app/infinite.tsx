"use client";

import {useCallback, useEffect, useMemo, useRef, useState} from "react";
import {usePublicClient, useReadContract, useReadContracts} from "wagmi";
import {useQueryClient} from "@tanstack/react-query";
import type {Address} from "viem";
import {parseEther} from "viem";
import {
    infiniteBlackjackAbi,
    testChipAbi,
    tableChatAbi,
    drandRandomnessProviderAbi,
    drandPublishTime,
    DEPLOYMENTS,
    megaethTestnet,
} from "@blackjack/config";
import {unpackCards, handValue, OutcomeNames, fetchBeaconSignature} from "@blackjack/sdk";
import {PROVIDER_ADDRESS, txUrl} from "../lib/config.ts";
import {VaultPanel} from "./vault.tsx";
import {CardView, TotalBadge, fmt} from "./ui.tsx";

const POLL = {refetchInterval: 1500} as const;
const ZERO = "0x0000000000000000000000000000000000000000" as const;
const CHAT_ADDRESS = (DEPLOYMENTS[megaethTestnet.id]?.chat ?? "") as Address;

type Call = {
    address: Address;
    abi: unknown;
    functionName: string;
    args?: readonly unknown[];
};
type WriteTx = (args: Call) => Promise<`0x${string}`>;
type WriteBatch = (calls: Call[]) => Promise<`0x${string}`>;

/** RoundState enum indices (mirror InfiniteBlackjack.sol). */
const RS = {
    NONE: 0,
    BETTING: 1,
    DEAL_PENDING: 2,
    ACTING: 3,
    DRAW_PENDING: 4,
    SETTLING: 5,
    DONE: 6,
    CANCELLED: 7,
} as const;

/** Action enum indices. */
const ACT = {PENDING: 0, STAND: 1, HIT: 2, DOUBLE: 3, SURRENDER: 4} as const;
const ACTION_LABEL = ["…", "stand", "hit", "double", "surrender"] as const;

type Round = {
    state: number;
    betDeadline: bigint;
    actDeadline: bigint;
    requestTimestamp: bigint;
    playerCount: number;
    actedCount: number;
    cursor: number;
    pendingRequestId: bigint;
    pendingProvider: Address;
    drawSeed: `0x${string}`;
    playerCards: bigint;
    dealerCards: bigint;
    dealerCardCount: number;
};

type Bet = {
    wager: bigint;
    action: number;
    hitTarget: number;
    settled: boolean;
    outcome: number;
    payout: bigint;
    cards: bigint;
    cardCount: number;
};

type Rules = {
    dealerHitsSoft17: boolean;
    blackjackNum: number;
    blackjackDen: number;
    doubleRule: number;
    lateSurrender: boolean;
};

/**
 * Shared multiplayer table: everyone bets into one common round, shares the same
 * two starting cards and dealer up-card, then commits their own play before the
 * draw beacon exists. State derives from chain polling only.
 */
export function InfiniteTable({
    table,
    name,
    address,
    isConnected,
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
    token: Address;
    symbol: string;
    vault: Address | undefined;
    writeTx: WriteTx;
    writeBatch: WriteBatch;
}) {
    const publicClient = usePublicClient();
    const queryClient = useQueryClient();
    const tbl = {address: table, abi: infiniteBlackjackAbi} as const;
    const chip = {address: token, abi: testChipAbi} as const;

    const {data: roundIdData} = useReadContract({...tbl, functionName: "currentRoundId", query: POLL});
    const roundId = (roundIdData as bigint | undefined) ?? 0n;
    const {data: roundData} = useReadContract({
        ...tbl,
        functionName: "getRound",
        args: [roundId],
        query: {...POLL, enabled: roundId > 0n},
    });
    const round = roundData as Round | undefined;
    const {data: rules} = useReadContract({...tbl, functionName: "rules"});
    const {data: minWager} = useReadContract({...tbl, functionName: "minWager"});
    const {data: maxWager} = useReadContract({...tbl, functionName: "maxWager"});
    const {data: liquidity} = useReadContract({...tbl, functionName: "liquidity", query: POLL});
    const {data: playersData} = useReadContract({
        ...tbl,
        functionName: "playersOf",
        args: [roundId],
        query: {...POLL, enabled: roundId > 0n},
    });
    const players = (playersData as readonly Address[] | undefined) ?? [];
    const {data: betsData} = useReadContracts({
        contracts: players.map(
            (p) => ({...tbl, functionName: "betOf", args: [roundId, p]}) as const,
        ),
        query: {...POLL, enabled: players.length > 0},
    });
    const {data: deferred} = useReadContract({
        ...tbl,
        functionName: "deferredPayouts",
        args: [address ?? ZERO],
        query: {...POLL, enabled: isConnected},
    });

    const {data: nickData} = useReadContracts({
        contracts: players.map(
            (p) =>
                ({
                    address: CHAT_ADDRESS,
                    abi: tableChatAbi,
                    functionName: "nicknameOf",
                    args: [p],
                }) as const,
        ),
        query: {refetchInterval: 30_000, enabled: players.length > 0 && CHAT_ADDRESS.length === 42},
    });
    const seatName = (p: Address, i: number) => {
        const nick = nickData?.[i]?.result as string | undefined;
        return nick && nick.length > 0 ? nick : `${p.slice(0, 6)}…${p.slice(-4)}`;
    };

    const myBet = useMemo(() => {
        if (!address) return undefined;
        const i = players.findIndex((p) => p.toLowerCase() === address.toLowerCase());
        if (i < 0) return undefined;
        return betsData?.[i]?.result as Bet | undefined;
    }, [players, betsData, address]);

    const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
    useEffect(() => {
        const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
        return () => clearInterval(t);
    }, []);

    // Pending beacon -> its committed drand round (countdown + auto-reveal).
    const pendingRequestId = round?.pendingRequestId ?? 0n;
    const [drandRounds, setDrandRounds] = useState<Record<string, bigint>>({});
    useEffect(() => {
        if (!publicClient || pendingRequestId === 0n) return;
        const key = pendingRequestId.toString();
        if (drandRounds[key] !== undefined) return;
        let stop = false;
        (async () => {
            try {
                const req = (await publicClient.readContract({
                    address: PROVIDER_ADDRESS,
                    abi: drandRandomnessProviderAbi,
                    functionName: "requests",
                    args: [pendingRequestId],
                })) as readonly unknown[];
                if (!stop) setDrandRounds((r) => ({...r, [key]: BigInt(req[1] as bigint)}));
            } catch {
                /* transient RPC error — retried on the next poll */
            }
        })();
        return () => {
            stop = true;
        };
    }, [publicClient, pendingRequestId, drandRounds]);

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
    const [copied, setCopied] = useState(false);
    const onInvite = async () => {
        const url = new URL(window.location.href);
        url.searchParams.set("table", table);
        try {
            await navigator.clipboard.writeText(url.toString());
        } catch {
            /* clipboard unavailable — the URL bar already carries the link */
        }
        setCopied(true);
        setTimeout(() => setCopied(false), 1500);
    };
    /** Auto-rebet: rejoin the next round with the same wager (session-only,
     *  off by default; disables itself on any bet error). With 1-click play
     *  this makes group sessions flow hand after hand. */
    const [autoRebet, setAutoRebet] = useState(false);
    const autoBetRound = useRef<bigint>(0n);

    const onBet = () =>
        run("bet", async () => {
            const wager = parseEther(wagerInput || "0");
            const live = (await publicClient!.readContract({
                ...chip,
                functionName: "allowance",
                args: [address!, table],
            })) as bigint;
            const calls: Call[] = [];
            // 2x covers a later double without a second approval popup.
            if (live < wager * 2n) {
                calls.push({...chip, functionName: "approve", args: [table, wager * 2n]});
            }
            calls.push({...tbl, functionName: "placeBet", args: [wager]});
            return writeBatch(calls);
        });

    const [hitTarget, setHitTarget] = useState(17);
    const onAct = (action: number, target: number) =>
        run(`act:${action}`, async () => {
            if (action === ACT.DOUBLE) {
                const wager = myBet?.wager ?? 0n;
                const live = (await publicClient!.readContract({
                    ...chip,
                    functionName: "allowance",
                    args: [address!, table],
                })) as bigint;
                const calls: Call[] = [];
                if (live < wager) {
                    calls.push({...chip, functionName: "approve", args: [table, wager]});
                }
                calls.push({...tbl, functionName: "act", args: [action, 0]});
                return writeBatch(calls);
            }
            return writeTx({...tbl, functionName: "act", args: [action, target]});
        });

    const onDrive = (
        fn: "lockDeal" | "lockActions" | "settle" | "refund" | "withdrawDeferred",
        args: readonly unknown[] = [],
    ) => run(fn, () => writeTx({...tbl, functionName: fn, args}), /InvalidRoundState|BettingStillOpen|ActionsStillOpen/i);

    const onBeacon = () =>
        run(
            "beacon",
            async () => {
                const dr = drandRounds[pendingRequestId.toString()];
                if (!dr) return null;
                const sig = await fetchBeaconSignature(dr);
                return writeTx({
                    address: PROVIDER_ADDRESS,
                    abi: drandRandomnessProviderAbi,
                    functionName: "fulfill",
                    args: [pendingRequestId, sig],
                });
            },
            /AlreadyFulfilled/i,
        );

    // Auto-drive: participants push the shared round forward (the keeper cron is
    // the backstop). Attempts RETRY every few seconds while their condition
    // still holds — a raced or transiently failed attempt must not leave the
    // round stalled until the keeper cron.
    const driveTried = useRef<Map<string, number>>(new Map());
    const iAmIn = myBet !== undefined && myBet.wager > 0n;
    useEffect(() => {
        if (busy || !isConnected || !round || roundId === 0n) return;
        const tryOnce = (step: string, go: () => void) => {
            const key = `${roundId}:${step}`;
            const last = driveTried.current.get(key) ?? 0;
            if (now - last < 4) return; // retry while the condition persists
            driveTried.current.set(key, now);
            go();
        };
        // Beacon reveal: any watcher may submit once the drand round publishes.
        if (pendingRequestId !== 0n) {
            const dr = drandRounds[pendingRequestId.toString()];
            if (dr !== undefined && BigInt(now) >= drandPublishTime(dr)) {
                tryOnce(`beacon:${pendingRequestId}`, () => void onBeacon());
            }
            return;
        }
        if (!iAmIn) return; // spectators don't pay gas; the keeper drives
        if (round.state === RS.BETTING && now >= Number(round.betDeadline) + 2) {
            tryOnce("lockDeal", () => void onDrive("lockDeal"));
        } else if (
            round.state === RS.ACTING
            && (round.actedCount >= round.playerCount || now >= Number(round.actDeadline) + 2)
        ) {
            tryOnce("lockActions", () => void onDrive("lockActions"));
        } else if (round.state === RS.SETTLING) {
            tryOnce("settle", () => void onDrive("settle", [100n]));
        } else if (round.state === RS.CANCELLED && round.cursor < round.playerCount) {
            tryOnce("refund", () => void onDrive("refund", [roundId, 100n]));
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [busy, isConnected, round, roundId, now, pendingRequestId, drandRounds, iAmIn]);

    // Auto-rebet: as soon as a fresh round is joinable (or the old one ended),
    // place the same wager once per round id.
    useEffect(() => {
        if (!autoRebet || !isConnected || busy) return;
        if (error) {
            setAutoRebet(false); // never loop on a failing bet
            return;
        }
        const joinableNow =
            round !== undefined
            && round.state === RS.BETTING
            && now < Number(round.betDeadline) - 2
            && !iAmIn;
        const roundOverNow =
            round === undefined || round.state === RS.DONE || round.state === RS.CANCELLED;
        if ((joinableNow || roundOverNow) && autoBetRound.current !== roundId + (roundOverNow ? 1n : 0n)) {
            autoBetRound.current = roundId + (roundOverNow ? 1n : 0n);
            void onBet();
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [autoRebet, isConnected, busy, error, round, roundId, now, iAmIn]);

    // ------------------------------------------------------------ derived view

    const r = rules as Rules | undefined;
    const state = round?.state ?? RS.NONE;
    const betOpen =
        state === RS.NONE
        || state === RS.DONE
        || state === RS.CANCELLED
        || (state === RS.BETTING && now < Number(round?.betDeadline ?? 0n));
    const sharedCards = round && state >= RS.ACTING ? unpackCards(round.playerCards, 2) : [];
    const dealerCards = round ? unpackCards(round.dealerCards, round.dealerCardCount) : [];
    const sv = handValue(sharedCards);
    const dv = handValue(dealerCards);
    const roundOver = state === RS.DONE || state === RS.CANCELLED;
    const acting = state === RS.ACTING && now < Number(round?.actDeadline ?? 0n);
    const canAct = acting && iAmIn && myBet!.action === ACT.PENDING;
    const drandRound = drandRounds[pendingRequestId.toString()];

    const doubleAllowed = useMemo(() => {
        if (!r || sharedCards.length !== 2) return false;
        if (r.doubleRule === 3) return false;
        if (r.doubleRule === 0) return true;
        const hv = handValue(sharedCards);
        if (hv.soft) return false;
        return r.doubleRule === 1 ? hv.total >= 9 && hv.total <= 11 : hv.total >= 10 && hv.total <= 11;
    }, [r, sharedCards]);

    const hitTargets = useMemo(() => {
        const min = Math.max(sv.total + 1, 12);
        return Array.from({length: 21 - min + 1}, (_, i) => min + i);
    }, [sv.total]);
    useEffect(() => {
        if (hitTargets.length > 0 && !hitTargets.includes(hitTarget)) {
            setHitTarget(hitTargets.includes(17) ? 17 : hitTargets[0]!);
        }
    }, [hitTargets, hitTarget]);

    const statusLine = (() => {
        if (state === RS.NONE || roundOver) return "Next round starts with the first bet.";
        if (state === RS.BETTING) {
            const left = Math.max(0, Number(round!.betDeadline) - now);
            return left > 0
                ? `Betting open — deal locks in ${left}s (${round!.playerCount} player${round!.playerCount === 1 ? "" : "s"} in)`
                : "Betting closed — locking the deal…";
        }
        if (state === RS.DEAL_PENDING) {
            return drandRound !== undefined && BigInt(now) >= drandPublishTime(drandRound)
                ? "Deal beacon published — revealing…"
                : `Shared deal locked to drand round ${drandRound ?? "…"} — ~${drandRound !== undefined ? Math.max(0, Number(drandPublishTime(drandRound)) - now) : "…"}s`;
        }
        if (state === RS.ACTING) {
            const left = Math.max(0, Number(round!.actDeadline) - now);
            return left > 0
                ? `Decisions: ${round!.actedCount}/${round!.playerCount} committed — auto-stand in ${left}s`
                : "Decisions locked — requesting the draw beacon…";
        }
        if (state === RS.DRAW_PENDING) {
            return drandRound !== undefined && BigInt(now) >= drandPublishTime(drandRound)
                ? "Draw beacon published — revealing everyone's cards…"
                : `All cards locked to drand round ${drandRound ?? "…"} — ~${drandRound !== undefined ? Math.max(0, Number(drandPublishTime(drandRound)) - now) : "…"}s`;
        }
        if (state === RS.SETTLING) return "Settling every seat…";
        return "";
    })();

    // ------------------------------------------------------------ render

    return (
        <>
            <div className="panel">
                <div className="row">
                    <div className="hand-title">♾️ {name}</div>
                    <button className="secondary" onClick={onInvite}>
                        {copied ? "✓ link copied" : "🔗 invite a friend"}
                    </button>
                    <span className="status">
                        bankroll {fmt((liquidity as readonly [bigint, bigint, bigint] | undefined)?.[0])}{" "}
                        {symbol} · bets {fmt(minWager as bigint | undefined)}–
                        {fmt(maxWager as bigint | undefined)}
                    </span>
                </div>
                <div className="status" style={{marginTop: 6}}>
                    One table, unlimited seats: every player shares the SAME two starting
                    cards and dealer up-card, then commits their own play (stand · hit to a
                    target · double · surrender) before the draw beacon exists — so nobody,
                    including the house, knows the next card while anyone is deciding. No
                    decision by the deadline simply stands. Two drand beacons per round,
                    however many players join.
                </div>
            </div>

            <div className="panel felt">
                <div className="row">
                    <div className="hand-title">
                        Round #{roundId.toString()}
                        {round && state === RS.BETTING && ` · ${round.playerCount} in`}
                    </div>
                    <span className="status">{statusLine}</span>
                </div>

                {state >= RS.ACTING && !roundOver && (
                    <>
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
                            {dealerCards.length === 1 && <CardView hidden />}
                        </div>
                        <div className="hand-title" style={{marginTop: 8}}>
                            Everyone&apos;s hand
                            {sharedCards.length > 0 && (
                                <TotalBadge total={sv.total} soft={sv.soft} bust={false} />
                            )}
                        </div>
                        <div className="cards">
                            {sharedCards.map((c, j) => (
                                <CardView key={j} card={c} />
                            ))}
                        </div>
                    </>
                )}

                {canAct && (
                    <div className="row" style={{marginTop: 10, gap: 8, flexWrap: "wrap"}}>
                        <button disabled={!!busy} onClick={() => onAct(ACT.STAND, 0)}>
                            {busy === `act:${ACT.STAND}` ? "…" : "Stand"}
                        </button>
                        <span className="row" style={{gap: 4}}>
                            <button disabled={!!busy} onClick={() => onAct(ACT.HIT, hitTarget)}>
                                {busy === `act:${ACT.HIT}` ? "…" : "Hit to"}
                            </button>
                            <select
                                value={hitTarget}
                                onChange={(e) => setHitTarget(Number(e.target.value))}
                                aria-label="hit until total reaches"
                            >
                                {hitTargets.map((t) => (
                                    <option key={t} value={t}>
                                        {t}
                                    </option>
                                ))}
                            </select>
                        </span>
                        {doubleAllowed && (
                            <button disabled={!!busy} onClick={() => onAct(ACT.DOUBLE, 0)}>
                                {busy === `act:${ACT.DOUBLE}` ? "…" : "Double"}
                            </button>
                        )}
                        {r?.lateSurrender && (
                            <button
                                className="secondary"
                                disabled={!!busy}
                                onClick={() => onAct(ACT.SURRENDER, 0)}
                            >
                                {busy === `act:${ACT.SURRENDER}` ? "…" : "Surrender"}
                            </button>
                        )}
                    </div>
                )}
                {acting && iAmIn && myBet!.action !== ACT.PENDING && (
                    <div className="status" style={{marginTop: 8}}>
                        ✅ You committed: {ACTION_LABEL[myBet!.action]}
                        {myBet!.action === ACT.HIT ? ` ${myBet!.hitTarget}` : ""} — waiting for
                        the others.
                    </div>
                )}

                {players.length > 0 && (
                    <div style={{marginTop: 10}}>
                        <div className="hand-title">Seats</div>
                        {players.map((p, i) => {
                            const b = betsData?.[i]?.result as Bet | undefined;
                            const me = address && p.toLowerCase() === address.toLowerCase();
                            const cards =
                                b && b.settled && b.cardCount > 0
                                    ? unpackCards(b.cards, b.cardCount)
                                    : [];
                            const cv = handValue(cards);
                            return (
                                <div className="row" key={p} style={{marginTop: 4}}>
                                    <span className="status">
                                        {me ? "⭐ you" : seatName(p, i)} ·{" "}
                                        {fmt(b?.wager)} {symbol}
                                        {b && b.action === ACT.DOUBLE ? " (doubled)" : ""}
                                        {state === RS.ACTING
                                            ? b && b.action !== ACT.PENDING
                                                ? " · ✅ committed"
                                                : " · deciding…"
                                            : ""}
                                        {b && b.settled && b.outcome !== 0
                                            ? ` · ${(OutcomeNames[b.outcome] ?? "?").replaceAll("_", " ")}${b.payout > 0n ? ` +${fmt(b.payout)}` : ""}`
                                            : ""}
                                    </span>
                                    {cards.length > 0 && (
                                        <span className="status">
                                            {cards.length}× cards, total {cv.total}
                                            {cv.total > 21 ? " (bust)" : ""}
                                        </span>
                                    )}
                                </div>
                            );
                        })}
                    </div>
                )}

                {iAmIn && myBet!.settled && myBet!.outcome !== 0 && (
                    <div
                        className={`result ${
                            myBet!.outcome === 1 || myBet!.outcome === 2
                                ? "win"
                                : myBet!.outcome === 3 || myBet!.outcome === 7
                                  ? "push"
                                  : "lose"
                        }`}
                        style={{marginTop: 10}}
                    >
                        {(OutcomeNames[myBet!.outcome] ?? "?").replaceAll("_", " ")}
                        {myBet!.payout > 0n ? ` — paid ${fmt(myBet!.payout)} ${symbol}` : ""}
                    </div>
                )}

                {isConnected && betOpen && !(state === RS.BETTING && iAmIn) && (
                    <div className="row" style={{marginTop: 10}}>
                        <span className="status">
                            {state === RS.BETTING
                                ? "Join this round:"
                                : "Open the next round with your bet:"}
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
                {isConnected && state === RS.BETTING && iAmIn && (
                    <div className="status" style={{marginTop: 8}}>
                        🎟️ You&apos;re in with {fmt(myBet!.wager)} {symbol} — waiting for the
                        window to close.
                    </div>
                )}
                {isConnected && (
                    <label className="status row" style={{marginTop: 8, gap: 6, cursor: "pointer"}}>
                        <input
                            type="checkbox"
                            checked={autoRebet}
                            onChange={(e) => setAutoRebet(e.target.checked)}
                        />
                        🔁 auto-rebet {wagerInput || "…"} {symbol} each round (keeps your seat at
                        the table; turns itself off if a bet fails)
                    </label>
                )}

                {pendingRequestId !== 0n
                    && drandRound !== undefined
                    && BigInt(now) >= drandPublishTime(drandRound)
                    && error && (
                        <button className="pulse" disabled={!!busy} onClick={() => void onBeacon()}>
                            Submit beacon
                        </button>
                    )}
                {((deferred as bigint | undefined) ?? 0n) > 0n && (
                    <div className="row" style={{marginTop: 8}}>
                        <span className="status">
                            A payout of {fmt(deferred as bigint)} {symbol} is parked for you.
                        </span>
                        <button disabled={!!busy} onClick={() => onDrive("withdrawDeferred")}>
                            Withdraw
                        </button>
                    </div>
                )}
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
