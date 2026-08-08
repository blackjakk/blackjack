"use client";

import {useCallback, useEffect, useState} from "react";
import {usePublicClient, useReadContract} from "wagmi";
import type {Address} from "viem";
import {parseEther} from "viem";
import {bankrollVaultAbi, sharedBankrollVaultAbi, testChipAbi} from "@blackjack/config";
import {isSharedVault} from "../lib/config.ts";
import {fmt} from "./ui.tsx";

const POLL = {refetchInterval: 4000} as const;

type Call = {
    address: Address;
    abi: unknown;
    functionName: string;
    args?: readonly unknown[];
};
type WriteBatch = (calls: Call[]) => Promise<`0x${string}`>;
type WriteTx = (args: Call) => Promise<`0x${string}`>;

/**
 * LP panel for a BankrollVault (one table) or a SharedBankrollVault (one pool
 * backing every game of the asset): deposit (instant), exit via the delayed
 * queue (request -> 1h -> claim at claim-time price). Shared-pool deposits stay
 * idle in the vault, so the deposit batch chains a permissionless fundTable
 * push into `fundTarget` (the table being viewed) to put them to work.
 */
export function VaultPanel({
    vault,
    token,
    symbol,
    address,
    isConnected,
    writeTx,
    writeBatch,
    fundTarget,
}: {
    vault: Address;
    token: Address;
    symbol: string;
    address: Address | undefined;
    isConnected: boolean;
    writeTx: WriteTx;
    writeBatch: WriteBatch;
    fundTarget?: Address;
}) {
    const publicClient = usePublicClient();
    const shared = isSharedVault(vault);
    const v = {address: vault, abi: shared ? sharedBankrollVaultAbi : bankrollVaultAbi} as const;
    const erc20 = {address: token, abi: testChipAbi} as const;
    const zero = "0x0000000000000000000000000000000000000000" as const;

    const {data: totalAssets} = useReadContract({...v, functionName: "totalAssets", query: POLL});
    const {data: shares} = useReadContract({
        ...v,
        functionName: "balanceOf",
        args: [address ?? zero],
        query: {...POLL, enabled: isConnected},
    });
    const {data: positionValue} = useReadContract({
        ...v,
        functionName: "previewRedeem",
        args: [(shares as bigint | undefined) ?? 0n],
        query: {...POLL, enabled: isConnected && (shares as bigint | undefined) !== undefined},
    });
    const {data: exitReq} = useReadContract({
        ...v,
        functionName: "exitRequests",
        args: [address ?? zero],
        query: {...POLL, enabled: isConnected},
    });
    const {data: exitValue} = useReadContract({
        ...v,
        functionName: "previewRedeem",
        args: [(exitReq as readonly [bigint, bigint] | undefined)?.[0] ?? 0n],
        query: {
            ...POLL,
            enabled: isConnected && ((exitReq as readonly [bigint, bigint] | undefined)?.[0] ?? 0n) > 0n,
        },
    });
    const {data: walletBal} = useReadContract({
        ...erc20,
        functionName: "balanceOf",
        args: [address ?? zero],
        query: {...POLL, enabled: isConnected},
    });
    // Governance transparency: pending membership proposals (shared pools only).
    const {data: proposalsData} = useReadContract({
        ...v,
        functionName: "pendingProposals",
        query: {...POLL, enabled: shared},
    });
    const {data: memberTables} = useReadContract({
        ...v,
        functionName: "tables",
        query: {refetchInterval: 30_000, enabled: shared},
    });

    const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
    useEffect(() => {
        const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
        return () => clearInterval(t);
    }, []);

    const [busy, setBusy] = useState<string | null>(null);
    const [error, setError] = useState<string | null>(null);
    const run = useCallback(
        async (label: string, fn: () => Promise<`0x${string}` | null>) => {
            setBusy(label);
            setError(null);
            try {
                const hash = await fn();
                if (hash) await publicClient?.waitForTransactionReceipt({hash});
            } catch (err) {
                const m = err instanceof Error ? err.message : String(err);
                setError(
                    m.includes("WithdrawExceedsAvailable")
                        ? "The table's liquidity is currently reserved for live hands — claim again once they settle."
                        : m.split("\n")[0]!,
                );
            } finally {
                setBusy(null);
            }
        },
        [publicClient],
    );

    const [depositInput, setDepositInput] = useState("");
    const onDeposit = () =>
        run("deposit", async () => {
            const amount = parseEther(depositInput || "0");
            if (amount === 0n) return null;
            const allowance = (await publicClient!.readContract({
                ...erc20,
                functionName: "allowance",
                args: [address!, vault],
            })) as bigint;
            const calls: Call[] = [];
            if (allowance < amount) {
                calls.push({...erc20, functionName: "approve", args: [vault, amount]});
            }
            calls.push({...v, functionName: "deposit", args: [amount, address!]});
            if (shared && fundTarget) {
                calls.push({...v, functionName: "fundTable", args: [fundTarget, amount]});
            }
            setDepositInput("");
            return writeBatch(calls);
        });

    const onRequestExit = (pct: bigint) =>
        run(`exit${pct}`, async () => {
            const bal = (shares as bigint | undefined) ?? 0n;
            const amount = (bal * pct) / 100n;
            if (amount === 0n) return null;
            return writeTx({...v, functionName: "requestRedeem", args: [amount]});
        });

    const onClaim = () => run("claim", () => writeTx({...v, functionName: "claim", args: [address!]}));

    const pendingShares = (exitReq as readonly [bigint, bigint] | undefined)?.[0] ?? 0n;
    const claimableAt = Number((exitReq as readonly [bigint, bigint] | undefined)?.[1] ?? 0n);
    const matured = pendingShares > 0n && now >= claimableAt;
    const myShares = (shares as bigint | undefined) ?? 0n;

    return (
        <div className="panel">
            <div className="row">
                <div className="hand-title">
                    {shared ? `🏦 ${symbol} house pool — be the house` : "🏦 Bankroll vault — be the house"}
                </div>
                <span className="status">
                    TVL {fmt(totalAssets as bigint | undefined)} {symbol}
                </span>
            </div>
            <div className="status" style={{marginTop: 6}}>
                {shared
                    ? `Deposit ${symbol} for LP shares of the SHARED ${symbol} bankroll — one
                       pool backs ${(memberTables as readonly Address[] | undefined)?.length ?? "…"} ${symbol}
                       games, so wins and losses at any of them move the same share price.
                       Adding a game is a governance action: a MEGA bond is staked on the
                       proposal, a public timelock runs (48 h for novel code, 12 h for
                       factory-built tables whose bytecode provably matches the reviewed
                       engine), and per-game float caps bound what any one game could ever
                       cost the pool — with the bond slashed if a game fails to pay what it
                       reports. You always have time to exit first if you disagree; games
                       outside the pool run on their own isolated vault.`
                    : `Deposit ${symbol} for LP shares of this table's bankroll: every hand
                       the house wins raises your share value, every player win lowers it.`}{" "}
                Exits are a two-step queue (request → 1 h wait → claim at the then-current
                price) so nobody can dodge a loss they saw coming. Play money — unaudited.
            </div>
            {shared &&
                (() => {
                    const [pTables, pEtas] =
                        (proposalsData as readonly [readonly Address[], readonly bigint[]] | undefined) ?? [[], []];
                    if (pTables.length === 0) return null;
                    return pTables.map((t, i) => {
                        const eta = Number(pEtas[i] ?? 0n);
                        const ready = now >= eta;
                        return (
                            <div className="row" key={t} style={{marginTop: 8}}>
                                <span className="status">
                                    🗳️ Proposed new pool game {t.slice(0, 6)}…{t.slice(-4)} —{" "}
                                    {ready
                                        ? "timelock elapsed, anyone can activate"
                                        : `activatable in ${Math.floor((eta - now) / 3600)}h ${Math.floor(((eta - now) % 3600) / 60)}m (exit first if you disagree)`}
                                </span>
                                {ready && (
                                    <button
                                        disabled={!!busy}
                                        onClick={() =>
                                            run("activate", () =>
                                                writeTx({...v, functionName: "activateTable", args: [t]}),
                                            )
                                        }
                                    >
                                        {busy === "activate" ? "…" : "Activate"}
                                    </button>
                                )}
                            </div>
                        );
                    });
                })()}

            {isConnected && (
                <>
                    <div className="row" style={{marginTop: 10}}>
                        <span className="status">
                            Your position:{" "}
                            {myShares > 0n
                                ? `${fmt(positionValue as bigint | undefined)} ${symbol}`
                                : "none"}
                            {` · wallet ${fmt(walletBal as bigint | undefined)} ${symbol}`}
                        </span>
                        <span className="row" style={{gap: 6}}>
                            <input
                                value={depositInput}
                                onChange={(e) => setDepositInput(e.target.value)}
                                inputMode="decimal"
                                placeholder={symbol}
                                style={{width: 100}}
                                aria-label={`deposit amount in ${symbol}`}
                            />
                            <button disabled={!!busy} onClick={onDeposit}>
                                {busy === "deposit" ? "…" : "Deposit"}
                            </button>
                        </span>
                    </div>

                    {myShares > 0n && (
                        <div className="row" style={{marginTop: 8}}>
                            <span className="status">Exit (starts the 1 h clock):</span>
                            <span className="row" style={{gap: 6}}>
                                {[25n, 50n, 100n].map((p) => (
                                    <button
                                        key={p.toString()}
                                        className="secondary"
                                        disabled={!!busy}
                                        onClick={() => onRequestExit(p)}
                                    >
                                        {busy === `exit${p}` ? "…" : `${p}%`}
                                    </button>
                                ))}
                            </span>
                        </div>
                    )}

                    {pendingShares > 0n && (
                        <div className="row" style={{marginTop: 8}}>
                            <span className="status">
                                ⏳ Exit pending: ~{fmt(exitValue as bigint | undefined)} {symbol}
                                {matured
                                    ? " — matured, claim now (final amount = price at claim)"
                                    : ` — claimable in ${Math.max(0, claimableAt - now) > 3600 ? `${Math.floor((claimableAt - now) / 3600)}h ` : ""}${Math.floor((Math.max(0, claimableAt - now) % 3600) / 60)}m`}
                            </span>
                            <button
                                className={matured ? "pulse" : "secondary"}
                                disabled={!!busy || !matured}
                                onClick={onClaim}
                            >
                                {busy === "claim" ? "…" : "Claim"}
                            </button>
                        </div>
                    )}
                </>
            )}
            {error && <div className="error" style={{marginTop: 8}}>{error}</div>}
        </div>
    );
}
