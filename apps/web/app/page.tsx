"use client";

import {useCallback, useEffect, useMemo, useRef, useState} from "react";
import {
    useAccount,
    useBalance,
    useConnect,
    useDisconnect,
    usePublicClient,
    useReadContract,
    useSwitchChain,
    useWatchContractEvent,
    useWriteContract,
} from "wagmi";
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
import {CardView, fmt} from "./ui.tsx";
import {Lobby, type TableChoice} from "./lobby.tsx";
import {V2Table} from "./v2table.tsx";
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
    hasV2,
} from "../lib/config.ts";

const POLL = {refetchInterval: 1500} as const;

/** How MOSS "Smart Approvals" session grants are scoped for 1-click play. */
const ONE_CLICK_HOURS = 24;
const ONE_CLICK_CHIP_PER_DAY = "5000";
const ONE_CLICK_GAS_PER_DAY = "0.01";

type MossProvider = {
    request: (args: {method: string; params?: unknown}) => Promise<unknown>;
};
type MossTxResult = {
    status: "approved" | "cancelled" | "error";
    error?: string;
    receipt?: {transactionHash: `0x${string}`};
};



const MOSS_BOOT_FAILURE = /did not respond|Failed to establish a connection to the MegaETH wallet/i;

/** Translate known wallet errors into something actionable. */
function friendlyError(msg: string): string {
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
    const [oneClickGrant, setOneClickGrant] = useState<{expiry: number; targets: string[]} | null>(
        null,
    );
    useEffect(() => {
        if (!isMoss || !address) return setOneClickGrant(null);
        const raw = localStorage.getItem(oneClickKey);
        if (!raw) return setOneClickGrant(null);
        try {
            const p = JSON.parse(raw) as {expiry?: number; targets?: string[]};
            if (p && typeof p.expiry === "number") {
                return setOneClickGrant({
                    expiry: p.expiry,
                    targets: (p.targets ?? []).map((t) => t.toLowerCase()),
                });
            }
        } catch {
            /* old format: bare expiry number covering only the v1 contracts */
        }
        const n = Number(raw);
        setOneClickGrant(
            n > 0
                ? {
                      expiry: n,
                      targets: [CHIP_ADDRESS, PROVIDER_ADDRESS, TABLE_ADDRESS].map((a) =>
                          a.toLowerCase(),
                      ),
                  }
                : null,
        );
    }, [isMoss, address, oneClickKey]);
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
                // grant; if the grant expired, fall back to the normal approval UI.
                try {
                return await withMossRetry(async () => {
                    const provider = (await liveConnector.getProvider()) as MossProvider;
                    const result = (await provider.request({
                        method: "wallet_callContract",
                        params: [
                            {
                                address: args.address,
                                abi: args.abi,
                                functionName: args.functionName,
                                args: args.args ?? [],
                                silent: true,
                                silentUIApproveFallback: true,
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
                    // policy edge) degrades to a normal approval popup instead of
                    // surfacing a dead-end error. Explicit user cancels stay final.
                    const m = err instanceof Error ? err.message : String(err);
                    if (/cancel/i.test(m)) throw err;
                }
            }
            const doWrite = () =>
                writeContractAsync(
                    liveConnector ? ({...args, connector: liveConnector} as typeof args) : args,
                );
            return liveConnector?.id === "mossWallet" ? withMossRetry(doWrite) : doWrite();
        },
        [writeContractAsync, liveConnector, oneClickActive, grantCovers],
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
                }
            } catch (err) {
                const full = err instanceof Error ? err.message : String(err);
                if (!ignore?.test(full)) {
                    setError(friendlyError(full.split("\n")[0]!));
                }
            } finally {
                setBusy(null);
            }
        },
        [publicClient],
    );

    const onFaucet = () => run("faucet", () => writeTx({...chip, functionName: "faucet"}));

    /** One passkey approval; afterwards matching game calls skip the popup. */
    /**
     * One passkey approval; afterwards matching game calls skip the popup.
     * Scoped to the chip + provider + the CURRENTLY SELECTED table only: the
     * small per-table payload is the shape the wallet's approval sheet is known
     * to render reliably (a 29-entry all-tables list has been seen to stall it),
     * and coverage merges as the player approves more tables.
     */
    const onEnableOneClick = () =>
        run("oneclick", async () => {
            const v1 = tableChoice === "v1";
            const target = (v1 ? TABLE_ADDRESS : tableChoice) as `0x${string}`;
            const provider = (await liveConnector!.getProvider()) as MossProvider;
            const expiry = Math.floor(Date.now() / 1000) + ONE_CLICK_HOURS * 3600;
            const tableCalls = v1
                ? [
                      {to: target, signature: "placeBet(uint256)"},
                      {to: target, signature: "hit()"},
                      {to: target, signature: "stand()"},
                      {to: target, signature: "double()"},
                      {to: target, signature: "cancelTimedOutGame(uint256)"},
                  ]
                : [
                      {to: target, signature: "placeBet(uint256)"},
                      {to: target, signature: "hit(uint256)"},
                      {to: target, signature: "stand(uint256)"},
                      {to: target, signature: "double(uint256)"},
                      {to: target, signature: "surrender(uint256)"},
                      {to: target, signature: "cancelTimedOutGame(uint256)"},
                      {to: target, signature: "fundHouse(uint256)"},
                  ];
            const request = provider.request({
                method: "wallet_grantPermissions",
                params: [
                    {
                        permissions: {
                            expiry,
                            permissions: {
                                calls: [
                                    {to: CHIP_ADDRESS, signature: "faucet()"},
                                    {to: CHIP_ADDRESS, signature: "approve(address,uint256)"},
                                    {to: PROVIDER_ADDRESS, signature: "fulfill(uint256,bytes)"},
                                    ...tableCalls,
                                ],
                                spend: [
                                    {
                                        limit: parseEther(ONE_CLICK_CHIP_PER_DAY),
                                        period: "day",
                                        token: CHIP_ADDRESS,
                                    },
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
                new Set([
                    ...(oneClickGrant?.targets ?? []),
                    ...[CHIP_ADDRESS, PROVIDER_ADDRESS, target].map((a) => a.toLowerCase()),
                ]),
            );
            localStorage.setItem(oneClickKey, JSON.stringify({expiry, targets}));
            setOneClickGrant({expiry, targets});
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
            if ((allowance ?? 0n) < wager) {
                // Silent mode approves the exact wager (spend-cap friendly, no UX
                // cost); popup mode approves a large multiple to spare the user
                // one dialog per bet.
                const approveHash = await writeTx({
                    ...chip, functionName: "approve",
                    args: [TABLE_ADDRESS, wager * (oneClickActive ? 1n : 100n)],
                });
                await publicClient?.waitForTransactionReceipt({hash: approveHash});
            }
            return writeTx({...table, functionName: "placeBet", args: [wager]});
        });

    const onHit = () => run("hit", () => writeTx({...table, functionName: "hit"}));
    const onStand = () => run("stand", () => writeTx({...table, functionName: "stand"}));
    const onDouble = () =>
        run("double", async () => {
            const wager = game!.wager;
            if ((allowance ?? 0n) < wager) {
                const approveHash = await writeTx({
                    ...chip, functionName: "approve",
                    args: [TABLE_ADDRESS, wager * (oneClickActive ? 1n : 100n)],
                });
                await publicClient?.waitForTransactionReceipt({hash: approveHash});
            }
            return writeTx({...table, functionName: "double"});
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

            <Lobby selected={tableChoice} onSelect={setTableChoice} />

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
                    {oneClickActive &&
                    !grantCovers(tableChoice === "v1" ? TABLE_ADDRESS : tableChoice) ? (
                        <>
                            <span className="status">
                                ⚡ 1-click play is on, but your approval predates this table.
                                Approve once (passkey) to cover this table too.
                            </span>
                            <button disabled={!!busy} onClick={onEnableOneClick}>
                                {busy === "oneclick" ? "Check the wallet…" : "Re-approve 1-click"}
                            </button>
                        </>
                    ) : oneClickActive ? (
                        <>
                            <span className="status">
                                ⚡ <strong>1-click play is on</strong> — game moves go through without
                                popups (max {ONE_CLICK_CHIP_PER_DAY} CHIP/day, expires{" "}
                                {new Date(oneClickExpiry * 1000).toLocaleTimeString()}).
                            </span>
                            <button className="secondary" disabled={!!busy} onClick={onDisableOneClick}>
                                {busy === "oneclick" ? "…" : "Turn off"}
                            </button>
                        </>
                    ) : (
                        <>
                            <span className="status">
                                Tired of approving every move? <strong>1-click play</strong> asks for
                                one passkey approval, then bets/hits/stands run silently at this table. Scoped to
                                this table only, {ONE_CLICK_CHIP_PER_DAY} CHIP/day cap,{" "}
                                {ONE_CLICK_HOURS}h expiry, revocable anytime.
                            </span>
                            <button disabled={!!busy} onClick={onEnableOneClick}>
                                {busy === "oneclick" ? "Check the wallet…" : "⚡ Enable 1-click play"}
                            </button>
                        </>
                    )}
                </div>
            )}

            {tableChoice !== "v1" && address !== undefined || tableChoice !== "v1" ? (
                <V2Table
                    key={tableChoice}
                    table={tableChoice as `0x${string}`}
                    name={V2_TABLES.find((t) => t.address === tableChoice)?.name ?? "Community table"}
                    address={address}
                    isConnected={isConnected && !wrongNetwork}
                    oneClickActive={grantCovers(tableChoice as string)}
                    writeTx={(a) => writeTx(a as Parameters<typeof writeContractAsync>[0])}
                />
            ) : (
            <>
            <div className="panel">
                <div className="hand-title">
                    Dealer {dealerCards.length > 0 && `— ${dealerVal.total}${dealerVal.soft ? " (soft)" : ""}`}
                </div>
                <div className="cards">
                    {dealerCards.map((c, i) => <CardView key={i} card={c} />)}
                    {!gameOver && dealerCards.length === 1 && <CardView hidden />}
                    {dealerCards.length === 0 && <span className="status">no cards yet</span>}
                </div>

                <div className="hand-title" style={{marginTop: 16}}>
                    You {playerCards.length > 0 && `— ${playerVal.total}${playerVal.soft ? " (soft)" : ""}`}
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
