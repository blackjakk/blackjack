"use client";

import {useEffect, useRef, useState} from "react";
import {useReadContracts} from "wagmi";
import type {Address} from "viem";
import {
    presenceAbi,
    tableChatAbi,
    blackjackTableV2Abi,
    infiniteBlackjackAbi,
    DEPLOYMENTS,
    megaethTestnet,
} from "@blackjack/config";
import {
    PRESENCE_ADDRESS,
    TABLE_ADDRESS,
    V2_TABLES,
    V3_TABLES,
    ASSET_TABLES,
    INFINITE_TABLES,
} from "../lib/config.ts";
import {burnerClients, burnerWrite} from "../lib/burner.ts";
import {tickerTableName} from "./ticker.tsx";
import type {TableChoice} from "./lobby.tsx";

const CHAT_ADDRESS = (DEPLOYMENTS[megaethTestnet.id]?.chat ?? "") as Address;
const ZERO = "0x0000000000000000000000000000000000000000";
const PING_EVERY = 60; // seconds between own pings
const ONLINE_WINDOW = 150; // pinged within this = online
const ACTIVITY_WINDOW = 300; // bet within this = present even without a funded burner

export interface OnlineUser {
    key: string; // burner (ping sender) — the chat identity
    account: Address | null; // main wallet, when connected
    table: Address | null; // where they are (null = browsing / in chat)
    lastSeen: number;
}

/**
 * Who's online: every open tab pings the ownerless Presence beacon from its
 * gasless chat burner key (once funded for chat, presence rides along free of
 * popups); the roster derives from recent Ping events, so every client sees
 * the same list and nobody can be quietly hidden.
 */
export function usePresence(tableChoice: TableChoice, mainWallet: Address | undefined): OnlineUser[] {
    const [roster, setRoster] = useState<OnlineUser[]>([]);
    const seenAt = useRef<Map<string, OnlineUser>>(new Map());
    const lastBlock = useRef<bigint>(0n);
    const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
    useEffect(() => {
        const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 5000);
        return () => clearInterval(t);
    }, []);

    // ---- own heartbeat: ping where we are (needs a funded chat burner; a dry
    // burner just means we watch silently until the user funds chat).
    const tableRef = useRef<TableChoice>(tableChoice);
    tableRef.current = tableChoice;
    const walletRef = useRef<Address | undefined>(mainWallet);
    walletRef.current = mainWallet;
    useEffect(() => {
        if (!PRESENCE_ADDRESS) return;
        let stopped = false;
        const beat = async () => {
            if (stopped) return;
            try {
                const {pub, account} = burnerClients();
                const bal = await pub.getBalance({address: account.address as Address});
                if (bal === 0n) return;
                const t = tableRef.current;
                await burnerWrite({
                    address: PRESENCE_ADDRESS,
                    abi: presenceAbi,
                    functionName: "ping",
                    args: [walletRef.current ?? ZERO, t === "v1" || !t ? ZERO : t],
                });
            } catch {
                /* cooldown/gas hiccup — next beat retries */
            }
        };
        void beat();
        const t = setInterval(() => void beat(), PING_EVERY * 1000);
        return () => {
            stopped = true;
            clearInterval(t);
        };
    }, []);

    // ---- roster: recent Ping events (start ~ONLINE_WINDOW ago, then tail).
    useEffect(() => {
        if (!PRESENCE_ADDRESS) return;
        const {pub} = burnerClients();
        let stopped = false;
        const scan = async () => {
            try {
                const latest = await pub.getBlockNumber();
                const from =
                    lastBlock.current > 0n
                        ? lastBlock.current + 1n
                        : latest > 400n
                          ? latest - 400n // ~ the online window at ~1s blocks
                          : 0n;
                if (from > latest) return;
                lastBlock.current = latest;
                const perHand = [
                    TABLE_ADDRESS,
                    ...V2_TABLES.map((t) => t.address),
                    ...V3_TABLES.map((t) => t.address),
                    ...ASSET_TABLES.map((t) => t.table),
                ];
                const [logs, bets, games] = await Promise.all([
                    pub.getContractEvents({
                        address: PRESENCE_ADDRESS,
                        abi: presenceAbi,
                        eventName: "Ping",
                        fromBlock: from,
                        toBlock: latest,
                    }),
                    pub.getContractEvents({
                        address: INFINITE_TABLES.map((t) => t.address),
                        abi: infiniteBlackjackAbi,
                        eventName: "BetPlaced",
                        fromBlock: from,
                        toBlock: latest,
                    }),
                    pub.getContractEvents({
                        address: perHand,
                        abi: blackjackTableV2Abi,
                        eventName: "GameCreated",
                        fromBlock: from,
                        toBlock: latest,
                    }),
                ]);
                if (stopped) return;
                const stamp = Math.floor(Date.now() / 1000);
                for (const log of logs) {
                    const a = log.args as {sender?: Address; account?: Address; table?: Address};
                    if (!a.sender) continue;
                    seenAt.current.set(a.sender.toLowerCase(), {
                        key: a.sender.toLowerCase(),
                        account: a.account && a.account !== ZERO ? a.account : null,
                        table: a.table && a.table !== ZERO ? a.table : null,
                        lastSeen: stamp,
                    });
                }
                // Anyone actively betting is present at that table even without
                // a funded chat burner (keyed separately, deduped at render).
                for (const log of [...bets, ...games] as {args: unknown; address: string}[]) {
                    const a = log.args as {player?: Address};
                    if (!a.player) continue;
                    seenAt.current.set(`act:${a.player.toLowerCase()}`, {
                        key: `act:${a.player.toLowerCase()}`,
                        account: a.player,
                        table: log.address as Address,
                        lastSeen: stamp,
                    });
                }
            } catch {
                /* transient RPC failure — next poll retries */
            }
        };
        void scan();
        const t = setInterval(() => void scan(), 8000);
        return () => {
            stopped = true;
            clearInterval(t);
        };
    }, []);

    useEffect(() => {
        const all = [...seenAt.current.values()];
        const pingedAccounts = new Set(
            all
                .filter((u) => !u.key.startsWith("act:") && u.account)
                .map((u) => (u.account as string).toLowerCase()),
        );
        setRoster(
            all
                .filter((u) =>
                    u.key.startsWith("act:")
                        ? now - u.lastSeen < ACTIVITY_WINDOW
                          && !pingedAccounts.has((u.account as string).toLowerCase())
                        : now - u.lastSeen < ONLINE_WINDOW,
                )
                .sort((a, b) => b.lastSeen - a.lastSeen),
        );
    }, [now]);

    return roster;
}

/** Roster panel: online count + who's where + one-click join. */
export function PresencePanel({
    tableChoice,
    onSelect,
    mainWallet,
}: {
    tableChoice: TableChoice;
    onSelect: (t: TableChoice) => void;
    mainWallet: Address | undefined;
}) {
    const roster = usePresence(tableChoice, mainWallet);
    const [open, setOpen] = useState(false);

    const {data: nickData} = useReadContracts({
        contracts: roster.map(
            (u) =>
                ({
                    address: CHAT_ADDRESS,
                    abi: tableChatAbi,
                    functionName: "nicknameOf",
                    args: [u.key.startsWith("act:") ? (u.account as Address) : (u.key as Address)],
                }) as const,
        ),
        query: {refetchInterval: 60_000, enabled: roster.length > 0 && CHAT_ADDRESS.length === 42},
    });
    const nameOf = (u: OnlineUser, i: number) => {
        const nick = nickData?.[i]?.result as string | undefined;
        if (nick && nick.length > 0) return nick;
        const a = u.account ?? u.key;
        return `${a.slice(0, 6)}…${a.slice(-4)}`;
    };

    const [myBurner, setMyBurner] = useState("");
    useEffect(() => {
        // burnerClients touches localStorage — client only, never during prerender.
        setMyBurner((burnerClients().account.address as string).toLowerCase());
    }, []);

    if (!PRESENCE_ADDRESS) return null;
    return (
        <div className="panel">
            <button className="row presence-head" onClick={() => setOpen((o) => !o)}>
                <span className="hand-title">
                    🟢 {roster.length} online
                    {roster.length === 0 ? " — fund chat once and you'll appear here too" : ""}
                </span>
                <span className="status">{open ? "hide ▲" : "who's here ▼"}</span>
            </button>
            {open && roster.length > 0 && (
                <div style={{marginTop: 6}}>
                    {roster.map((u, i) => {
                        const here =
                            u.table !== null
                            && tableChoice !== "v1"
                            && (tableChoice as string).toLowerCase() === u.table.toLowerCase();
                        return (
                            <div className="row" key={u.key} style={{marginTop: 4}}>
                                <span className="status">
                                    {u.key === myBurner ? "⭐ " : ""}
                                    <strong>{nameOf(u, i)}</strong>{" "}
                                    {u.table ? `at ${tickerTableName(u.table)}` : "in the lobby/chat"}
                                </span>
                                {u.table !== null && !here && u.key !== myBurner && (
                                    <button onClick={() => onSelect(u.table as TableChoice)}>
                                        Join →
                                    </button>
                                )}
                                {here && u.key !== myBurner && (
                                    <span className="status">at your table 🎉</span>
                                )}
                            </div>
                        );
                    })}
                </div>
            )}
        </div>
    );
}
