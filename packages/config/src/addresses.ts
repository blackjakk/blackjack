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
 * Deployed contract addresses per chain id.
 *
 * Empty until a deployment is performed (see docs/DEPLOYMENT.md); record the
 * addresses printed by `forge script script/Deploy.s.sol --sig "runTestnet()"` here.
 * Local anvil deployments can be injected at runtime via environment variables
 * instead of being committed.
 */
export const DEPLOYMENTS: Partial<Record<number, BlackjackDeployment>> = {};
