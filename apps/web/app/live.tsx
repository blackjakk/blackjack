"use client";

import {useMemo} from "react";
import {useReadContracts} from "wagmi";
import type {Address} from "viem";
import {infiniteBlackjackAbi} from "@blackjack/config";
import {INFINITE_TABLES} from "../lib/config.ts";

const POLL = {refetchInterval: 3000} as const;

export interface LiveRound {
    table: Address;
    symbol: string;
    state: number; // RoundState enum
    betDeadline: number;
    actDeadline: number;
    playerCount: number;
}

/**
 * Site-wide pulse of every Infinite table's current round, so "a round is
 * filling RIGHT NOW" is visible from anywhere in the app — the glue that lets
 * people actually find each other. Derived purely from chain state.
 */
export function useLiveRounds(): LiveRound[] {
    const {data: ids} = useReadContracts({
        contracts: INFINITE_TABLES.map(
            (t) =>
                ({
                    address: t.address,
                    abi: infiniteBlackjackAbi,
                    functionName: "currentRoundId",
                }) as const,
        ),
        query: {...POLL, enabled: INFINITE_TABLES.length > 0},
    });
    const roundIds = useMemo(
        () => INFINITE_TABLES.map((_, i) => (ids?.[i]?.result as bigint | undefined) ?? 0n),
        [ids],
    );
    const {data: rounds} = useReadContracts({
        contracts: INFINITE_TABLES.map(
            (t, i) =>
                ({
                    address: t.address,
                    abi: infiniteBlackjackAbi,
                    functionName: "getRound",
                    args: [roundIds[i] ?? 0n],
                }) as const,
        ),
        query: {...POLL, enabled: roundIds.some((id) => id > 0n)},
    });

    return useMemo(() => {
        const out: LiveRound[] = [];
        INFINITE_TABLES.forEach((t, i) => {
            if ((roundIds[i] ?? 0n) === 0n) return;
            const r = rounds?.[i]?.result as
                | {state: number; betDeadline: bigint; actDeadline: bigint; playerCount: number}
                | undefined;
            if (!r) return;
            out.push({
                table: t.address,
                symbol: t.symbol,
                state: Number(r.state),
                betDeadline: Number(r.betDeadline),
                actDeadline: Number(r.actDeadline),
                playerCount: Number(r.playerCount),
            });
        });
        return out;
    }, [roundIds, rounds]);
}

/** The single most joinable round right now (open betting, most time left). */
export function joinableRound(live: LiveRound[], now: number): LiveRound | undefined {
    return live
        .filter((r) => r.state === 1 /* BETTING */ && r.betDeadline - now > 3)
        .sort((a, b) => b.betDeadline - a.betDeadline)[0];
}
