import type {Address} from "viem";

/**
 * Preinstalled DrandOracleQuicknet verifier addresses (docs.megaeth.com/developer-docs/vrf,
 * confirmed live on testnet 2026-08-06).
 */
export const DRAND_ORACLE_QUICKNET: Record<number, Address> = {
    6343: "0x4e1673dcAA38136b5032F27ef93423162aF977Cc", // MegaETH testnet
    4326: "0x7a53a6eFA81c426838fcf4824E6e207923969b36", // MegaETH mainnet
};

export interface BlackjackDeployment {
    chip: Address;
    table: Address;
    randomnessProvider: Address;
    /** Block the deployment landed in — event queries start here. */
    deployBlock: bigint;
    /** Onchain chat room (TableChat), if deployed. */
    chat?: Address;
    chatDeployBlock?: bigint;
    /** Phase A (v2): permissionless TableFactory and its launch tables. */
    factory?: Address;
    v2Tables?: {name: string; address: Address}[];
    /** Split-capable V3 tables (extended ABI: split/outcome2/hand2). */
    v3Tables?: {name: string; address: Address}[];
    /** LP vaults (ERC-4626) per table, plus real-asset tables (own factories). */
    vaults?: {table: Address; vault: Address}[];
    assetTables?: {
        symbol: string;
        token: Address;
        factory: Address;
        table: Address;
        vault: Address;
    }[];
    /** Decentralization phase: OZ TimelockController holding every admin role. */
    timelock?: Address;
    /** Ownerless presence beacon (who's online), pinged by chat burner keys. */
    presence?: Address;
    presenceDeployBlock?: bigint;
    /** Phase D: shared multiplayer InfiniteBlackjack tables, one per asset. */
    infiniteTables?: {symbol: string; token: Address; address: Address}[];
    /**
     * Phase D: per-asset SHARED vaults (SharedBankrollVault) — one pool backing
     * every member game of that asset. Tables listed here override the per-table
     * `vaults` mapping.
     */
    sharedVaults?: {symbol: string; token: Address; vault: Address; tables: Address[]}[];
}

/**
 * Deployed contract addresses per chain id (see docs/DEPLOYMENT.md).
 * Local anvil deployments can be injected at runtime via environment variables
 * instead of being committed.
 *
 * MegaETH testnet deployment (2026-08-06, deployer 0x97eB…a476, Sourcify-verified):
 * NOTE: testnet state may be rolled back by network upgrades; redeploy if so.
 */
export const DEPLOYMENTS: Partial<Record<number, BlackjackDeployment>> = {
    6343: {
        chip: "0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711",
        table: "0x261ab01D3c6F06BccBb49380bD27cd9303A4dB2f",
        randomnessProvider: "0x801466769247D89B3d768C4Ad5B74D83466cD14b",
        deployBlock: 26317836n,
        chat: "0x9768a366EAA389fAc374D0736fee4Cd07D02e180",
        chatDeployBlock: 26320341n,
        // Decentralization (2026-08-08): all table/pool admin behind a 12 h
        // public timelock (deployer = sole proposer, open execution).
        timelock: "0xeD7d0351Fdc1aa7c5aE6395e393fcA43BE25d3f3",
        // Presence beacon (2026-08-08): ownerless, event-only pings.
        presence: "0xbfC42dee38778b40AA96CB07eA5DFb5b6f2b248E",
        presenceDeployBlock: 26523037n,
        // Provenance-recording factories (2026-08-08, isFromFactory) — deployments
        // are byte-identical to the reviewed engines, the tier-1 trust basis.
        factory: "0xA29cafeD124864D38dabFe8Fe803cdE61b111Fd0",
        v2Tables: [
            {name: "Classic (S17, 3:2)", address: "0x457e5eb30973af0654aE3f6b5E1ba62d5c97C1cF"},
            {name: "Vegas (H17, 6:5, surrender)", address: "0xe4eDc43D1cD0cC5370fAB275EcB1c50C1CC0b6Ee"},
            {name: "Pro (S17, 3:2, D9-11, surrender)", address: "0xb414D2B3AAe5Da85813Ea3680895a457e0a08577"},
        ],
        // Split rollout (2026-08-08): V3 engine (split pairs), factory 0xEF80…1a72.
        v3Tables: [
            {name: "Split (S17, 3:2, split, surrender)", address: "0x1d8DD0B8D825c939024582f31Dc512955187Dc2E"},
        ],
        // LP rollout (2026-08-08): delayed-exit vaults (1h queue) = sole treasuries.
        vaults: [
            {table: "0x1d8DD0B8D825c939024582f31Dc512955187Dc2E", vault: "0xa103a0B75b591d77f32b479bdaD2869dc7F222B2"},
            {table: "0x457e5eb30973af0654aE3f6b5E1ba62d5c97C1cF", vault: "0x87B20cb956d9fD3fEec2281163FFB80B7D43D3c7"},
            {table: "0xe4eDc43D1cD0cC5370fAB275EcB1c50C1CC0b6Ee", vault: "0x7cb6F0e70745507DdBa4b31Fe9CB8698473512A5"},
            {table: "0xb414D2B3AAe5Da85813Ea3680895a457e0a08577", vault: "0xb0a6AC3013e804031984f01c61313EfbcEa6faD2"},
            // (Asset classic tables live in sharedVaults below since Phase D.)
        ],
        // Real testnet assets (verified onchain + docs 2026-08-08). No faucets for
        // USDm/MEGA — those tables start empty and wait for their first LPs.
        assetTables: [
            {symbol: "USDm", token: "0x15e9f2B0A747aC05c7446559306687085D161e5C", factory: "0x83fa0c3D296c325773C0bB82551735aD6aEbe60B", table: "0x700762a0DB39AA3Dc8a84260FCd0e7A52cbc4003", vault: "0x7B10E47a92a0D571898eC54e9f677f2bC82495fd"},
            {symbol: "ETH", token: "0x4200000000000000000000000000000000000006", factory: "0xCB7670742A14Fbc2DD76b1f47c5D6b9aA8d900De", table: "0x756595C7d4e3d2668700d0f3d72CDC377b66d116", vault: "0x70eE7F053cB6a203326Ff4a014e6586B3B3E4dcF"},
            {symbol: "MEGA", token: "0xc903c68C1d389CEd76fEe0349067a4295828e6c2", factory: "0x57C816E3a544B2D74A6f86119e25078287d6D368", table: "0x480F77B89B498DD995B72FE9672053836983D272", vault: "0x85258F50d27d1F171a6564081fd62ec9eeB19D8e"},
        ],
        // Phase D (2026-08-08): shared multiplayer tables, one per asset, all
        // Sourcify exact_match. One drand beacon pair serves every player in a round.
        infiniteTables: [
            {symbol: "CHIP", token: "0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711", address: "0x9103B9723e5BffbBcD70Bfb0785AADF64E2D0E35"},
            {symbol: "USDm", token: "0x15e9f2B0A747aC05c7446559306687085D161e5C", address: "0x70D3f02A850c197Bc339ba9F8530aBcCb4217Aac"},
            {symbol: "ETH", token: "0x4200000000000000000000000000000000000006", address: "0xb25Fd4A3dEFF1926e6B17B1fF8Eb2beBDd807286"},
            {symbol: "MEGA", token: "0xc903c68C1d389CEd76fEe0349067a4295828e6c2", address: "0x6EF4dEf337D24631efEe0e0ffb145Ef835430644"},
        ],
        // Phase D pools, third iteration (2026-08-08, supersedes same-day v1/v2):
        // membership is a MEGA-bonded, float-capped, timelocked governance
        // proposal (48 h novel code / 12 h factory-provenanced), objectively
        // slashable via claimDefault; LPs can always exit through the 1 h queue
        // before a new game touches the pool. Unapproved games run on their own
        // per-table BankrollVault instead.
        sharedVaults: [
            {symbol: "CHIP", token: "0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711", vault: "0xbf0064b3a503e62d447002210aF1e60150301f25", tables: ["0x9103B9723e5BffbBcD70Bfb0785AADF64E2D0E35"]},
            {symbol: "USDm", token: "0x15e9f2B0A747aC05c7446559306687085D161e5C", vault: "0x7B10E47a92a0D571898eC54e9f677f2bC82495fd", tables: ["0x70D3f02A850c197Bc339ba9F8530aBcCb4217Aac", "0x700762a0DB39AA3Dc8a84260FCd0e7A52cbc4003"]},
            {symbol: "ETH", token: "0x4200000000000000000000000000000000000006", vault: "0x70eE7F053cB6a203326Ff4a014e6586B3B3E4dcF", tables: ["0xb25Fd4A3dEFF1926e6B17B1fF8Eb2beBDd807286", "0x756595C7d4e3d2668700d0f3d72CDC377b66d116"]},
            {symbol: "MEGA", token: "0xc903c68C1d389CEd76fEe0349067a4295828e6c2", vault: "0x85258F50d27d1F171a6564081fd62ec9eeB19D8e", tables: ["0x6EF4dEf337D24631efEe0e0ffb145Ef835430644", "0x480F77B89B498DD995B72FE9672053836983D272"]},
        ],
    },
};
