"use client";

import {useCallback, useEffect, useMemo, useRef, useState} from "react";
import {
    useAccount,
    useBalance,
    useConnect,
    useDisconnect,
    usePublicClient,
    useReadContract,
    useReadContracts,
    useSwitchChain,
    useWatchContractEvent,
    useWriteContract,
} from "wagmi";
import {useQueryClient} from "@tanstack/react-query";
import {formatEther, parseEther} from "viem";
import {
    blackjackTableAbi,
    testChipAbi,
    drandRandomnessProviderAbi,
    mockRandomnessProviderAbi,
} from "@blackjack/config";
import {
    unpackCards,
    handValue,
    GameState,
    Outcome,
    OutcomeNames,
    fetchBeaconSignature,
    type Card,
} from "@blackjack/sdk";
import {drandPublishTime} from "@blackjack/config";
import {Chat} from "./chat.tsx";
import {CardView, TotalBadge, fmt} from "./ui.tsx";
import {Lobby, type TableChoice} from "./lobby.tsx";
import {useLiveRounds, joinableRound} from "./live.tsx";
import {PresencePanel} from "./presence.tsx";
import {V2Table} from "./v2table.tsx";
import {InfiniteTable} from "./infinite.tsx";
import {StatsPanel} from "./stats.tsx";
import {tickerTableName} from "./ticker.tsx";
import {
    TABLE_ADDRESS,
    CHIP_ADDRESS,
    PROVIDER_ADDRESS,
    PROVIDER_KIND,
    GAS_FAUCET_URL,
    activeChain,
    isConfigured,
    txUrl,
    BUILD_ID,
    V2_TABLES,
    V3_TABLES,
    ASSET_TABLES,
    VAULTS,
    tableToken,
    isV3Table,
    isInfiniteTable,
    INFINITE_TABLES,
    hasV2,
    ASSETS,
    assetOfTable,
    defaultTableForAsset,
    defaultWager,
} from "../lib/config.ts";

const POLL = {refetchInterval: 1500} as const;

/** How MOSS "Smart Approvals" session grants are scoped for 1-click play. */
const ONE_CLICK_HOURS = 24;
const ONE_CLICK_CHIP_PER_DAY = "5000";
const ONE_CLICK_GAS_PER_DAY = "0.01";
/** Daily silent-spend cap per wager token (18-dec units as strings). Sized for
 *  a real session — roughly 200+ default-size bets — because a hit cap doesn't
 *  pause 1-click, it turns EVERY remaining bet that day into a popup. The old
 *  ETH cap (0.02 ≈ ten 0.002 bets) did exactly that. */
const ONE_CLICK_SPEND_PER_DAY: Record<string, string> = {
    CHIP: ONE_CLICK_CHIP_PER_DAY,
    USDm: "1000",
    MEGA: "1000",
    ETH: "0.2",
};

type MossProvider = {
    request: (args: {method: string; params?: unknown}) => Promise<unknown>;
};
type MossTxResult = {
    status: "approved" | "cancelled" | "error";
    error?: string;
    receipt?: {transactionHash: `0x${string}`};
};



/** Solc ABIs carry `internalType` ("enum InfiniteBlackjack.Action") alongside the
 * canonical `type` ("uint8"). MOSS's policy engine matches silent calls against
 * granted canonical signatures like `act(uint8,uint8)`; a signature derived from
 * internalType can never match one, which downgrades a covered call to a surprise
 * approval popup. Hand the wallet an internalType-free ABI so the computed
 * signature is always canonical. */
const mossAbi = (abi: unknown): unknown =>
    JSON.parse(JSON.stringify(abi), (key, value: unknown) =>
        key === "internalType" ? undefined : value,
    );

/** Canonical form of a granted call for set-comparison: lowercase, no
 *  whitespace. Requested plans and wallet_getPermissions reports are both run
 *  through this so a formatting difference can never read as a coverage gap. */
const normCall = (to: string, signature: string): string =>
    `${to}:${signature}`.toLowerCase().replace(/\s+/g, "");

/** Human label for a 1-click grant target address (token, provider or table). */
function grantTargetLabel(addr: string): string {
    const a = addr.toLowerCase();
    if (a === CHIP_ADDRESS.toLowerCase()) return "CHIP";
    if (a === PROVIDER_ADDRESS.toLowerCase()) return "beacon provider";
    const asset = ASSET_TABLES.find((t) => t.token.toLowerCase() === a);
    if (asset) return asset.symbol === "ETH" ? "WETH" : asset.symbol;
    return tickerTableName(addr);
}

const MOSS_BOOT_FAILURE = /did not respond|Failed to establish a connection to the MegaETH wallet/i;

/** Translate known wallet errors into something actionable. */
function friendlyError(msg: string): string {
    if (msg.includes("0xfb8f41b2")) {
        return (
            "The table wasn't approved to take the chips (the wallet auto-revokes " +
            "standalone approvals). Just retry — approval and bet now go through " +
            "together in one step."
        );
    }
    if (MOSS_BOOT_FAILURE.test(msg)) {
        const firefox = typeof navigator !== "undefined" && navigator.userAgent.includes("Firefox");
        const clearPath = firefox
            ? "click the shield icon in the address bar → Clear cookies and site data"
            : "click the lock icon in the address bar → Cookies and site data → Delete data used by this site";
        return (
            "The MOSS wallet failed to load (already retried automatically). This is " +
            `usually a stale wallet session — ${clearPath}, then reload and reconnect ` +
            "with your passkey (you'll need to re-enable 1-click play). Extension " +
            "wallets like MetaMask keep working in the meantime."
        );
    }
    return msg;
}

/**
 * MOSS boot failures are often transient (handshake timeout on a cold cache);
 * the SDK fully resets on failure, so one delayed retry converts most of them
 * into successes before the user ever sees an error.
 */
async function withMossRetry<T>(fn: () => Promise<T>): Promise<T> {
    try {
        return await fn();
    } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (!MOSS_BOOT_FAILURE.test(msg)) throw err;
        await new Promise((r) => setTimeout(r, 2500));
        return fn();
    }
}

export default function Page() {
    const {address, isConnected, chainId: walletChainId, connector: activeConnector} = useAccount();
    const {connectAsync, connectors} = useConnect();
    const {disconnect} = useDisconnect();
    const [pickerBusy, setPickerBusy] = useState(false);
    const [pickerError, setPickerError] = useState<string | null>(null);
    const clickWallet = async (connector: (typeof connectors)[number]) => {
        setPickerBusy(true);
        setPickerError(null);
        try {
            await withMossRetry(() => connectAsync({connector}));
        } catch (err) {
            setPickerError(
                friendlyError(err instanceof Error ? err.message.split("\n")[0]! : String(err)),
            );
        } finally {
            setPickerBusy(false);
        }
    };
    const {switchChain, isPending: switching} = useSwitchChain();
    const publicClient = usePublicClient();
    const queryClient = useQueryClient();
    const {writeContractAsync} = useWriteContract();

    // wagmi can rehydrate a persisted session into a connector "shell" without
    // methods (seen with MOSS when its hosted iframe re-authorizes slowly after
    // a reload); the first write then dies with "connector.getChainId is not a
    // function". Always hand writes the live connector instance from the config,
    // and drop the session if the stored connector no longer exists at all.
    const liveConnector = useMemo(
        () => connectors.find((c) => c.id === activeConnector?.id),
        [connectors, activeConnector],
    );
    const connectorIsShell =
        !!activeConnector &&
        typeof (activeConnector as {getChainId?: unknown}).getChainId !== "function";
    useEffect(() => {
        if (isConnected && connectorIsShell && !liveConnector) disconnect();
    }, [isConnected, connectorIsShell, liveConnector, disconnect]);

    // ------------------------------------------------- MOSS 1-click play
    // A Smart Approvals session grant (one passkey approval) lets game calls run
    // silently: scoped to this table's contracts, capped per day, 24h expiry.
    const isMoss = liveConnector?.id === "mossWallet";
    const oneClickKey = `moss-oneclick:${address ?? ""}`;
    type GrantRecord = {
        expiry: number;
        targets: string[];
        /** normalized "to:signature" pairs granted (union of what the approval
         *  sheet approved and what wallet_getPermissions reports; may be absent
         *  on old caches until the next refresh) */
        calls?: string[];
        /** unix seconds of the in-app approval that produced this record —
         *  absent when the record came purely from a wallet report */
        grantedAt?: number;
    };
    const [oneClickGrant, setOneClickGrant] = useState<GrantRecord | null>(null);
    const readCachedGrant = useCallback((): GrantRecord | null => {
        const raw = localStorage.getItem(oneClickKey);
        if (!raw) return null;
        try {
            const p = JSON.parse(raw) as Partial<GrantRecord>;
            if (p && typeof p.expiry === "number") {
                return {
                    expiry: p.expiry,
                    targets: (p.targets ?? []).map((t) => t.toLowerCase()),
                    calls: p.calls,
                    grantedAt: p.grantedAt,
                };
            }
        } catch {
            /* old format: bare expiry number covering only the v1 contracts */
        }
        const n = Number(raw);
        return n > 0
            ? {
                  expiry: n,
                  targets: [CHIP_ADDRESS, PROVIDER_ADDRESS, TABLE_ADDRESS].map((a) =>
                      a.toLowerCase(),
                  ),
              }
            : null;
    }, [oneClickKey]);

    /** Reconcile the local grant record with wallet_getPermissions. The wallet
     *  is the long-run source of truth (approvals can happen out-of-band), but
     *  its report can LAG a passkey approval that just happened in this tab —
     *  briefly returning the previous grant, or none at all. Overwriting the
     *  fresh record with that stale report is what looped the re-approve
     *  banner, so: reports older than the record are ignored (every new grant
     *  has a strictly later expiry), a report of the SAME grant merges as a
     *  union with what the approval sheet approved, and a "no grant" report
     *  within minutes of an in-app approval is treated as the same lag. */
    const refreshGrant = useCallback(async () => {
        if (!isMoss || !address || !liveConnector) return;
        try {
            const provider = (await liveConnector.getProvider()) as MossProvider;
            const res = (await provider.request({method: "wallet_getPermissions"})) as
                | {
                      permissions?: {
                          expiry: number;
                          permissions: {calls: {to: string; signature: string}[]};
                      } | null;
                  }
                | undefined;
            const p = res?.permissions;
            const cached = readCachedGrant();
            if (p && p.expiry > Date.now() / 1000 + 60 && p.permissions?.calls?.length) {
                const reported = p.permissions.calls.map((c) => normCall(c.to, c.signature));
                console.info("[1-click] wallet reports grant:", p.expiry, reported);
                if (cached && cached.expiry > p.expiry + 5) return; // stale report
                const sameGrant = cached !== null && Math.abs(cached.expiry - p.expiry) <= 5;
                const calls = Array.from(
                    new Set([...reported, ...(sameGrant ? (cached.calls ?? []) : [])]),
                );
                const targets = Array.from(
                    new Set([
                        ...calls.map((c) => c.split(":")[0]!),
                        ...(sameGrant ? cached.targets : []),
                    ]),
                );
                const grant: GrantRecord = {
                    expiry: p.expiry,
                    targets,
                    calls,
                    ...(sameGrant && cached.grantedAt ? {grantedAt: cached.grantedAt} : {}),
                };
                localStorage.setItem(oneClickKey, JSON.stringify(grant));
                setOneClickGrant(grant);
            } else if (p === null || p === undefined) {
                const justApproved =
                    cached?.grantedAt !== undefined
                    && Date.now() / 1000 - cached.grantedAt < 180;
                if (justApproved) return; // wallet cache lag, not a revoke
                // No active grant wallet-side; drop any stale cache.
                localStorage.removeItem(oneClickKey);
                setOneClickGrant(null);
            }
        } catch {
            /* wallet unreachable — keep whatever the cache said */
        }
    }, [isMoss, address, liveConnector, oneClickKey, readCachedGrant]);

    useEffect(() => {
        if (!isMoss || !address) return setOneClickGrant(null);
        setOneClickGrant(readCachedGrant());
        void refreshGrant();
    }, [isMoss, address, readCachedGrant, refreshGrant]);
    /** Why the last silent (1-click) call fell back to a wallet popup — surfaced
     *  in the 1-click panel so coverage gaps are debuggable instead of mysterious. */
    const [silentIssue, setSilentIssue] = useState<string | null>(null);

    const oneClickExpiry = oneClickGrant?.expiry ?? 0;
    const oneClickActive = isMoss && oneClickExpiry > Date.now() / 1000 + 60;
    const grantCovers = useCallback(
        (target: string) =>
            oneClickActive && (oneClickGrant?.targets.includes(target.toLowerCase()) ?? false),
        [oneClickActive, oneClickGrant],
    );


    const writeTx = useCallback(
        async (args: Parameters<typeof writeContractAsync>[0]) => {
            if (oneClickActive && liveConnector && grantCovers(args.address as string)) {
                // Silent path: wallet_callContract with silent:true uses the session
                // grant. Deliberately NO silentUIApproveFallback — with it, a declined
                // silent call opens the wallet's own sheet and the decline REASON is
                // lost. Without it the wallet returns status:"error" with a human-
                // readable reason (missing permission, spend cap, …), which we surface
                // in the panel, then fall back to a normal approval popup ourselves.
                try {
                return await withMossRetry(async () => {
                    const provider = (await liveConnector.getProvider()) as MossProvider;
                    const result = (await provider.request({
                        method: "wallet_callContract",
                        params: [
                            {
                                address: args.address,
                                abi: mossAbi(args.abi),
                                functionName: args.functionName,
                                args: args.args ?? [],
                                silent: true,
                            },
                        ],
                    })) as MossTxResult;
                    if (result.status !== "approved" || !result.receipt?.transactionHash) {
                        throw new Error(result.error ?? `wallet ${result.status ?? "error"}`);
                    }
                    return result.receipt.transactionHash;
                });
                } catch (err) {
                    // A silent call the wallet won't run (missing/changed permission,
                    // spend cap, policy edge) degrades to a normal approval popup
                    // instead of a dead-end error. No UI was shown yet, so there is
                    // no user cancel to honor here.
                    const m = err instanceof Error ? err.message : String(err);
                    console.warn("[1-click] silent call fell back to popup:", m);
                    setSilentIssue(`${args.functionName}: ${m.split("\n")[0]!.slice(0, 160)}`);
                    void refreshGrant();
                }
            }
            const doWrite = () =>
                writeContractAsync(
                    liveConnector ? ({...args, connector: liveConnector} as typeof args) : args,
                );
            return liveConnector?.id === "mossWallet" ? withMossRetry(doWrite) : doWrite();
        },
        [writeContractAsync, liveConnector, oneClickActive, grantCovers, refreshGrant, setSilentIssue],
    );

    /**
     * Execute several calls as ONE atomic MOSS batch (single approval sheet, no
     * gap between approve and spend — the wallet auto-revokes dangling ERC-20
     * approvals, so approve-then-call as two txs loses the allowance before the
     * second call runs). Non-MOSS wallets execute sequentially.
     */
    const writeBatch = useCallback(
        async (
            calls: {
                address: `0x${string}`;
                abi: unknown;
                functionName: string;
                args?: readonly unknown[];
            }[],
        ): Promise<`0x${string}`> => {
            if (calls.length === 1 && !isMoss) {
                return writeTx(calls[0] as Parameters<typeof writeContractAsync>[0]);
            }
            if (isMoss && liveConnector) {
                const canSilent = oneClickActive && calls.every((c) => grantCovers(c.address));
                const send = async (silent: boolean) => {
                    const provider = (await liveConnector.getProvider()) as MossProvider;
                    const result = (await provider.request({
                        method: "wallet_callContract",
                        params: [
                            calls.map((c) => ({
                                address: c.address,
                                abi: mossAbi(c.abi),
                                functionName: c.functionName,
                                args: c.args ?? [],
                                // No silentUIApproveFallback: a decline must come
                                // back as status:"error" + reason (surfaced in the
                                // panel); we then re-send interactively ourselves.
                                ...(silent ? {silent: true} : {}),
                            })),
                        ],
                    })) as MossTxResult & {receipts?: {transactionHash: `0x${string}`}[]};
                    if (result.status !== "approved") {
                        throw new Error(result.error ?? `wallet ${result.status ?? "error"}`);
                    }
                    const hash =
                        result.receipts?.[result.receipts.length - 1]?.transactionHash ??
                        result.receipt?.transactionHash;
                    if (!hash) throw new Error("wallet returned no transaction receipt");
                    return hash;
                };
                try {
                    return await withMossRetry(() => send(canSilent));
                } catch (err) {
                    // Interactive attempts (canSilent false) have nothing to fall
                    // back to — including a user cancel, which stays final. A failed
                    // SILENT attempt showed no UI, so always degrade it to a popup.
                    const m = err instanceof Error ? err.message : String(err);
                    if (!canSilent) throw err;
                    console.warn("[1-click] silent batch fell back to popup:", m);
                    setSilentIssue(
                        `${calls.map((c) => c.functionName).join("+")}: ${m.split("\n")[0]!.slice(0, 160)}`,
                    );
                    void refreshGrant();
                    return send(false);
                }
            }
            let last!: `0x${string}`;
            for (const c of calls) {
                last = await writeTx(c as Parameters<typeof writeContractAsync>[0]);
                await publicClient?.waitForTransactionReceipt({hash: last});
            }
            return last;
        },
        [isMoss, liveConnector, oneClickActive, grantCovers, refreshGrant, writeTx, publicClient, setSilentIssue],
    );
    const wrongNetwork = isConnected && walletChainId !== activeChain.id;
    const {data: gasBalance} = useBalance({
        address,
        query: {refetchInterval: 5000, enabled: isConnected && !wrongNetwork},
    });

    const [walletMenu, setWalletMenu] = useState(false);
    useEffect(() => {
        if (isConnected) setWalletMenu(false);
    }, [isConnected]);

    // MOSS is MegaETH's embedded wallet (hosted iframe + passkey) — no browser
    // extension required. Extension wallets announce themselves via EIP-6963 and
    // show up as extra connectors; the bare `injected` connector is only offered
    // as a fallback when window.ethereum exists but nothing announced itself.
    const mossConnector = connectors.find((c) => c.id === "mossWallet");
    const discoveredWallets = connectors.filter(
        (c) =>
            c.type === "injected" &&
            c.id !== "injected" &&
            c.id !== "mossWallet" &&
            // MOSS also announces itself via EIP-6963 once its SDK boots; hide the
            // duplicate so it doesn't show up twice under "extension wallets".
            c.id !== "com.megaeth.account",
    );
    const genericInjected = connectors.find((c) => c.id === "injected");
    const hasWindowEthereum =
        typeof window !== "undefined" && !!(window as {ethereum?: unknown}).ethereum;
    const extensionWallets =
        discoveredWallets.length > 0
            ? discoveredWallets
            : genericInjected && hasWindowEthereum
              ? [genericInjected]
              : [];

    const [copied, setCopied] = useState(false);
    const copyAddress = useCallback(async () => {
        if (!address) return;
        try {
            await navigator.clipboard.writeText(address);
        } catch {
            // Clipboard API can be unavailable (permissions, old browsers).
            const ta = document.createElement("textarea");
            ta.value = address;
            document.body.appendChild(ta);
            ta.select();
            document.execCommand("copy");
            ta.remove();
        }
        setCopied(true);
        setTimeout(() => setCopied(false), 1500);
    }, [address]);

    const [tableChoice, setTableChoice] = useState<TableChoice>(
        hasV2 && V2_TABLES.length > 0 ? V2_TABLES[0]!.address : "v1",
    );
    /** Asset family the UI is showing (drives the lobby filter + dropdown). */
    const selectedAsset = assetOfTable(tableChoice as string);
    /** True once the table is a deliberate choice (click, deep link, saved
     *  pick) — suppresses balance auto-detection. */
    const navigated = useRef(false);
    /** True once the choice is real at all (navigation OR auto-detection) —
     *  before that the URL isn't stamped, so a default render can't
     *  masquerade as a shared link on the next reload. */
    const chosen = useRef(false);
    const pickTable = useCallback((t: TableChoice) => {
        navigated.current = true;
        chosen.current = true;
        localStorage.setItem("bj-last-table", t as string);
        setTableChoice(t);
    }, []);

    // Invite deep-links: ?table=<address|v1> lands a friend directly at a table;
    // otherwise the last explicitly-picked table is restored.
    useEffect(() => {
        const t = new URLSearchParams(window.location.search).get("table");
        const saved = localStorage.getItem("bj-last-table");
        const pick = [t, saved].find(
            (v) => v === "v1" || (v && /^0x[0-9a-fA-F]{40}$/.test(v)),
        );
        if (!pick) return;
        navigated.current = true;
        chosen.current = true;
        setTableChoice(pick as TableChoice);
    }, []);
    useEffect(() => {
        if (!chosen.current) return;
        const url = new URL(window.location.href);
        if (tableChoice === "v1") url.searchParams.set("table", "v1");
        else url.searchParams.set("table", tableChoice as string);
        window.history.replaceState(null, "", url);
    }, [tableChoice]);

    const liveRounds = useLiveRounds();

    const [wagerInput, setWagerInput] = useState("10");
    const [lastGameId, setLastGameId] = useState<bigint | null>(null);
    const [lastTx, setLastTx] = useState<string | null>(null);
    const [busy, setBusy] = useState<string | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [history, setHistory] = useState<{gameId: bigint; outcome: number; payout: bigint}[]>([]);

    // ---------------------------------------------------------------- reads

    const table = {address: TABLE_ADDRESS, abi: blackjackTableAbi} as const;
    const chip = {address: CHIP_ADDRESS, abi: testChipAbi} as const;

    const {data: chipBalance} = useReadContract({
        ...chip, functionName: "balanceOf", args: [address ?? "0x0000000000000000000000000000000000000000"],
        query: {...POLL, enabled: isConnected},
    });
    const {data: allowance} = useReadContract({
        ...chip, functionName: "allowance",
        args: [address ?? "0x0000000000000000000000000000000000000000", TABLE_ADDRESS],
        query: {...POLL, enabled: isConnected},
    });

    // What does this wallet actually hold? Feeds the asset dropdown (balance
    // per option) and the first-visit default below.
    const {data: assetBals} = useReadContracts({
        contracts: ASSETS.map(
            (a) =>
                ({
                    address: a.token,
                    abi: testChipAbi,
                    functionName: "balanceOf",
                    args: [address ?? "0x0000000000000000000000000000000000000000"],
                }) as const,
        ),
        query: {refetchInterval: 5000, enabled: isConnected && !!address},
    });
    /** Auto-detect the starting asset ONCE per visit: land on whichever asset
     *  the wallet can play the longest with (balance measured in default-size
     *  bets, so tokens with wildly different scales compare fairly). Explicit
     *  choices — a click, a shared ?table= link, a saved pick — always win. */
    const detected = useRef(false);
    useEffect(() => {
        if (detected.current || navigated.current || !isConnected || !assetBals) return;
        if (assetBals.some((b) => b.status !== "success")) return;
        detected.current = true;
        let best = "";
        let bestScore = 0n;
        ASSETS.forEach((a, i) => {
            const bal = (assetBals[i]!.result as bigint | undefined) ?? 0n;
            const unit = parseEther(defaultWager(a.symbol));
            const score = unit > 0n ? bal / unit : 0n;
            if (score > bestScore) {
                best = a.symbol;
                bestScore = score;
            }
        });
        if (!best) return; // nothing playable yet — stay on CHIP (free faucet)
        chosen.current = true;
        setTableChoice((cur) =>
            assetOfTable(cur as string) === best ? cur : defaultTableForAsset(best),
        );
    }, [assetBals, isConnected]);
    const {data: liquidity} = useReadContract({...table, functionName: "liquidity", query: POLL});
    const {data: minWager} = useReadContract({...table, functionName: "minWager", query: POLL});
    const {data: maxWager} = useReadContract({...table, functionName: "maxWager", query: POLL});
    const {data: paused} = useReadContract({...table, functionName: "paused", query: POLL});
    const {data: timeout_} = useReadContract({...table, functionName: "randomnessTimeout", query: POLL});
    const {data: activeGameId} = useReadContract({
        ...table, functionName: "activeGameOf",
        args: [address ?? "0x0000000000000000000000000000000000000000"],
        query: {...POLL, enabled: isConnected},
    });

    useEffect(() => {
        if (activeGameId && activeGameId !== 0n) setLastGameId(activeGameId);
    }, [activeGameId]);

    const viewGameId = activeGameId && activeGameId !== 0n ? activeGameId : lastGameId;
    const {data: game} = useReadContract({
        ...table, functionName: "getGame", args: [viewGameId ?? 0n],
        query: {...POLL, enabled: viewGameId !== null && viewGameId !== undefined},
    });

    // Pending drand round info for randomness status / beacon submission.
    const {data: drandRequest} = useReadContract({
        address: PROVIDER_ADDRESS, abi: drandRandomnessProviderAbi, functionName: "requests",
        args: [game?.pendingRequestId ?? 0n],
        query: {
            ...POLL,
            enabled: PROVIDER_KIND === "drand" && !!game && game.pendingRequestId !== 0n,
        },
    });

    // Result history straight from events (frontend derives state from chain only).
    useWatchContractEvent({
        ...table, eventName: "GameSettled",
        args: {player: address},
        enabled: isConnected,
        onLogs: (logs) => {
            setHistory((prev) => {
                const next = [...prev];
                for (const log of logs) {
                    const {gameId, outcome, payout} = log.args as {
                        gameId: bigint; outcome: number; payout: bigint;
                    };
                    if (!next.some((h) => h.gameId === gameId)) {
                        next.unshift({gameId, outcome, payout});
                    }
                }
                return next.slice(0, 10);
            });
        },
    });

    // ---------------------------------------------------------------- derived

    const playerCards = useMemo(
        () => (game ? unpackCards(game.playerCards, game.playerCount) : []),
        [game],
    );
    const dealerCards = useMemo(
        () => (game ? unpackCards(game.dealerCards, game.dealerCount) : []),
        [game],
    );
    const playerVal = handValue(playerCards);
    const dealerVal = handValue(dealerCards);

    const state = game?.state as GameState | undefined;
    const awaiting =
        state === GameState.AWAITING_INITIAL_RANDOMNESS ||
        state === GameState.AWAITING_HIT_RANDOMNESS ||
        state === GameState.AWAITING_DEALER_RANDOMNESS;
    const canAct = state === GameState.PLAYER_TURN && !busy;
    const canDouble = canAct && game?.playerCount === 2 && !game?.doubled;
    const gameOver = state === GameState.SETTLED || state === GameState.CANCELLED;
    const noGame = !viewGameId || (gameOver && activeGameId === 0n);

    const cancellableAt =
        game && awaiting && timeout_ !== undefined
            ? Number(game.requestTimestamp) + Number(timeout_)
            : null;
    const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
    useEffect(() => {
        const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
        return () => clearInterval(t);
    }, []);

    const drandRound = drandRequest ? (drandRequest as readonly unknown[])[1] as bigint : null;
    const drandReady = drandRound ? BigInt(now) >= drandPublishTime(BigInt(drandRound)) : false;

    // ---------------------------------------------------------------- actions

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
                console.error("[blackjack] action failed:", err);
                const full = err instanceof Error ? err.message : String(err);
                if (!ignore?.test(full)) {
                    const firstLine = full.split("\n")[0]!;
                    // Wallet errors often bury the useful part past line 1.
                    const detail =
                        firstLine.length < 40 ? full.replaceAll("\n", " · ").slice(0, 300) : firstLine;
                    setError(friendlyError(detail));
                }
            } finally {
                setBusy(null);
            }
        },
        [publicClient, queryClient],
    );

    const onFaucet = () => run("faucet", () => writeTx({...chip, functionName: "faucet"}));

    /** Grant call-scopes per table kind. */
    const perHandSigs = (t: string) => [
        {to: t, signature: "placeBet(uint256)"},
        {to: t, signature: "hit(uint256)"},
        {to: t, signature: "stand(uint256)"},
        {to: t, signature: "double(uint256)"},
        {to: t, signature: "surrender(uint256)"},
        {to: t, signature: "cancelTimedOutGame(uint256)"},
        {to: t, signature: "fundHouse(uint256)"},
        ...(isV3Table(t) ? [{to: t, signature: "split(uint256)"}] : []),
    ];
    const infiniteSigs = (t: string) => [
        {to: t, signature: "placeBet(uint256)"},
        {to: t, signature: "act(uint8,uint8)"},
        {to: t, signature: "lockDeal()"},
        {to: t, signature: "lockActions()"},
        {to: t, signature: "settle(uint256)"},
        {to: t, signature: "cancelRound(uint256)"},
        {to: t, signature: "refund(uint256,uint256)"},
        {to: t, signature: "withdrawDeferred()"},
        {to: t, signature: "fundHouse(uint256)"},
    ];

    /**
     * The grant PLAN for a table: every {to, signature} pair this build's game
     * flows need there. Used both to REQUEST the grant and to AUDIT an existing
     * grant against it — so an app update that adds calls automatically flags
     * stale approvals instead of silently downgrading to popups.
     * Scope: CHIP tables are granted individually (the all-tables list is the
     * shape known to stall the wallet's approval sheet); the real-asset families
     * (USDm/ETH/MEGA) have only TWO tables each, so one approval covers both.
     */
    const grantPlanFor = useCallback(
        (choice: TableChoice) => {
            const v1 = choice === "v1";
            const target = (v1 ? TABLE_ADDRESS : choice) as `0x${string}`;
            const {token: grantToken, symbol: grantSym} = tableToken(target);
            const assetPair =
                grantSym !== "CHIP"
                    ? {
                          classic: ASSET_TABLES.find((t) => t.symbol === grantSym)?.table,
                          infinite: INFINITE_TABLES.find((t) => t.symbol === grantSym)?.address,
                      }
                    : null;
            const grantTargets: string[] = assetPair
                ? ([assetPair.classic, assetPair.infinite].filter(Boolean) as string[])
                : [target];
            const tableCalls = v1
                ? [
                      {to: target as string, signature: "placeBet(uint256)"},
                      {to: target as string, signature: "hit()"},
                      {to: target as string, signature: "stand()"},
                      {to: target as string, signature: "double()"},
                      {to: target as string, signature: "cancelTimedOutGame(uint256)"},
                  ]
                : grantTargets.flatMap((t) =>
                      isInfiniteTable(t) ? infiniteSigs(t) : perHandSigs(t),
                  );
            const calls = [
                ...(grantToken.toLowerCase() === CHIP_ADDRESS.toLowerCase()
                    ? [{to: CHIP_ADDRESS as string, signature: "faucet()"}]
                    : []),
                {to: grantToken as string, signature: "approve(address,uint256)"},
                {to: PROVIDER_ADDRESS as string, signature: "fulfill(uint256,bytes)"},
                ...tableCalls,
            ];
            return {target, grantToken, grantSym, grantTargets, calls};
        },
        // eslint-disable-next-line react-hooks/exhaustive-deps
        [],
    );

    /** Why the active grant is insufficient at the current table, if it is:
     *  kind "table" — approval was for a different table; kind "update" — an
     *  app update added calls (new functions, token coverage, family tables)
     *  that the stored grant predates, with the exact missing pairs listed so
     *  a persistent flag is diagnosable instead of mysterious. */
    const coverageGap = useMemo(() => {
        if (!oneClickActive) return null;
        const plan = grantPlanFor(tableChoice);
        if (!grantCovers(plan.target)) return {kind: "table" as const, missing: [] as string[]};
        const known = oneClickGrant?.calls;
        if (!known || known.length === 0) return null; // unknown — don't false-alarm
        const have = new Set(known.map((c) => c.toLowerCase().replace(/\s+/g, "")));
        const missing = plan.calls
            .map((c) => normCall(c.to, c.signature))
            .filter((c) => !have.has(c));
        if (missing.length > 0) console.warn("[1-click] grant is missing:", missing);
        return missing.length === 0 ? null : {kind: "update" as const, missing};
    }, [oneClickActive, grantPlanFor, tableChoice, grantCovers, oneClickGrant]);

    /** One passkey approval; afterwards matching game calls skip the popup. */
    const onEnableOneClick = () =>
        run("oneclick", async () => {
            const plan = grantPlanFor(tableChoice);
            const {grantToken, grantSym, grantTargets, target} = plan;
            const provider = (await liveConnector!.getProvider()) as MossProvider;
            const expiry = Math.floor(Date.now() / 1000) + ONE_CLICK_HOURS * 3600;
            // The plan IS the request: token approve + spend cap for the table's
            // wager token, beacon fulfill, and every game call the plan lists.
            const spendCap = parseEther(ONE_CLICK_SPEND_PER_DAY[grantSym] ?? "100");
            const request = provider.request({
                method: "wallet_grantPermissions",
                params: [
                    {
                        permissions: {
                            expiry,
                            permissions: {
                                calls: plan.calls,
                                spend: [
                                    {limit: spendCap, period: "day", token: grantToken},
                                    {limit: parseEther(ONE_CLICK_GAS_PER_DAY), period: "day"},
                                ],
                            },
                        },
                    },
                ],
            });
            const res = (await Promise.race([
                request,
                new Promise((_, reject) =>
                    setTimeout(
                        () =>
                            reject(
                                new Error(
                                    "The wallet never showed its approval screen. Reload the page and try again — play works without 1-click too (normal popups).",
                                ),
                            ),
                        60_000,
                    ),
                ),
            ])) as {status?: string};
            if (res?.status !== "approved") throw new Error("permission grant was not approved");
            const targets = Array.from(
                new Set(
                    [grantToken, PROVIDER_ADDRESS, target, ...grantTargets].map((a) =>
                        a.toLowerCase(),
                    ),
                ),
            );
            // What was requested is what was granted (wallet keeps ONE grant, so
            // no merge with older targets). grantedAt marks this record as
            // approval-sheet ground truth so a lagging wallet report can't
            // immediately downgrade it; a delayed refresh reconciles once the
            // wallet has caught up.
            const calls = plan.calls.map((c) => normCall(c.to, c.signature));
            const grant = {expiry, targets, calls, grantedAt: Math.floor(Date.now() / 1000)};
            localStorage.setItem(oneClickKey, JSON.stringify(grant));
            setOneClickGrant(grant);
            setSilentIssue(null);
            setTimeout(() => void refreshGrant(), 5000);
            return null;
        });

    const onDisableOneClick = () =>
        run("oneclick", async () => {
            const provider = (await liveConnector!.getProvider()) as MossProvider;
            await provider.request({method: "wallet_revokePermissions"});
            localStorage.removeItem(oneClickKey);
            setOneClickGrant(null);
            return null;
        });

    const onBet = () =>
        run("bet", async () => {
            const wager = parseEther(wagerInput || "0");
            // Fresh read (not the polled hook): approvals can be revoked out-of-band.
            const live = (await publicClient!.readContract({
                ...chip, functionName: "allowance", args: [address!, TABLE_ADDRESS],
            })) as bigint;
            const calls = [];
            if (live < wager) {
                calls.push({
                    ...chip, functionName: "approve",
                    args: [TABLE_ADDRESS, wager * (isMoss ? 1n : 100n)] as const,
                });
            }
            calls.push({...table, functionName: "placeBet", args: [wager] as const});
            return writeBatch(calls);
        });

    const onHit = () => run("hit", () => writeTx({...table, functionName: "hit"}));
    const onStand = () => run("stand", () => writeTx({...table, functionName: "stand"}));
    const onDouble = () =>
        run("double", async () => {
            const wager = game!.wager;
            const live = (await publicClient!.readContract({
                ...chip, functionName: "allowance", args: [address!, TABLE_ADDRESS],
            })) as bigint;
            const calls = [];
            if (live < wager) {
                calls.push({
                    ...chip, functionName: "approve",
                    args: [TABLE_ADDRESS, wager * (isMoss ? 1n : 100n)] as const,
                });
            }
            calls.push({...table, functionName: "double"});
            return writeBatch(calls);
        });

    /**
     * Anyone may submit the public beacon; here the player's own wallet does it.
     * A concurrent submitter winning the race reverts us with AlreadyFulfilled —
     * that's a success for the game, so it's swallowed rather than shown.
     */
    const onSubmitBeacon = () =>
        run(
            "beacon",
            async () => {
                if (!game || game.pendingRequestId === 0n) return null;
                if (PROVIDER_KIND === "drand") {
                    if (!drandRound) return null;
                    const sig = await fetchBeaconSignature(BigInt(drandRound));
                    return writeTx({
                        address: PROVIDER_ADDRESS, abi: drandRandomnessProviderAbi,
                        functionName: "fulfill", args: [game.pendingRequestId, sig],
                    });
                }
                // Local dev only: mock provider takes a caller-chosen seed.
                const bytes = crypto.getRandomValues(new Uint8Array(32));
                const seed = `0x${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")}` as `0x${string}`;
                return writeTx({
                    address: PROVIDER_ADDRESS, abi: mockRandomnessProviderAbi,
                    functionName: "fulfill", args: [game.pendingRequestId, seed],
                });
            },
            /AlreadyFulfilled/i,
        );

    // Auto-reveal: submit the beacon the moment drand publishes it, so a hand
    // plays bet → short wait → cards, with no button hunting. One attempt per
    // request id; a failure surfaces the manual button instead of retry-looping.
    const [autoBeacon, setAutoBeacon] = useState(true);
    useEffect(() => {
        const stored = localStorage.getItem("auto-beacon");
        if (stored !== null) setAutoBeacon(stored === "1");
    }, []);
    const toggleAutoBeacon = () =>
        setAutoBeacon((v) => {
            localStorage.setItem("auto-beacon", v ? "0" : "1");
            return !v;
        });
    const autoTried = useRef<bigint | null>(null);
    useEffect(() => {
        if (!autoBeacon || PROVIDER_KIND !== "drand") return;
        const reqId = game?.pendingRequestId;
        if (!awaiting || !drandReady || !reqId || busy) return;
        if (autoTried.current === reqId) return;
        autoTried.current = reqId;
        void onSubmitBeacon();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [autoBeacon, awaiting, drandReady, game?.pendingRequestId, busy]);

    const onCancel = () =>
        run("cancel", () =>
            writeTx({...table, functionName: "cancelTimedOutGame", args: [viewGameId!]}),
        );

    // ---------------------------------------------------------------- render

    if (!isConfigured) {
        return (
            <main>
                <h1>MegaETH Blackjack</h1>
                <div className="panel">
                    Set <code>NEXT_PUBLIC_TABLE_ADDRESS</code> / <code>NEXT_PUBLIC_CHIP_ADDRESS</code>{" "}
                    (see <code>.env.example</code>) to point this UI at a deployment.
                </div>
            </main>
        );
    }

    const outcomeClass =
        game && game.outcome !== Outcome.NONE
            ? game.outcome === Outcome.PLAYER_BLACKJACK || game.outcome === Outcome.PLAYER_WIN
                ? "win"
                : game.outcome === Outcome.PUSH || game.outcome === Outcome.CANCELLED_REFUND
                  ? "push"
                  : "lose"
            : "";

    return (
        <main>
            <div className="row">
                <h1>♠ MegaETH Blackjack <span className="status">(testnet · build {BUILD_ID})</span></h1>
                {isConnected ? (
                    <div className="row" style={{gap: 8}}>
                        <button className="secondary addr" title="Copy full address" onClick={copyAddress}>
                            {copied ? "✓ copied" : <>{address?.slice(0, 6)}…{address?.slice(-4)} ⧉</>}
                        </button>
                        <button className="secondary" onClick={() => disconnect()}>Disconnect</button>
                    </div>
                ) : (
                    <button onClick={() => {
                        setPickerError(null);
                        setWalletMenu(true);
                        // Warm the MOSS iframe while the user reads the picker, so
                        // clicking MOSS doesn't race the whole wallet boot sequence.
                        // eth_accounts is non-interactive (no prompt).
                        mossConnector
                            ?.getProvider()
                            .then((p) =>
                                (p as {request: (a: {method: string}) => Promise<unknown>}).request({
                                    method: "eth_accounts",
                                }),
                            )
                            .catch(() => {});
                    }}>
                        Connect wallet
                    </button>
                )}
            </div>

            {walletMenu && !isConnected && (
                <div className="modal-backdrop" onClick={() => setWalletMenu(false)}>
                    <div className="modal" onClick={(e) => e.stopPropagation()}>
                        <div className="row">
                            <div className="hand-title">Connect a wallet</div>
                            <button className="ghost" onClick={() => setWalletMenu(false)}>✕</button>
                        </div>

                        {mossConnector && (
                            <button
                                className="wallet-option"
                                disabled={pickerBusy}
                                onClick={() => clickWallet(mossConnector)}
                            >
                                {mossConnector.icon && (
                                    /* eslint-disable-next-line @next/next/no-img-element */
                                    <img src={mossConnector.icon} alt="" />
                                )}
                                <span>
                                    <strong>MOSS — MegaETH&apos;s wallet</strong>
                                    <span className="sub">
                                        Nothing to install · passkey sign-in · works on mobile
                                    </span>
                                </span>
                            </button>
                        )}

                        {extensionWallets.map((c) => (
                            <button
                                key={c.uid}
                                className="wallet-option"
                                disabled={pickerBusy}
                                onClick={() => clickWallet(c)}
                            >
                                {c.icon && (
                                    /* eslint-disable-next-line @next/next/no-img-element */
                                    <img src={c.icon} alt="" />
                                )}
                                <span>
                                    <strong>{c.id === "injected" ? "Browser wallet" : c.name}</strong>
                                    <span className="sub">extension wallet</span>
                                </span>
                            </button>
                        ))}

                        {extensionWallets.length === 0 && (
                            <div className="status">
                                No browser-wallet extension detected — MOSS above works without
                                one. To use MetaMask or another extension instead, install it and
                                reload this page.
                            </div>
                        )}

                        {pickerBusy && <div className="status">Waiting for the wallet — check for a popup…</div>}
                        {pickerError && <div className="error">{pickerError}</div>}
                    </div>
                </div>
            )}

            {wrongNetwork && (
                <div className="panel row" style={{borderColor: "#7a5600"}}>
                    <span className="status">
                        Your wallet is on another network. This table lives on{" "}
                        <strong>{activeChain.name}</strong> (chain {activeChain.id}).
                    </span>
                    <button disabled={switching} onClick={() => switchChain({chainId: activeChain.id})}>
                        {switching ? "Check your wallet…" : `Switch / add ${activeChain.name}`}
                    </button>
                </div>
            )}

            {isConnected && !wrongNetwork && (chipBalance ?? 0n) === 0n && noGame && (
                <div className="panel">
                    <div className="hand-title">Getting started (everything here is free)</div>
                    <ol className="steps">
                        <li>
                            <strong>Gas:</strong>{" "}
                            {gasBalance !== undefined && gasBalance.value > 0n ? (
                                <>✅ you have {Number(formatEther(gasBalance.value)).toFixed(4)} testnet ETH</>
                            ) : (
                                <>
                                    copy your address{" "}
                                    <button className="tiny addr" onClick={copyAddress}>
                                        {copied ? "✓ copied" : <>{address?.slice(0, 8)}…{address?.slice(-6)} ⧉</>}
                                    </button>{" "}
                                    and paste it at{" "}
                                    <a href={GAS_FAUCET_URL} target="_blank" rel="noreferrer">
                                        testnet.megaeth.com
                                    </a>{" "}
                                    for free testnet ETH (human check, ~30s)
                                </>
                            )}
                        </li>
                        <li>
                            <strong>Chips:</strong> claim 1000 free CHIP with the faucet button below
                        </li>
                        <li>
                            <strong>Play:</strong> place a bet — cards come from the drand public
                            randomness beacon, verified onchain
                        </li>
                    </ol>
                </div>
            )}

            {(() => {
                const jr = joinableRound(liveRounds, now);
                if (!jr || (tableChoice as string).toLowerCase() === jr.table.toLowerCase()) {
                    return null;
                }
                return (
                    <button className="live-banner" onClick={() => pickTable(jr.table)}>
                        🔴 LIVE — a round is filling at ♾️ {jr.symbol} Infinite · {jr.playerCount}{" "}
                        player{jr.playerCount === 1 ? "" : "s"} in · {Math.max(0, jr.betDeadline - now)}s
                        left to join →
                    </button>
                );
            })()}
            <div className="panel row">
                <span className="status">
                    🎰 Playing with{" "}
                    <strong>{selectedAsset === "ETH" ? "ETH (as WETH)" : selectedAsset}</strong>
                    {isConnected && assetBals
                        ? ` — you hold ${fmt(
                              (assetBals[ASSETS.findIndex((a) => a.symbol === selectedAsset)]
                                  ?.result as bigint | undefined) ?? 0n,
                          )}`
                        : ""}
                </span>
                <select
                    value={selectedAsset}
                    onChange={(e) => pickTable(defaultTableForAsset(e.target.value))}
                    aria-label="Wager asset"
                >
                    {ASSETS.map((a, i) => {
                        const b = assetBals?.[i]?.result as bigint | undefined;
                        return (
                            <option key={a.symbol} value={a.symbol}>
                                {a.symbol}
                                {isConnected && b !== undefined ? ` — ${fmt(b)}` : ""}
                            </option>
                        );
                    })}
                </select>
            </div>

            <Lobby
                selected={tableChoice}
                onSelect={pickTable}
                live={liveRounds}
                asset={selectedAsset}
            />

            {tableChoice === "v1" && (
            <div className="panel stats">
                <div className="stat">
                    <div className="label">Your CHIP balance</div>
                    <div className="value">{isConnected ? fmt(chipBalance) : "—"}</div>
                </div>
                <div className="stat">
                    <div className="label">House bankroll</div>
                    <div className="value">{fmt(liquidity?.[0])}</div>
                </div>
                <div className="stat">
                    <div className="label">Available liquidity</div>
                    <div className="value">{fmt(liquidity?.[2])}</div>
                </div>
                <div className="stat">
                    <div className="label">Bet limits</div>
                    <div className="value">{fmt(minWager)} – {fmt(maxWager)}</div>
                </div>
                <div className="stat">
                    <div className="label">Table status</div>
                    <div className="value">{paused ? "⏸ paused" : "open"}</div>
                </div>
            </div>

            )}

            {isConnected && (
                <div className="panel row">
                    <span className="status">Need play chips? Free faucet, 1000 CHIP / hour.</span>
                    <button className="secondary" disabled={!!busy} onClick={onFaucet}>
                        {busy === "faucet" ? "Claiming…" : "Claim faucet chips"}
                    </button>
                </div>
            )}

            {isMoss && !wrongNetwork && (
                <div className="panel row">
                    {oneClickActive && coverageGap !== null ? (
                        <>
                            <span className="status">
                                {coverageGap.kind === "table"
                                    ? "⚡ 1-click play is on, but your approval predates this table. Approve once (passkey) to cover this table too."
                                    : "⚡ 1-click play is on, but an app update added new actions your approval predates — re-approve once (passkey) to keep everything silent."}
                                {coverageGap.missing.length > 0 && (
                                    <>
                                        <br />
                                        missing:{" "}
                                        {coverageGap.missing
                                            .slice(0, 4)
                                            .map((c) => {
                                                const [to = "", sig = ""] = c.split(":");
                                                return `${sig.split("(")[0]} @ ${grantTargetLabel(to)}`;
                                            })
                                            .join(" · ")}
                                        {coverageGap.missing.length > 4
                                            ? ` · +${coverageGap.missing.length - 4} more`
                                            : ""}
                                    </>
                                )}
                            </span>
                            <button className="pulse" disabled={!!busy} onClick={onEnableOneClick}>
                                {busy === "oneclick" ? "Check the wallet…" : "⚡ Re-approve 1-click"}
                            </button>
                        </>
                    ) : oneClickActive ? (
                        <>
                            <span className="status">
                                ⚡ <strong>1-click play is on</strong> — game moves go through without
                                popups (expires {new Date(oneClickExpiry * 1000).toLocaleTimeString()}).
                                <br />
                                covers:{" "}
                                {(oneClickGrant?.targets ?? [])
                                    .map((t) => grantTargetLabel(t))
                                    .join(" · ")}
                                {silentIssue && (
                                    <>
                                        <br />
                                        ⚠️ last silent call fell back to a popup — {silentIssue}
                                        {/spend|limit|cap|exceed|budget/i.test(silentIssue)
                                            ? " (looks like the daily spend cap — re-approving resets it)"
                                            : ""}
                                    </>
                                )}
                            </span>
                            {silentIssue && (
                                <button className="pulse" disabled={!!busy} onClick={onEnableOneClick}>
                                    {busy === "oneclick" ? "Check the wallet…" : "⚡ Re-approve"}
                                </button>
                            )}
                            <button className="secondary" disabled={!!busy} onClick={onDisableOneClick}>
                                {busy === "oneclick" ? "…" : "Turn off"}
                            </button>
                        </>
                    ) : (
                        <>
                            <span className="status">
                                Tired of approving every move? <strong>1-click play</strong> asks for
                                one passkey approval, then bets/hits/stands run silently. CHIP tables are
                                approved one at a time; USDm/ETH/MEGA approvals cover BOTH tables of
                                the asset. Daily spend caps, {ONE_CLICK_HOURS}h expiry, revocable anytime.
                            </span>
                            <button disabled={!!busy} onClick={onEnableOneClick}>
                                {busy === "oneclick" ? "Check the wallet…" : "⚡ Enable 1-click play"}
                            </button>
                        </>
                    )}
                </div>
            )}

            {tableChoice !== "v1" && isInfiniteTable(tableChoice as string) ? (
                <InfiniteTable
                    key={tableChoice}
                    table={tableChoice as `0x${string}`}
                    name={
                        INFINITE_TABLES.find(
                            (t) => t.address.toLowerCase() === (tableChoice as string).toLowerCase(),
                        )?.symbol.concat(" Infinite — shared table") ?? "Infinite table"
                    }
                    address={address}
                    isConnected={isConnected && !wrongNetwork}
                    token={tableToken(tableChoice as string).token}
                    symbol={tableToken(tableChoice as string).symbol}
                    vault={VAULTS[(tableChoice as string).toLowerCase()]}
                    writeTx={(a) => writeTx(a as Parameters<typeof writeContractAsync>[0])}
                    writeBatch={writeBatch}
                />
            ) : tableChoice !== "v1" && address !== undefined || tableChoice !== "v1" ? (
                <V2Table
                    key={tableChoice}
                    table={tableChoice as `0x${string}`}
                    name={
                        V2_TABLES.find((t) => t.address === tableChoice)?.name ??
                        V3_TABLES.find((t) => t.address === tableChoice)?.name ??
                        ASSET_TABLES.find((t) => t.table === tableChoice)?.symbol.concat(
                            " Classic",
                        ) ??
                        "Community table"
                    }
                    address={address}
                    isConnected={isConnected && !wrongNetwork}
                    oneClickActive={grantCovers(tableChoice as string)}
                    isMoss={isMoss}
                    isV3={isV3Table(tableChoice as string)}
                    token={tableToken(tableChoice as string).token}
                    symbol={tableToken(tableChoice as string).symbol}
                    vault={VAULTS[(tableChoice as string).toLowerCase()]}
                    writeTx={(a) => writeTx(a as Parameters<typeof writeContractAsync>[0])}
                    writeBatch={writeBatch}
                />
            ) : (
            <>
            <div className="panel felt">
                <div className="hand-title">
                    Dealer
                    {dealerCards.length > 0 && (
                        <TotalBadge
                            total={dealerVal.total}
                            soft={dealerVal.soft}
                            bust={dealerVal.total > 21}
                        />
                    )}
                </div>
                <div className="cards">
                    {dealerCards.map((c, i) => <CardView key={i} card={c} />)}
                    {!gameOver && dealerCards.length === 1 && <CardView hidden />}
                    {dealerCards.length === 0 && <span className="status">no cards yet</span>}
                </div>

                <div className="hand-title" style={{marginTop: 16}}>
                    You
                    {playerCards.length > 0 && (
                        <TotalBadge
                            total={playerVal.total}
                            soft={playerVal.soft}
                            bust={playerVal.total > 21}
                        />
                    )}
                    {game && game.doubled ? " · doubled" : ""}
                    {game ? ` · wager ${fmt(game.doubled ? game.wager * 2n : game.wager)} CHIP` : ""}
                </div>
                <div className="cards">
                    {playerCards.map((c, i) => <CardView key={i} card={c} />)}
                    {playerCards.length === 0 && <span className="status">place a bet to be dealt in</span>}
                </div>

                <div className="row" style={{marginTop: 16}}>
                    {noGame && isConnected && (
                        <div className="row" style={{gap: 8}}>
                            <input
                                value={wagerInput}
                                onChange={(e) => setWagerInput(e.target.value)}
                                inputMode="decimal"
                                aria-label="wager in CHIP"
                            />
                            <button disabled={!!busy || paused === true} onClick={onBet}>
                                {busy === "bet" ? "Placing bet…" : "Place bet"}
                            </button>
                        </div>
                    )}
                    {state === GameState.PLAYER_TURN && (
                        <div className="row" style={{gap: 8}}>
                            <button disabled={!canAct} onClick={onHit}>
                                {busy === "hit" ? "…" : "Hit"}
                            </button>
                            <button disabled={!canAct} onClick={onStand}>
                                {busy === "stand" ? "…" : "Stand"}
                            </button>
                            <button disabled={!canDouble || paused === true} onClick={onDouble}>
                                {busy === "double" ? "…" : "Double"}
                            </button>
                        </div>
                    )}
                    {awaiting && (
                        <div className="row" style={{gap: 8}}>
                            <span className="status">
                                {PROVIDER_KIND !== "drand"
                                    ? "🎲 waiting for randomness…"
                                    : busy === "beacon"
                                      ? `🎲 revealing cards…${oneClickActive ? "" : " (confirm in your wallet if prompted)"}`
                                      : drandReady
                                        ? autoBeacon && !error
                                            ? "🎲 beacon published — revealing…"
                                            : "🎲 beacon published — reveal your cards:"
                                        : drandRound
                                          ? `🎲 cards locked to public drand round ${drandRound} — publishes in ~${Math.max(0, Number(drandPublishTime(BigInt(drandRound))) - now)}s`
                                          : "🎲 committing to a future drand round…"}
                            </span>
                            {(PROVIDER_KIND !== "drand" || !autoBeacon || !!error) && (
                                <button
                                    className={
                                        PROVIDER_KIND !== "drand" || drandReady ? "pulse" : "secondary"
                                    }
                                    disabled={!!busy || (PROVIDER_KIND === "drand" && !drandReady)}
                                    onClick={onSubmitBeacon}
                                >
                                    {busy === "beacon"
                                        ? "Submitting…"
                                        : PROVIDER_KIND === "drand"
                                          ? "Submit beacon"
                                          : "Reveal (dev seed)"}
                                </button>
                            )}
                            {PROVIDER_KIND === "drand" && (
                                <label
                                    className="status"
                                    style={{cursor: "pointer", userSelect: "none"}}
                                    title="Submit the public drand beacon automatically as soon as it publishes (anyone may submit it — it only unlocks the committed cards)"
                                >
                                    <input
                                        type="checkbox"
                                        checked={autoBeacon}
                                        onChange={toggleAutoBeacon}
                                    />{" "}
                                    auto-reveal
                                </label>
                            )}
                            {cancellableAt !== null && now >= cancellableAt && (
                                <button className="secondary" disabled={!!busy} onClick={onCancel}>
                                    Cancel & refund (timed out)
                                </button>
                            )}
                        </div>
                    )}
                </div>

                {gameOver && game && (
                    <div className={`result ${outcomeClass}`} style={{marginTop: 12}}>
                        {OutcomeNames[game.outcome]!.replaceAll("_", " ")}
                        {game.payout > 0n ? ` — paid ${fmt(game.payout)} CHIP` : ""}
                    </div>
                )}

                {lastTx && (
                    <div className="status" style={{marginTop: 10}}>
                        last tx: <a href={txUrl(lastTx)} target="_blank" rel="noreferrer">{lastTx.slice(0, 10)}…{lastTx.slice(-8)}</a>
                    </div>
                )}
                {error && <div className="error" style={{marginTop: 10}}>{error}</div>}
            </div>

            {history.length > 0 && (
                <div className="panel">
                    <div className="hand-title">Recent results (from onchain events)</div>
                    <div className="history">
                        {history.map((h) => (
                            <div key={h.gameId.toString()}>
                                game #{h.gameId.toString()} — {OutcomeNames[h.outcome]?.replaceAll("_", " ")}
                                {h.payout > 0n ? ` (paid ${fmt(h.payout)} CHIP)` : ""}
                            </div>
                        ))}
                    </div>
                </div>
            )}
            </>
            )}

            <StatsPanel address={address} />

            <PresencePanel tableChoice={tableChoice} onSelect={pickTable} mainWallet={address} />
            <Chat />

            <div className="panel status">
                Fully onchain: cards come from committed randomness (drand quicknet via MegaETH&apos;s
                preinstalled verifier), settlement is enforced by the BlackjackTable contract, and this
                page only reads chain state — there is no game server. Rules: European no-hole-card,
                dealer stands on all 17s, blackjack pays 3:2, double on first two cards.{" "}
                <span title="deployed commit">build {BUILD_ID}</span>
            </div>
        </main>
    );
}
