"use client";

import {useCallback, useEffect, useMemo, useRef, useState} from "react";
import {useAccount, useSendTransaction} from "wagmi";
import {formatEther, parseEther, type Address} from "viem";
import {tableChatAbi, megaethTestnet, DEPLOYMENTS} from "@blackjack/config";
import {burnerClients, burnerWrite} from "../lib/burner.ts";

const live = DEPLOYMENTS[megaethTestnet.id];
const CHAT_ADDRESS = (process.env.NEXT_PUBLIC_CHAT_ADDRESS ?? live?.chat ?? "") as Address;
const CHAT_DEPLOY_BLOCK = BigInt(
    process.env.NEXT_PUBLIC_CHAT_DEPLOY_BLOCK ?? String(live?.chatDeployBlock ?? 0n),
);

const QUICK_EMOJI = ["👍", "❤️", "😂", "🔥", "🎰", "♠️"];
const QUICK_GIFS = [
    "https://media.giphy.com/media/3o7aCSPqXE5C6T8tBC/giphy.gif",
    "https://media.giphy.com/media/xT9IgIc0lryrxvqVGM/giphy.gif",
    "https://media.giphy.com/media/26uf2YTgF5upXUTm0/giphy.gif",
    "https://media.giphy.com/media/l0HlHFRbmaZtBRhXG/giphy.gif",
    "https://media.giphy.com/media/QBd2kLB5qDmysEXre9/giphy.gif",
];
const GIF_HOST_ALLOWLIST = /^https:\/\/([a-z0-9-]+\.)*(tenor\.com|giphy\.com|imgur\.com)\/[^\s]+$/i;

interface Msg {
    id: bigint;
    author: Address;
    replyTo: bigint;
    kind: number; // 0 text, 1 gif
    content: string;
    timestamp: number;
    edited: boolean;
    deleted: boolean;
}

interface ChatStore {
    messages: Map<string, Msg>;
    reactions: Map<string, Map<string, Set<string>>>; // msgId -> emoji -> reactor set
    nicknames: Map<string, string>;
}

function avatarColor(addr: string): string {
    let h = 0;
    for (const c of addr.toLowerCase()) h = (h * 31 + c.charCodeAt(0)) >>> 0;
    return `hsl(${h % 360} 55% 45%)`;
}

function shortAddr(a: string): string {
    return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function Chat() {
    const {address: mainWallet, isConnected} = useAccount();
    const {sendTransactionAsync} = useSendTransaction();

    const [burnerAddr, setBurnerAddr] = useState<Address | null>(null);
    const [burnerBalance, setBurnerBalance] = useState<bigint | null>(null);
    const [tick, setTick] = useState(0);
    const [text, setText] = useState("");
    const [gifMode, setGifMode] = useState(false);
    const [replyTo, setReplyTo] = useState<Msg | null>(null);
    const [editing, setEditing] = useState<Msg | null>(null);
    const [busy, setBusy] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [nickInput, setNickInput] = useState("");
    const [showNick, setShowNick] = useState(false);
    const [reactFor, setReactFor] = useState<string | null>(null);
    const [muted, setMuted] = useState<Set<string>>(new Set());

    const store = useRef<ChatStore>({
        messages: new Map(),
        reactions: new Map(),
        nicknames: new Map(),
    });
    const lastBlock = useRef<bigint>(0n);
    const listRef = useRef<HTMLDivElement>(null);

    // ---------------------------------------------------------------- burner init (client only)

    useEffect(() => {
        const {account} = burnerClients();
        setBurnerAddr(account.address as Address);
        setMuted(new Set(JSON.parse(localStorage.getItem("chat-muted") ?? "[]")));
    }, []);

    useEffect(() => {
        if (!burnerAddr) return;
        const {pub} = burnerClients();
        const poll = () => pub.getBalance({address: burnerAddr}).then(setBurnerBalance, () => {});
        poll();
        const t = setInterval(poll, 5000);
        return () => clearInterval(t);
    }, [burnerAddr]);

    // ---------------------------------------------------------------- log ingestion

    const applyLogs = useCallback((logs: {eventName?: string; args?: never; blockNumber?: bigint}[]) => {
        const s = store.current;
        for (const log of logs) {
            const a = log.args as unknown as Record<string, unknown>;
            switch (log.eventName) {
                case "MessageSent": {
                    const id = a.id as bigint;
                    s.messages.set(id.toString(), {
                        id,
                        author: a.author as Address,
                        replyTo: a.replyTo as bigint,
                        kind: Number(a.kind),
                        content: a.content as string,
                        timestamp: Number(a.timestamp),
                        edited: false,
                        deleted: false,
                    });
                    break;
                }
                case "MessageEdited": {
                    const m = s.messages.get((a.id as bigint).toString());
                    if (m) {
                        m.content = a.content as string;
                        m.edited = true;
                    }
                    break;
                }
                case "MessageDeleted": {
                    const m = s.messages.get((a.id as bigint).toString());
                    if (m) m.deleted = true;
                    break;
                }
                case "ReactionToggled": {
                    const id = (a.id as bigint).toString();
                    const emoji = a.emoji as string;
                    const reactor = (a.reactor as string).toLowerCase();
                    if (!s.reactions.has(id)) s.reactions.set(id, new Map());
                    const byEmoji = s.reactions.get(id)!;
                    if (!byEmoji.has(emoji)) byEmoji.set(emoji, new Set());
                    if (a.added) byEmoji.get(emoji)!.add(reactor);
                    else byEmoji.get(emoji)!.delete(reactor);
                    break;
                }
                case "NicknameSet":
                    s.nicknames.set((a.user as string).toLowerCase(), a.name as string);
                    break;
            }
            if (log.blockNumber && log.blockNumber > lastBlock.current) {
                lastBlock.current = log.blockNumber;
            }
        }
        if (logs.length > 0) setTick((t) => t + 1);
    }, []);

    useEffect(() => {
        if (!CHAT_ADDRESS || CHAT_DEPLOY_BLOCK === 0n) return;
        const {pub} = burnerClients();
        let stopped = false;

        const fetchRange = async (from: bigint, to: bigint | "latest") => {
            const logs = await pub.getContractEvents({
                address: CHAT_ADDRESS,
                abi: tableChatAbi,
                fromBlock: from,
                toBlock: to,
            });
            if (!stopped) applyLogs(logs as never);
        };

        (async () => {
            try {
                // Initial history, chunked so RPC log-range limits can't bite.
                const latest = await pub.getBlockNumber();
                const CHUNK = 100_000n;
                for (let from = CHAT_DEPLOY_BLOCK; from <= latest; from += CHUNK) {
                    const to = from + CHUNK - 1n < latest ? from + CHUNK - 1n : latest;
                    await fetchRange(from, to);
                }
                lastBlock.current = lastBlock.current > latest ? lastBlock.current : latest;
            } catch (e) {
                setError(`history load failed: ${e instanceof Error ? e.message.split("\n")[0] : e}`);
            }
        })();

        const t = setInterval(async () => {
            try {
                await fetchRange(lastBlock.current + 1n, "latest");
            } catch {
                /* transient RPC hiccup; next poll retries */
            }
        }, 1500);
        return () => {
            stopped = true;
            clearInterval(t);
        };
    }, [applyLogs]);

    // ---------------------------------------------------------------- derived

    const messages = useMemo(() => {
        void tick;
        return [...store.current.messages.values()]
            .filter((m) => !muted.has(m.author.toLowerCase()))
            .sort((a, b) => (a.id < b.id ? -1 : 1));
    }, [tick, muted]);

    const nameOf = useCallback(
        (addr: string) => store.current.nicknames.get(addr.toLowerCase()) || shortAddr(addr),
        [],
    );

    useEffect(() => {
        const el = listRef.current;
        if (el && el.scrollHeight - el.scrollTop - el.clientHeight < 240) {
            el.scrollTop = el.scrollHeight;
        }
    }, [messages.length]);

    const funded = burnerBalance !== null && burnerBalance > 0n;

    // ---------------------------------------------------------------- actions

    const act = useCallback(async (label: string, fn: () => Promise<unknown>) => {
        setBusy(true);
        setError(null);
        try {
            await fn();
        } catch (e) {
            const msg = e instanceof Error ? e.message.split("\n")[0]! : String(e);
            setError(`${label}: ${msg.slice(0, 160)}`);
        } finally {
            setBusy(false);
        }
    }, []);

    const onSend = () => {
        const content = text.trim();
        if (!content) return;
        if (gifMode && !GIF_HOST_ALLOWLIST.test(content)) {
            setError("GIF mode expects a direct https URL from tenor/giphy/imgur");
            return;
        }
        void act("send", async () => {
            if (editing) {
                await burnerWrite({
                    address: CHAT_ADDRESS, abi: tableChatAbi,
                    functionName: "editMessage", args: [editing.id, content],
                });
                setEditing(null);
            } else {
                await burnerWrite({
                    address: CHAT_ADDRESS, abi: tableChatAbi,
                    functionName: "sendMessage",
                    args: [gifMode ? 1 : 0, content, replyTo?.id ?? 0n],
                });
                setReplyTo(null);
            }
            setText("");
            setGifMode(false);
        });
    };

    const sendGifUrl = (url: string) =>
        act("gif", () =>
            burnerWrite({
                address: CHAT_ADDRESS, abi: tableChatAbi,
                functionName: "sendMessage", args: [1, url, replyTo?.id ?? 0n],
            }).then(() => setReplyTo(null)),
        );

    const onReact = (m: Msg, emoji: string) => {
        setReactFor(null);
        void act("react", () =>
            burnerWrite({
                address: CHAT_ADDRESS, abi: tableChatAbi,
                functionName: "toggleReaction", args: [m.id, emoji],
            }),
        );
    };

    const onDelete = (m: Msg) =>
        act("delete", () =>
            burnerWrite({
                address: CHAT_ADDRESS, abi: tableChatAbi,
                functionName: "deleteMessage", args: [m.id],
            }),
        );

    const onSaveNick = () =>
        act("nickname", () =>
            burnerWrite({
                address: CHAT_ADDRESS, abi: tableChatAbi,
                functionName: "setNickname", args: [nickInput.trim().slice(0, 32)],
            }).then(() => setShowNick(false)),
        );

    const onFundBurner = () =>
        act("fund", async () => {
            if (!burnerAddr) return;
            await sendTransactionAsync({to: burnerAddr, value: parseEther("0.0005")});
        });

    const toggleMute = (addr: string) => {
        const next = new Set(muted);
        const key = addr.toLowerCase();
        if (next.has(key)) next.delete(key);
        else next.add(key);
        setMuted(next);
        localStorage.setItem("chat-muted", JSON.stringify([...next]));
    };

    // ---------------------------------------------------------------- render

    if (!CHAT_ADDRESS) return null;
    const mine = burnerAddr?.toLowerCase();

    return (
        <div className="panel chat">
            <div className="chat-header">
                <div>
                    <strong>♠ Table chat</strong>{" "}
                    <span className="status">fully onchain · public & permanent</span>
                </div>
                {burnerAddr && (
                    <button className="secondary tiny" onClick={() => {
                        setShowNick(!showNick);
                        setNickInput(store.current.nicknames.get(mine!) ?? "");
                    }}>
                        {nameOf(burnerAddr)} ✎
                    </button>
                )}
            </div>

            {showNick && (
                <div className="chat-nick">
                    <input
                        value={nickInput}
                        maxLength={32}
                        placeholder="nickname"
                        onChange={(e) => setNickInput(e.target.value)}
                    />
                    <button className="tiny" disabled={busy || !funded} onClick={onSaveNick}>Save</button>
                </div>
            )}

            {burnerAddr && !funded && (
                <div className="chat-fund">
                    Chat sends from a burner key ({shortAddr(burnerAddr)}) — no popups, testnet-gas
                    only. Fund it once:{" "}
                    {isConnected && mainWallet ? (
                        <button className="tiny" disabled={busy} onClick={onFundBurner}>
                            Send 0.0005 ETH from wallet
                        </button>
                    ) : (
                        <span>connect a wallet above, or send any dust of testnet ETH to it.</span>
                    )}
                </div>
            )}

            <div className="chat-list" ref={listRef}>
                {messages.length === 0 && (
                    <div className="status" style={{padding: 16}}>
                        No messages yet — say gm ♠
                    </div>
                )}
                {messages.map((m) => {
                    const isMine = m.author.toLowerCase() === mine;
                    const parent = m.replyTo !== 0n
                        ? store.current.messages.get(m.replyTo.toString())
                        : undefined;
                    const reactions = store.current.reactions.get(m.id.toString());
                    return (
                        <div key={m.id.toString()} className={`msg${isMine ? " mine" : ""}`}>
                            <div className="avatar" style={{background: avatarColor(m.author)}}>
                                {nameOf(m.author).replace("0x", "").slice(0, 2).toUpperCase()}
                            </div>
                            <div className="msg-body">
                                <div className="msg-meta">
                                    <span className="msg-author">{nameOf(m.author)}</span>
                                    <span className="msg-time">
                                        {new Date(m.timestamp * 1000).toLocaleTimeString([], {
                                            hour: "2-digit", minute: "2-digit",
                                        })}
                                        {m.edited && !m.deleted ? " · edited" : ""}
                                    </span>
                                </div>
                                {parent && (
                                    <div className="msg-quote">
                                        ↩ {nameOf(parent.author)}:{" "}
                                        {parent.deleted ? "deleted message" : parent.content.slice(0, 80)}
                                    </div>
                                )}
                                {m.deleted ? (
                                    <div className="msg-content deleted">message deleted</div>
                                ) : m.kind === 1 && GIF_HOST_ALLOWLIST.test(m.content) ? (
                                    // eslint-disable-next-line @next/next/no-img-element
                                    <img className="msg-gif" src={m.content} alt="GIF" loading="lazy" />
                                ) : (
                                    <div className="msg-content">{m.content}</div>
                                )}
                                <div className="msg-reactions">
                                    {reactions &&
                                        [...reactions.entries()]
                                            .filter(([, who]) => who.size > 0)
                                            .map(([emoji, who]) => (
                                                <button
                                                    key={emoji}
                                                    className={`chip${mine && who.has(mine) ? " active" : ""}`}
                                                    disabled={!funded || busy}
                                                    onClick={() => onReact(m, emoji)}
                                                >
                                                    {emoji} {who.size}
                                                </button>
                                            ))}
                                    {!m.deleted && (
                                        <span className="msg-tools">
                                            <button className="ghost" disabled={!funded}
                                                onClick={() => setReactFor(
                                                    reactFor === m.id.toString() ? null : m.id.toString(),
                                                )}>
                                                ☺+
                                            </button>
                                            <button className="ghost" onClick={() => {
                                                setReplyTo(m);
                                                setEditing(null);
                                            }}>
                                                ↩
                                            </button>
                                            {isMine && m.kind === 0 && (
                                                <button className="ghost" onClick={() => {
                                                    setEditing(m);
                                                    setReplyTo(null);
                                                    setText(m.content);
                                                    setGifMode(false);
                                                }}>
                                                    ✎
                                                </button>
                                            )}
                                            {isMine && (
                                                <button className="ghost" disabled={busy}
                                                    onClick={() => void onDelete(m)}>
                                                    🗑
                                                </button>
                                            )}
                                            {!isMine && (
                                                <button className="ghost" title="hide this address locally"
                                                    onClick={() => toggleMute(m.author)}>
                                                    🔇
                                                </button>
                                            )}
                                        </span>
                                    )}
                                </div>
                                {reactFor === m.id.toString() && (
                                    <div className="emoji-tray">
                                        {QUICK_EMOJI.map((e) => (
                                            <button key={e} className="ghost" onClick={() => onReact(m, e)}>
                                                {e}
                                            </button>
                                        ))}
                                    </div>
                                )}
                            </div>
                        </div>
                    );
                })}
            </div>

            {(replyTo || editing) && (
                <div className="chat-context">
                    {editing
                        ? `editing your message`
                        : `replying to ${nameOf(replyTo!.author)}: ${replyTo!.content.slice(0, 60)}`}
                    <button className="ghost" onClick={() => {
                        setReplyTo(null);
                        setEditing(null);
                        setText("");
                    }}>
                        ✕
                    </button>
                </div>
            )}

            {gifMode && !editing && (
                <div className="gif-tray">
                    {QUICK_GIFS.map((u) => (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img key={u} src={u} alt="quick gif" loading="lazy"
                            onClick={() => !busy && funded && void sendGifUrl(u)} />
                    ))}
                </div>
            )}

            <div className="chat-composer">
                <button className={`secondary tiny${gifMode ? " active-mode" : ""}`}
                    disabled={!!editing}
                    onClick={() => setGifMode(!gifMode)} title="send a GIF">
                    GIF
                </button>
                <input
                    value={text}
                    maxLength={600}
                    placeholder={
                        !funded
                            ? "fund the burner key to chat"
                            : gifMode
                              ? "paste a tenor/giphy/imgur GIF url…"
                              : editing
                                ? "edit your message…"
                                : "message the table…"
                    }
                    disabled={!funded}
                    onChange={(e) => setText(e.target.value)}
                    onKeyDown={(e) => e.key === "Enter" && !busy && onSend()}
                />
                <button disabled={!funded || busy || !text.trim()} onClick={onSend}>
                    {busy ? "…" : editing ? "Save" : "Send"}
                </button>
            </div>
            {error && <div className="error" style={{marginTop: 6}}>{error}</div>}
            <div className="status" style={{marginTop: 8, fontSize: 12}}>
                Every message is a MegaETH testnet transaction from your burner key — public,
                permanent, uncensorable. 2s cooldown between messages. Don&apos;t post anything
                private. 🔇 hides an address on this device only.
            </div>
        </div>
    );
}
