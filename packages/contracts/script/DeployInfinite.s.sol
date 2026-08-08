// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InfiniteBlackjack} from "../src/InfiniteBlackjack.sol";
import {SharedBankrollVault} from "../src/SharedBankrollVault.sol";
import {IBankrollTable} from "../src/interfaces/IBankrollTable.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {BankrollVault} from "../src/BankrollVault.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";

interface IMintable {
    function mint(address, uint256) external;
}

/// @notice Phase D rollout: one InfiniteBlackjack table per asset + one SHARED
///         per-asset vault (hp*) that backs every game of that asset.
///         - CHIP pool seeds 200k fresh CHIP for its infinite table (legacy CHIP
///           per-table vaults keep their tables; LPs migrate self-serve).
///         - USDm/MEGA classic tables re-point to the shared pools (their legacy
///           vaults hold ZERO LP shares — verified onchain before running).
///         - bjETH's sole LP is the deployer: this script only STARTS its delayed
///           exit; FinishEthMigration completes the move an hour later.
///         Run with --skip-simulation --slow on MegaETH testnet.
contract DeployInfinite is Script {
    address internal constant CHIP = 0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711;
    address internal constant USDM = 0x15e9f2B0A747aC05c7446559306687085D161e5C;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant MEGA = 0xc903c68C1d389CEd76fEe0349067a4295828e6c2;
    address internal constant PROVIDER = 0x801466769247D89B3d768C4Ad5B74D83466cD14b;

    address internal constant USDM_TABLE = 0x700762a0DB39AA3Dc8a84260FCd0e7A52cbc4003;
    address internal constant MEGA_TABLE = 0x480F77B89B498DD995B72FE9672053836983D272;
    address internal constant USDM_LEGACY_VAULT = 0x196A8Fd97409c1e1e194F05BB5e0d6D00232e20D;
    address internal constant MEGA_LEGACY_VAULT = 0xf853bEda69B48Dd6Cb5A84Fa64f00e503bcE7F26;
    address internal constant ETH_LEGACY_VAULT = 0xB3A0E5faec83091252da443E65E28C855440ef2c;

    uint64 internal constant BET_WINDOW = 45;
    uint64 internal constant ACT_WINDOW = 40;
    uint64 internal constant EXIT_DELAY = 1 hours;

    function _rules() internal pure returns (InfiniteBlackjack.Rules memory) {
        return InfiniteBlackjack.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: InfiniteBlackjack.DoubleRule.ANY_TWO,
            lateSurrender: true
        });
    }

    function _deploySet(
        address token,
        uint256 minW,
        uint256 maxW,
        string memory name,
        string memory symbol
    ) internal returns (InfiniteBlackjack tbl, SharedBankrollVault vault) {
        tbl = new InfiniteBlackjack(
            IERC20(token),
            IRandomnessProvider(PROVIDER),
            _rules(),
            minW,
            maxW,
            BET_WINDOW,
            ACT_WINDOW,
            100,
            msg.sender
        );
        vault = new SharedBankrollVault(IERC20(token), EXIT_DELAY, name, symbol, msg.sender);
        tbl.grantRole(tbl.TREASURY_ROLE(), address(vault));
        tbl.revokeRole(tbl.TREASURY_ROLE(), msg.sender);
        vault.addTable(IBankrollTable(address(tbl)));
    }

    /// @dev Move an (LP-empty, onchain-verified) classic table from its legacy
    ///      per-table vault into the shared pool.
    function _repointClassic(address classic, address legacyVault, SharedBankrollVault pool)
        internal
    {
        BlackjackTableV2 t = BlackjackTableV2(classic);
        require(BankrollVault(legacyVault).totalSupply() == 0, "legacy vault has LPs");
        t.grantRole(t.TREASURY_ROLE(), address(pool));
        t.revokeRole(t.TREASURY_ROLE(), legacyVault);
        pool.addTable(IBankrollTable(classic));
    }

    function runTestnet() external {
        require(block.chainid == 6343, "not MegaETH testnet");
        vm.startBroadcast();

        (InfiniteBlackjack chipInf, SharedBankrollVault hpCHIP) =
            _deploySet(CHIP, 1e18, 500e18, "Blackjack CHIP House Pool", "hpCHIP");
        (InfiniteBlackjack usdmInf, SharedBankrollVault hpUSDm) =
            _deploySet(USDM, 1e18, 100e18, "Blackjack USDm House Pool", "hpUSDm");
        (InfiniteBlackjack ethInf, SharedBankrollVault hpETH) =
            _deploySet(WETH, 5e14, 1e16, "Blackjack ETH House Pool", "hpETH");
        (InfiniteBlackjack megaInf, SharedBankrollVault hpMEGA) =
            _deploySet(MEGA, 1e18, 100e18, "Blackjack MEGA House Pool", "hpMEGA");

        // USDm/MEGA classic tables join their asset pools (legacy vaults empty).
        _repointClassic(USDM_TABLE, USDM_LEGACY_VAULT, hpUSDm);
        _repointClassic(MEGA_TABLE, MEGA_LEGACY_VAULT, hpMEGA);

        // Seed the CHIP pool and push it into the infinite table.
        IMintable(CHIP).mint(msg.sender, 200_000e18);
        IERC20(CHIP).approve(address(hpCHIP), 200_000e18);
        hpCHIP.deposit(200_000e18, msg.sender);
        hpCHIP.fundTable(IBankrollTable(address(chipInf)), 200_000e18);

        // Start the bjETH unwind clock (deployer is its sole LP, verified onchain);
        // FinishEthMigration claims + re-points once the delay matures.
        BankrollVault legacyEth = BankrollVault(ETH_LEGACY_VAULT);
        legacyEth.requestRedeem(legacyEth.balanceOf(msg.sender));

        vm.stopBroadcast();

        console.log("CHIP  infinite:", address(chipInf));
        console.log("CHIP  pool:    ", address(hpCHIP));
        console.log("USDm  infinite:", address(usdmInf));
        console.log("USDm  pool:    ", address(hpUSDm));
        console.log("ETH   infinite:", address(ethInf));
        console.log("ETH   pool:    ", address(hpETH));
        console.log("MEGA  infinite:", address(megaInf));
        console.log("MEGA  pool:    ", address(hpMEGA));
    }
}

/// @notice Run >= 1h after DeployInfinite: claim the matured bjETH exit, move the
///         ETH classic table into the shared ETH pool and re-deposit the recovered
///         WETH. Set ETH_INFINITE/HP_ETH env vars to the DeployInfinite outputs.
contract FinishEthMigration is Script {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant ETH_TABLE = 0x756595C7d4e3d2668700d0f3d72CDC377b66d116;
    address internal constant ETH_LEGACY_VAULT = 0xB3A0E5faec83091252da443E65E28C855440ef2c;

    function runTestnet() external {
        require(block.chainid == 6343, "not MegaETH testnet");
        SharedBankrollVault pool = SharedBankrollVault(vm.envAddress("HP_ETH"));
        address ethInfinite = vm.envAddress("ETH_INFINITE");
        vm.startBroadcast();

        uint256 recovered = BankrollVault(ETH_LEGACY_VAULT).claim(msg.sender);

        BlackjackTableV2 t = BlackjackTableV2(ETH_TABLE);
        require(BankrollVault(ETH_LEGACY_VAULT).totalSupply() == 0, "legacy vault has LPs");
        t.grantRole(t.TREASURY_ROLE(), address(pool));
        t.revokeRole(t.TREASURY_ROLE(), ETH_LEGACY_VAULT);
        pool.addTable(IBankrollTable(ETH_TABLE));

        IERC20(WETH).approve(address(pool), recovered);
        pool.deposit(recovered, msg.sender);
        pool.fundTable(IBankrollTable(ETH_TABLE), recovered / 2);
        pool.fundTable(IBankrollTable(ethInfinite), recovered - recovered / 2);

        vm.stopBroadcast();
        console.log("recovered WETH:", recovered);
    }
}
