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
    },
};
