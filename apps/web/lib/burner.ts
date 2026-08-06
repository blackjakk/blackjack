import {
    createPublicClient,
    createWalletClient,
    http,
    type Address,
    type Hash,
    type PublicClient,
    type WalletClient,
    type Account,
} from "viem";
import {generatePrivateKey, privateKeyToAccount} from "viem/accounts";
import {activeChain} from "./config.ts";

/**
 * Burner key for chat: generated once per browser and kept in localStorage so chat
 * messages send instantly without wallet popups. It should only ever hold a dust
 * amount of TESTNET ETH for gas — never send real value to it. Clearing site data
 * discards the key (and the chat identity with it).
 */
const STORAGE_KEY = "blackjack-chat-burner-key";

export function getBurnerAccount(): Account {
    let pk = localStorage.getItem(STORAGE_KEY) as `0x${string}` | null;
    if (!pk || !/^0x[0-9a-fA-F]{64}$/.test(pk)) {
        pk = generatePrivateKey();
        localStorage.setItem(STORAGE_KEY, pk);
    }
    return privateKeyToAccount(pk);
}

let clients: {pub: PublicClient; wallet: WalletClient; account: Account} | null = null;

export function burnerClients() {
    if (!clients) {
        const account = getBurnerAccount();
        clients = {
            account,
            // MegaETH mini-blocks land in ~10ms; poll receipts fast so chat feels live.
            pub: createPublicClient({
                chain: activeChain,
                transport: http(),
                pollingInterval: 250,
            }),
            wallet: createWalletClient({account, chain: activeChain, transport: http()}),
        };
    }
    return clients;
}

/** Serialize burner transactions so rapid sends can't race on the nonce. */
let queue: Promise<unknown> = Promise.resolve();

export function burnerWrite(args: {
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
}): Promise<Hash> {
    const run = async (): Promise<Hash> => {
        const {pub, wallet, account} = burnerClients();
        // simulateContract estimates via the remote RPC (MegaETH storage gas included).
        const {request} = await pub.simulateContract({
            ...args,
            account,
            chain: activeChain,
        } as never);
        const hash = await wallet.writeContract(request as never);
        await pub.waitForTransactionReceipt({hash});
        return hash;
    };
    const next = queue.then(run, run);
    queue = next.catch(() => {});
    return next;
}
