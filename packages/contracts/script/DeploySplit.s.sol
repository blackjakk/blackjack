// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {BlackjackTableV3} from "../src/BlackjackTableV3.sol";
import {BankrollVault} from "../src/BankrollVault.sol";
import {TableFactoryV3} from "../src/TableFactoryV3.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";

interface IMintable {
    function mint(address, uint256) external;
}

/// @notice Split-capable table (V3 engine) + delayed-exit vault, CHIP-denominated.
///         Run with --skip-simulation --slow on MegaETH testnet.
contract DeploySplit is Script {
    address internal constant CHIP = 0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711;
    address internal constant PROVIDER = 0x801466769247D89B3d768C4Ad5B74D83466cD14b;

    function runTestnet() external {
        require(block.chainid == 6343, "not MegaETH testnet");
        vm.startBroadcast();
        TableFactoryV3 f = new TableFactoryV3(IERC20(CHIP), IRandomnessProvider(PROVIDER));
        BlackjackTableV3 t = BlackjackTableV3(
            f.createTable(
                BlackjackTableV3.Rules({
                    dealerHitsSoft17: false,
                    blackjackNum: 3,
                    blackjackDen: 2,
                    doubleRule: BlackjackTableV3.DoubleRule.ANY_TWO,
                    lateSurrender: true
                }),
                1e18,
                1_000e18,
                5,
                msg.sender
            )
        );
        // The vault's constructor param is typed as the V2 table; V3 exposes the
        // identical treasury/accounting surface.
        BankrollVault vault = new BankrollVault(
            BlackjackTableV2(address(t)), 1 hours, "Blackjack Split LP", "bjSplit"
        );
        IMintable(CHIP).mint(msg.sender, 200_000e18);
        IERC20(CHIP).approve(address(vault), 200_000e18);
        vault.deposit(200_000e18, msg.sender);
        t.grantRole(t.TREASURY_ROLE(), address(vault));
        t.revokeRole(t.TREASURY_ROLE(), msg.sender);
        console.log("v3 factory:", address(f));
        console.log("split table:", address(t));
        console.log("split vault:", address(vault));
    }
}
