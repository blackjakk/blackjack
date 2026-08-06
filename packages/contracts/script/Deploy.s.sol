// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {TestChip} from "../src/TestChip.sol";
import {BlackjackTable} from "../src/BlackjackTable.sol";
import {MockRandomnessProvider} from "../src/rand/MockRandomnessProvider.sol";
import {DrandRandomnessProvider} from "../src/rand/DrandRandomnessProvider.sol";
import {IDrandOracleQuicknet} from "../src/interfaces/IDrandOracleQuicknet.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deployment scripts. Never hardcode private keys — pass them via
///         `--private-key` / keystore and configure the rest through env vars.
contract Deploy is Script {
    /// MegaETH testnet (chain 6343) preinstalled DrandOracleQuicknet.
    /// Verified against docs.megaeth.com/developer-docs/vrf and the live chain.
    address internal constant TESTNET_DRAND_VERIFIER = 0x4e1673dcAA38136b5032F27ef93423162aF977Cc;

    uint256 internal constant DEFAULT_MIN_WAGER = 1e18; // 1 CHIP
    uint256 internal constant DEFAULT_MAX_WAGER = 1_000e18; // 1000 CHIP
    uint256 internal constant DEFAULT_BANKROLL = 1_000_000e18; // 1M CHIP

    function _deployCommon(IRandomnessProvider provider, address admin)
        internal
        returns (TestChip chip, BlackjackTable table)
    {
        chip = new TestChip(admin);
        table = new BlackjackTable(
            IERC20(address(chip)),
            provider,
            vm.envOr("MIN_WAGER", DEFAULT_MIN_WAGER),
            vm.envOr("MAX_WAGER", DEFAULT_MAX_WAGER),
            admin
        );
        uint256 bankroll = vm.envOr("HOUSE_BANKROLL", DEFAULT_BANKROLL);
        chip.mint(admin, bankroll);
        chip.approve(address(table), bankroll);
        table.fundHouse(bankroll);
    }

    /// @notice Local/anvil deployment with the deterministic mock provider.
    function runLocal() external {
        vm.startBroadcast();
        address admin = msg.sender;
        MockRandomnessProvider mock = new MockRandomnessProvider();
        (TestChip chip, BlackjackTable table) =
            _deployCommon(IRandomnessProvider(address(mock)), admin);
        vm.stopBroadcast();

        console.log("== local deployment (mock randomness) ==");
        console.log("TestChip:               ", address(chip));
        console.log("MockRandomnessProvider: ", address(mock));
        console.log("BlackjackTable:         ", address(table));
        console.log("admin/treasury:         ", admin);
    }

    /// @notice MegaETH testnet deployment with the drand quicknet adapter.
    /// @dev Requires chain 6343. Re-verify the verifier address against
    ///      docs.megaeth.com before deploying; override with DRAND_VERIFIER if the
    ///      preinstall ever moves.
    function runTestnet() external {
        require(block.chainid == 6343, "expected MegaETH testnet (6343)");
        address verifier = vm.envOr("DRAND_VERIFIER", TESTNET_DRAND_VERIFIER);
        require(verifier.code.length > 0, "drand verifier has no code at this address");

        vm.startBroadcast();
        address admin = msg.sender;
        DrandRandomnessProvider drand = new DrandRandomnessProvider(
            IDrandOracleQuicknet(verifier), uint64(vm.envOr("MIN_FUTURE_ROUNDS", uint256(2)))
        );
        (TestChip chip, BlackjackTable table) =
            _deployCommon(IRandomnessProvider(address(drand)), admin);
        vm.stopBroadcast();

        console.log("== MegaETH testnet deployment (drand randomness) ==");
        console.log("TestChip:                ", address(chip));
        console.log("DrandRandomnessProvider: ", address(drand));
        console.log("BlackjackTable:          ", address(table));
        console.log("DrandOracleQuicknet:     ", verifier);
        console.log("admin/treasury:          ", admin);
        console.log("");
        console.log("next steps: start the keeper, record addresses in packages/config,");
        console.log("then review role assignments per docs/DEPLOYMENT.md");
    }
}
