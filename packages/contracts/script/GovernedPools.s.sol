// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SharedBankrollVault} from "../src/SharedBankrollVault.sol";
import {IBankrollTable} from "../src/interfaces/IBankrollTable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

interface ITreasuryTable is IAccessControl {
    function TREASURY_ROLE() external view returns (bytes32);
}

/// @notice Replace the v1 shared pools (instant admin addTable) with GOVERNED
///         pools: membership is propose -> 48 h timelock -> permissionless
///         activate while LPs exist (instant only at zero supply). Run while the
///         deployer is still the SOLE LP of every v1 pool — verified onchain
///         before broadcasting.
///
///         Phase 1 (`runTestnet`): deploy the four governed pools; migrate the
///         empty USDm/MEGA sets immediately; start the delayed exits that unwind
///         the deployer's CHIP and ETH positions in the v1 pools.
///         Phase 2 (`finishFunded`, >= 1 h later): claim both exits, re-point
///         the CHIP/ETH tables, re-deposit and re-fund. Tables are proposed only
///         AFTER the old pool released them so the new pools' totalAssets never
///         double-counts funds still owed to v1-pool LPs.
///         Run with --skip-simulation --slow on MegaETH testnet.
contract GovernedPools is Script {
    address internal constant CHIP = 0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711;
    address internal constant USDM = 0x15e9f2B0A747aC05c7446559306687085D161e5C;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant MEGA = 0xc903c68C1d389CEd76fEe0349067a4295828e6c2;

    address internal constant CHIP_INF = 0x9103B9723e5BffbBcD70Bfb0785AADF64E2D0E35;
    address internal constant USDM_INF = 0x70D3f02A850c197Bc339ba9F8530aBcCb4217Aac;
    address internal constant ETH_INF = 0xb25Fd4A3dEFF1926e6B17B1fF8Eb2beBDd807286;
    address internal constant MEGA_INF = 0x6EF4dEf337D24631efEe0e0ffb145Ef835430644;
    address internal constant USDM_TABLE = 0x700762a0DB39AA3Dc8a84260FCd0e7A52cbc4003;
    address internal constant ETH_TABLE = 0x756595C7d4e3d2668700d0f3d72CDC377b66d116;
    address internal constant MEGA_TABLE = 0x480F77B89B498DD995B72FE9672053836983D272;

    address internal constant OLD_HP_CHIP = 0xDD796fb9BfDCAb8210884Ccc8634B8f8a2324Bc0;
    address internal constant OLD_HP_USDM = 0x8F88B2FfDEF4F79f9a7C7Ac3429b4A0439965c2E;
    address internal constant OLD_HP_ETH = 0x6558427457B8bf3C36Ab1E1be88F2a5223cd55D4;
    address internal constant OLD_HP_MEGA = 0x03C399f63755e04f4E3D56a92972d3f37e93a51C;

    uint64 internal constant EXIT_DELAY = 1 hours;
    uint64 internal constant MEMBERSHIP_DELAY = 48 hours;

    function _newPool(address token, string memory name, string memory symbol)
        internal
        returns (SharedBankrollVault)
    {
        return new SharedBankrollVault(
            IERC20(token), EXIT_DELAY, MEMBERSHIP_DELAY, name, symbol, msg.sender
        );
    }

    /// @dev Move `table` from `oldPool` to `newPool` (grant new treasury, revoke
    ///      old, propose — instant while the new pool has zero shares).
    function _repoint(address table, address oldPool, SharedBankrollVault newPool) internal {
        ITreasuryTable t = ITreasuryTable(table);
        bytes32 role = t.TREASURY_ROLE();
        t.grantRole(role, address(newPool));
        t.revokeRole(role, oldPool);
        newPool.proposeTable(IBankrollTable(table));
    }

    function runTestnet() external {
        require(block.chainid == 6343, "not MegaETH testnet");
        vm.startBroadcast();

        SharedBankrollVault hpCHIP = _newPool(CHIP, "Blackjack CHIP House Pool", "hpCHIP");
        SharedBankrollVault hpUSDm = _newPool(USDM, "Blackjack USDm House Pool", "hpUSDm");
        SharedBankrollVault hpETH = _newPool(WETH, "Blackjack ETH House Pool", "hpETH");
        SharedBankrollVault hpMEGA = _newPool(MEGA, "Blackjack MEGA House Pool", "hpMEGA");

        // USDm/MEGA v1 pools hold no LP shares and no funds: full migration now.
        require(SharedBankrollVault(OLD_HP_USDM).totalSupply() == 0, "hpUSDm v1 has LPs");
        require(SharedBankrollVault(OLD_HP_MEGA).totalSupply() == 0, "hpMEGA v1 has LPs");
        _repoint(USDM_INF, OLD_HP_USDM, hpUSDm);
        _repoint(USDM_TABLE, OLD_HP_USDM, hpUSDm);
        _repoint(MEGA_INF, OLD_HP_MEGA, hpMEGA);
        _repoint(MEGA_TABLE, OLD_HP_MEGA, hpMEGA);

        // CHIP/ETH v1 pools hold the deployer's LP positions: start their delayed
        // exits; finishFunded() completes the move once the queue matures.
        SharedBankrollVault(OLD_HP_CHIP).requestRedeem(
            SharedBankrollVault(OLD_HP_CHIP).balanceOf(msg.sender)
        );
        SharedBankrollVault(OLD_HP_ETH).requestRedeem(
            SharedBankrollVault(OLD_HP_ETH).balanceOf(msg.sender)
        );

        vm.stopBroadcast();
        console.log("governed hpCHIP:", address(hpCHIP));
        console.log("governed hpUSDm:", address(hpUSDm));
        console.log("governed hpETH: ", address(hpETH));
        console.log("governed hpMEGA:", address(hpMEGA));
    }

    /// @notice Phase 2, >= 1 h after runTestnet. Env: NEW_HP_CHIP, NEW_HP_ETH.
    function finishFunded() external {
        require(block.chainid == 6343, "not MegaETH testnet");
        SharedBankrollVault hpCHIP = SharedBankrollVault(vm.envAddress("NEW_HP_CHIP"));
        SharedBankrollVault hpETH = SharedBankrollVault(vm.envAddress("NEW_HP_ETH"));
        vm.startBroadcast();

        uint256 chipOut = SharedBankrollVault(OLD_HP_CHIP).claim(msg.sender);
        uint256 wethOut = SharedBankrollVault(OLD_HP_ETH).claim(msg.sender);
        require(SharedBankrollVault(OLD_HP_CHIP).totalSupply() == 0, "hpCHIP v1 has LPs");
        require(SharedBankrollVault(OLD_HP_ETH).totalSupply() == 0, "hpETH v1 has LPs");

        _repoint(CHIP_INF, OLD_HP_CHIP, hpCHIP);
        _repoint(ETH_INF, OLD_HP_ETH, hpETH);
        _repoint(ETH_TABLE, OLD_HP_ETH, hpETH);

        IERC20(CHIP).approve(address(hpCHIP), chipOut);
        hpCHIP.deposit(chipOut, msg.sender);
        hpCHIP.fundTable(IBankrollTable(CHIP_INF), chipOut);

        IERC20(WETH).approve(address(hpETH), wethOut);
        hpETH.deposit(wethOut, msg.sender);
        hpETH.fundTable(IBankrollTable(ETH_TABLE), wethOut / 2);
        hpETH.fundTable(IBankrollTable(ETH_INF), wethOut - wethOut / 2);

        vm.stopBroadcast();
        console.log("CHIP recovered:", chipOut);
        console.log("WETH recovered:", wethOut);
    }
}
