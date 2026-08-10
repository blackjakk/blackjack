"use client";

import {useEffect, useMemo, useState} from "react";
import {useReadContract, useReadContracts} from "wagmi";
import type {Address} from "viem";
import {tableFactoryAbi, blackjackTableV2Abi} from "@blackjack/config";
import {
    FACTORY_ADDRESS,
    V2_TABLES,
    V3_TABLES,
    ASSET_TABLES,
    INFINITE_TABLES,
    hasV2,
} from "../lib/config.ts";
import {fmt} from "./ui.tsx";
import type {LiveRound} from "./live.tsx";

const POLL = {refetchInterval: 5000} as const;

export type TableChoice = "v1" | Address;

type Rules = {
    dealerHitsSoft17: boolean;
    blackjackNum: number;
    blackjackDen: number;
    doubleRule: number;
    lateSurrender: boolean;
};

const DOUBLE_LABEL = ["double any 2", "double 9–11", "double 10–11", "no double"] as const;

export function rulesSummary(r: Rules): string {
    return [
        r.dealerHitsSoft17 ? "dealer hits soft 17" : "dealer stands on 17",
        `blackjack pays ${r.blackjackNum}:${r.blackjackDen}`,
        DOUBLE_LABEL[r.doubleRule] ?? "?",
        r.lateSurrender ? "surrender" : null,
    ]
        .filter(Boolean)
        .join(" · ");
}

/** Table picker: curated launch tables + community tables from the open
 *  registry, filtered to one asset family at a time (the asset dropdown above
 *  the lobby switches families). */
export function Lobby({
    selected,
    onSelect,
    live = [],
    asset = "CHIP",
}: {
    selected: TableChoice;
    onSelect: (t: TableChoice) => void;
    live?: LiveRound[];
    /** Asset family to show ("CHIP" | "USDm" | "ETH" | "MEGA"). */
    asset?: string;
}) {
    const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
    useEffect(() => {
        const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
        return () => clearInterval(t);
    }, []);
    const liveFor = (addr: string) =>
        live.find((r) => r.table.toLowerCase() === addr.toLowerCase());
    const {data: registry} = useReadContract({
        address: FACTORY_ADDRESS,
        abi: tableFactoryAbi,
        functionName: "allTables",
        query: {...POLL, enabled: hasV2},
    });

    const tables = useMemo(() => {
        const curated = [
            ...INFINITE_TABLES.map((t) => ({
                name: `♾️ ${t.symbol} Infinite — shared table`,
                address: t.address,
                symbol: t.symbol,
                community: false,
            })),
            ...V2_TABLES.map((t) => ({...t, symbol: "CHIP", community: false})),
            ...V3_TABLES.map((t) => ({...t, symbol: "CHIP", community: false})),
            ...ASSET_TABLES.map((t) => ({
                name: `${t.symbol} Classic (S17, 3:2, surrender)`,
                address: t.table,
                symbol: t.symbol,
                community: false,
            })),
        ];
        const known = new Set(curated.map((t) => t.address.toLowerCase()));
        const extras = ((registry as readonly Address[] | undefined) ?? [])
            .filter((a) => !known.has(a.toLowerCase()))
            .map((a) => ({
                name: `Community ${a.slice(0, 6)}…${a.slice(-4)}`,
                address: a,
                symbol: "CHIP",
                community: true,
            }));
        return [...curated, ...extras];
    }, [registry]);

    const {data: infos} = useReadContracts({
        contracts: tables.flatMap((t) => [
            {address: t.address, abi: blackjackTableV2Abi, functionName: "rules"} as const,
            {address: t.address, abi: blackjackTableV2Abi, functionName: "liquidity"} as const,
            {address: t.address, abi: blackjackTableV2Abi, functionName: "minWager"} as const,
            {address: t.address, abi: blackjackTableV2Abi, functionName: "maxWager"} as const,
        ]),
        query: {...POLL, enabled: tables.length > 0},
    });

    if (!hasV2) return null;

    return (
        <div className="panel">
            <div className="hand-title">{asset} tables</div>
            <div className="lobby">
                {asset === "CHIP" && (
                    <button
                        className={`table-card${selected === "v1" ? " active-table" : ""}`}
                        onClick={() => onSelect("v1")}
                    >
                        <strong>Original (v1)</strong>
                        <span className="sub">
                            dealer stands on 17 · blackjack pays 3:2 · double any 2 · single hand
                        </span>
                    </button>
                )}
                {tables.map((t, i) => {
                    if (t.symbol !== asset) return null;
                    const rules = infos?.[i * 4]?.result as Rules | undefined;
                    const liq = infos?.[i * 4 + 1]?.result as
                        | readonly [bigint, bigint, bigint]
                        | undefined;
                    const min = infos?.[i * 4 + 2]?.result as bigint | undefined;
                    const max = infos?.[i * 4 + 3]?.result as bigint | undefined;
                    return (
                        <button
                            key={t.address}
                            className={`table-card${selected === t.address ? " active-table" : ""}`}
                            onClick={() => onSelect(t.address)}
                        >
                            <strong>
                                {t.name}
                                {t.community ? " ⚠️" : ""}
                            </strong>
                            <span className="sub">{rules ? rulesSummary(rules) : "…"}</span>
                            {(() => {
                                const lr = liveFor(t.address);
                                if (!lr) return null;
                                if (lr.state === 1 && lr.betDeadline > now) {
                                    return (
                                        <span className="sub live-open">
                                            🔴 round filling — {lr.playerCount} in ·{" "}
                                            {lr.betDeadline - now}s to join
                                        </span>
                                    );
                                }
                                if (lr.state >= 2 && lr.state <= 5) {
                                    return (
                                        <span className="sub">
                                            🟢 round in play ({lr.playerCount}) — next one soon
                                        </span>
                                    );
                                }
                                return null;
                            })()}
                            <span className="sub">
                                bets {fmt(min)}–{fmt(max)} · bankroll {fmt(liq?.[0])} {t.symbol}
                                {liq !== undefined && liq[0] === 0n
                                    ? " · 🏦 empty — be the first LP!"
                                    : ""}
                                {t.community ? " · unvetted community table" : ""}
                            </span>
                        </button>
                    );
                })}
            </div>
            <div className="status" style={{marginTop: 8}}>
                Anyone can create a table (and fund any table&apos;s bankroll) through the
                onchain TableFactory — community tables use the same verified code with
                their creator&apos;s rule choices, but play at curated tables if unsure.
            </div>
        </div>
    );
}
