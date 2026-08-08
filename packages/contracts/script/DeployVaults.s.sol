// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {BankrollVault} from "../src/BankrollVault.sol";
import {TableFactory} from "../src/TableFactory.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";

interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

/// @notice LP-vault rollout, run with --skip-simulation --slow on MegaETH:
///         1. For each live CHIP table: pull the deployer-donated bankroll out,
///            re-supply it THROUGH a new BankrollVault (deployer = first LP),
///            then hand the table's TREASURY_ROLE to the vault exclusively.
///         2. New single-table factories for real testnet assets (USDm, WETH,
///            MEGA — addresses verified onchain + docs 2026-08-08), each with a
///            classic-rules table and a vault. WETH is seeded by wrapping ETH;
///            USDm/MEGA start empty and wait for their first LPs.
contract DeployVaults is Script {
    address internal constant PROVIDER = 0x801466769247D89B3d768C4Ad5B74D83466cD14b;
    address internal constant USDM = 0x15e9f2B0A747aC05c7446559306687085D161e5C;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant MEGA = 0xc903c68C1d389CEd76fEe0349067a4295828e6c2;

    address[3] internal CHIP_TABLES = [
        0x457e5eb30973af0654aE3f6b5E1ba62d5c97C1cF, // Classic
        0xe4eDc43D1cD0cC5370fAB275EcB1c50C1CC0b6Ee, // Vegas
        0xb414D2B3AAe5Da85813Ea3680895a457e0a08577 // Pro
    ];
    string[3] internal CHIP_NAMES = ["Classic", "Vegas", "Pro"];

    function _classicRules() internal pure returns (BlackjackTableV2.Rules memory) {
        return BlackjackTableV2.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: BlackjackTableV2.DoubleRule.ANY_TWO,
            lateSurrender: true
        });
    }

    function runTestnet() external {
        require(block.chainid == 6343, "not MegaETH testnet");
        vm.startBroadcast();

        // ---- 1. vaults for the live CHIP tables (bankroll migrates through them)
        for (uint256 i = 0; i < 3; i++) {
            BlackjackTableV2 t = BlackjackTableV2(CHIP_TABLES[i]);
            // Migrate the UNRESERVED bankroll only; funds reserved for any live
            // game stay in the table (they were deployer bankroll and accrue to
            // the deployer's first-LP shares either way).
            uint256 bankroll = t.availableLiquidity();
            t.withdrawHouseFunds(msg.sender, bankroll);

            BankrollVault vault = new BankrollVault(
                t,
                1 hours,
                string.concat("Blackjack ", CHIP_NAMES[i], " LP"),
                string.concat("bj", CHIP_NAMES[i])
            );
            t.chip().approve(address(vault), bankroll);
            vault.deposit(bankroll, msg.sender); // deployer is the first LP
            t.grantRole(t.TREASURY_ROLE(), address(vault));
            t.revokeRole(t.TREASURY_ROLE(), msg.sender); // vault is the ONLY treasury
            console.log(CHIP_NAMES[i], "vault:", address(vault));
        }

        // ---- 2. real-asset tables + vaults
        _assetTable(USDM, "USDm", 1e18, 100e18, 0);
        _assetTable(WETH, "ETH", 0.0005e18, 0.01e18, 0.25e18);
        _assetTable(MEGA, "MEGA", 1e18, 100e18, 0);

        vm.stopBroadcast();
    }

    function _assetTable(address token, string memory sym, uint256 min, uint256 max, uint256 seed)
        internal
    {
        TableFactory f = new TableFactory(IERC20(token), IRandomnessProvider(PROVIDER));
        BlackjackTableV2 t = BlackjackTableV2(f.createTable(_classicRules(), min, max, 5, msg.sender));
        BankrollVault vault = new BankrollVault(
            t, 1 hours, string.concat("Blackjack ", sym, " LP"), string.concat("bj", sym)
        );
        if (seed > 0 && token == WETH) {
            IWETH(WETH).deposit{value: seed}();
            IWETH(WETH).approve(address(vault), seed);
            vault.deposit(seed, msg.sender);
        }
        t.grantRole(t.TREASURY_ROLE(), address(vault));
        t.revokeRole(t.TREASURY_ROLE(), msg.sender);
        console.log(sym, "factory:", address(f));
        console.log(sym, "table:", address(t));
        console.log(sym, "vault:", address(vault));
    }
}
