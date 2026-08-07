"use client";

import {useCallback, useEffect, useMemo, useState} from "react";
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
import {
    TABLE_ADDRESS,
    CHIP_ADDRESS,
    PROVIDER_ADDRESS,
    PROVIDER_KIND,
    GAS_FAUCET_URL,
    activeChain,
    isConfigured,
    txUrl,
} from "../lib/config.ts";

const POLL = {refetchInterval: 1500} as const;

function CardView({card, hidden}: {card?: Card; hidden?: boolean}) {
    if (hidden || !card) return <div className="card back">?</div>;
    const red = card.suit === 1 || card.suit === 2;
    return <div className={`card${red ? " red" : ""}`}>{card.label}</div>;
}

function fmt(x: bigint | undefined): string {
    return x === undefined ? "…" : Number(formatEther(x)).toLocaleString();
}

export default function Page() {
    const {address, isConnected, chainId: walletChainId, connector: activeConnector} = useAccount();
    const {connect, connectors, error: connectError, isPending: connecting, reset: resetConnect} = useConnect();
    const {disconnect} = useDisconnect();
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
    const writeTx = useCallback(
        (args: Parameters<typeof writeContractAsync>[0]) =>
            writeContractAsync(
                liveConnector ? ({...args, connector: liveConnector} as typeof args) : args,
            ),
        [writeContractAsync, liveConnector],
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
        async (label: string, fn: () => Promise<`0x${string}` | null>) => {
            setBusy(label);
            setError(null);
            try {
                const hash = await fn();
                if (hash) {
                    setLastTx(hash);
                    await publicClient?.waitForTransactionReceipt({hash});
                }
            } catch (err) {
                setError(err instanceof Error ? err.message.split("\n")[0]! : String(err));
            } finally {
                setBusy(null);
            }
        },
        [publicClient],
    );

    const onFaucet = () => run("faucet", () => writeTx({...chip, functionName: "faucet"}));

    const onBet = () =>
        run("bet", async () => {
            const wager = parseEther(wagerInput || "0");
            if ((allowance ?? 0n) < wager) {
                const approveHash = await writeTx({
                    ...chip, functionName: "approve", args: [TABLE_ADDRESS, wager * 100n],
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
                    ...chip, functionName: "approve", args: [TABLE_ADDRESS, wager * 100n],
                });
                await publicClient?.waitForTransactionReceipt({hash: approveHash});
            }
            return writeTx({...table, functionName: "double"});
        });

    /** Anyone may submit the public beacon; here the player's own wallet does it. */
    const onSubmitBeacon = () =>
        run("beacon", async () => {
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
        });

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
                <h1>♠ MegaETH Blackjack <span className="status">(testnet)</span></h1>
                {isConnected ? (
                    <div className="row" style={{gap: 8}}>
                        <button className="secondary addr" title="Copy full address" onClick={copyAddress}>
                            {copied ? "✓ copied" : <>{address?.slice(0, 6)}…{address?.slice(-4)} ⧉</>}
                        </button>
                        <button className="secondary" onClick={() => disconnect()}>Disconnect</button>
                    </div>
                ) : (
                    <button onClick={() => {
                        resetConnect();
                        setWalletMenu(true);
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
                                disabled={connecting}
                                onClick={() => connect({connector: mossConnector})}
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
                                disabled={connecting}
                                onClick={() => connect({connector: c})}
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

                        {connecting && <div className="status">Waiting for the wallet — check for a popup…</div>}
                        {connectError && (
                            <div className="error">{connectError.message.split("\n")[0]}</div>
                        )}
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

            {isConnected && (
                <div className="panel row">
                    <span className="status">Need play chips? Free faucet, 1000 CHIP / hour.</span>
                    <button className="secondary" disabled={!!busy} onClick={onFaucet}>
                        {busy === "faucet" ? "Claiming…" : "Claim faucet chips"}
                    </button>
                </div>
            )}

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
                                🎲 waiting for verifiable randomness
                                {PROVIDER_KIND === "drand" && drandRound
                                    ? drandReady
                                        ? " — beacon published, submit it:"
                                        : ` — drand round ${drandRound} publishes in ~${Math.max(0, Number(drandPublishTime(BigInt(drandRound))) - now)}s`
                                    : "…"}
                            </span>
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

            <Chat />

            <div className="panel status">
                Fully onchain: cards come from committed randomness (drand quicknet via MegaETH&apos;s
                preinstalled verifier), settlement is enforced by the BlackjackTable contract, and this
                page only reads chain state — there is no game server. Rules: European no-hole-card,
                dealer stands on all 17s, blackjack pays 3:2, double on first two cards.
            </div>
        </main>
    );
}
