// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestChip} from "../src/TestChip.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {TableFactory} from "../src/TableFactory.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";

/// @notice Phase A testnet deployment: TableFactory + three variant tables, reusing
///         the live TestChip and DrandRandomnessProvider (requestRandomness is
///         permissionless, so no provider changes are needed).
///         Run with --skip-simulation on MegaETH (storage gas: docs/DEPLOYMENT.md).
contract DeployV2 is Script {
    address internal constant CHIP = 0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711;
    address internal constant PROVIDER = 0x801466769247D89B3d768C4Ad5B74D83466cD14b;

    function runTestnet() external {
        require(block.chainid == 6343, "not MegaETH testnet");
        require(PROVIDER.code.length > 0, "provider missing");

        vm.startBroadcast();
        TableFactory factory =
            new TableFactory(IERC20(CHIP), IRandomnessProvider(PROVIDER));

        // 1. Classic: S17, 3:2, double any two, no surrender (v1-equivalent rules).
        address classic = factory.createTable(
            BlackjackTableV2.Rules({
                dealerHitsSoft17: false,
                blackjackNum: 3,
                blackjackDen: 2,
                doubleRule: BlackjackTableV2.DoubleRule.ANY_TWO,
                lateSurrender: false
            }),
            1e18,
            1_000e18,
            5,
            msg.sender
        );

        // 2. Vegas-style: H17, 6:5, double hard 10-11 only, late surrender.
        address vegas = factory.createTable(
            BlackjackTableV2.Rules({
                dealerHitsSoft17: true,
                blackjackNum: 6,
                blackjackDen: 5,
                doubleRule: BlackjackTableV2.DoubleRule.TEN_TO_ELEVEN,
                lateSurrender: true
            }),
            1e18,
            1_000e18,
            5,
            msg.sender
        );

        // 3. Pro: S17, 3:2, double hard 9-11, late surrender, higher minimum.
        address pro = factory.createTable(
            BlackjackTableV2.Rules({
                dealerHitsSoft17: false,
                blackjackNum: 3,
                blackjackDen: 2,
                doubleRule: BlackjackTableV2.DoubleRule.NINE_TO_ELEVEN,
                lateSurrender: true
            }),
            10e18,
            1_000e18,
            5,
            msg.sender
        );
        vm.stopBroadcast();

        console.log("factory:", address(factory));
        console.log("classic:", classic);
        console.log("vegas:  ", vegas);
        console.log("pro:    ", pro);
        // Funding happens separately via cast (mint + approve + fundHouse per table)
        // to avoid MegaETH mini-block nonce races in batched broadcasts.
    }
}
