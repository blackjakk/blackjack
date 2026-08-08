// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {BankrollVault} from "../src/BankrollVault.sol";

interface ILegacyVault {
    function balanceOf(address) external view returns (uint256);
    function maxRedeem(address) external view returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
}

/// @notice Replace the instant-exit v1 vaults with delayed-exit vaults (1h queue):
///         deployer redeems its v1 first-LP shares (clamped to unreserved
///         liquidity; any live-game slice is abandoned as play-money dust),
///         re-deposits through a fresh delayed vault, and the tables' treasury
///         role moves v1 vault -> v2 vault. Run with --skip-simulation --slow.
contract MigrateVaultsDelay is Script {
    struct Pair {
        address table;
        address legacyVault;
        string sym;
    }

    function _pairs() internal pure returns (Pair[6] memory p) {
        p[0] = Pair(0x457e5eb30973af0654aE3f6b5E1ba62d5c97C1cF, 0xF4f1726687BcE9C5285Bc9Ab6bacb0Dca9F2E65F, "Classic");
        p[1] = Pair(0xe4eDc43D1cD0cC5370fAB275EcB1c50C1CC0b6Ee, 0xC1D56cD890a84B2Bd433421C177b7C1f524A5de4, "Vegas");
        p[2] = Pair(0xb414D2B3AAe5Da85813Ea3680895a457e0a08577, 0xa8332EdB9999A300Acb1e35E8F4A313375aB97a8, "Pro");
        p[3] = Pair(0x700762a0DB39AA3Dc8a84260FCd0e7A52cbc4003, 0xee8f3d40060290e959f285a8BA866c4FAF28eA67, "USDm");
        p[4] = Pair(0x756595C7d4e3d2668700d0f3d72CDC377b66d116, 0x7686DEf9ac25dfE608e27A13c1678Cf9df19E21a, "ETH");
        p[5] = Pair(0x480F77B89B498DD995B72FE9672053836983D272, 0xb0FC29344A1AdeE8FbcE46a0B913F3CEa3698C29, "MEGA");
    }

    function runTestnet() external {
        require(block.chainid == 6343, "not MegaETH testnet");
        Pair[6] memory pairs = _pairs();
        vm.startBroadcast();
        for (uint256 i = 0; i < 6; i++) {
            BlackjackTableV2 t = BlackjackTableV2(pairs[i].table);
            ILegacyVault legacy = ILegacyVault(pairs[i].legacyVault);

            uint256 redeemable = legacy.maxRedeem(msg.sender);
            uint256 assets;
            if (redeemable > 0) {
                assets = legacy.redeem(redeemable, msg.sender, msg.sender);
            }

            BankrollVault v2 = new BankrollVault(
                t,
                1 hours,
                string.concat("Blackjack ", pairs[i].sym, " LP"),
                string.concat("bj", pairs[i].sym)
            );
            if (assets > 0) {
                t.chip().approve(address(v2), assets);
                v2.deposit(assets, msg.sender);
            }
            t.grantRole(t.TREASURY_ROLE(), address(v2));
            t.revokeRole(t.TREASURY_ROLE(), pairs[i].legacyVault);
            console.log(pairs[i].sym, "delayed vault:", address(v2));
        }
        vm.stopBroadcast();
    }
}
