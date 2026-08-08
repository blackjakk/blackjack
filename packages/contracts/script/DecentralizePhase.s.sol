// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {SharedBankrollVault} from "../src/SharedBankrollVault.sol";
import {IBankrollTable} from "../src/interfaces/IBankrollTable.sol";
import {TableFactory} from "../src/TableFactory.sol";
import {TableFactoryV3} from "../src/TableFactoryV3.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";

interface IRolesTable is IAccessControl {
    function TREASURY_ROLE() external view returns (bytes32);
}

interface ILegacyPool {
    function claim(address receiver) external returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice Decentralization phase (rungs 1+2+3), executed while the deployer is
///         still the sole LP of every pool (verified onchain before running):
///         1. TIMELOCK: an OZ TimelockController (12 h, open execution) becomes
///            DEFAULT_ADMIN of every table and pool; the deployer keeps only
///            proposer rights on the timelock and the operational REBALANCER role.
///         2. PROVENANCE: fresh factories that record what they deploy
///            (isFromFactory); pools treat factory-deployed tables as tier 1.
///         3. BONDS + CAPS: membership proposals post a MEGA bond, commit to a
///            float cap, and can be objectively slashed via claimDefault.
///         Also claims the matured v1-pool exits and funds the new pools, so the
///         intermediate (zero-LP) governed pools are skipped entirely.
///         Run with --skip-simulation --slow on MegaETH testnet.
contract DecentralizePhase is Script {
    address internal constant CHIP = 0x31E4261aF4Ed630E78d7438Ebcb25Ca7c3c15711;
    address internal constant USDM = 0x15e9f2B0A747aC05c7446559306687085D161e5C;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant MEGA = 0xc903c68C1d389CEd76fEe0349067a4295828e6c2;
    address internal constant PROVIDER = 0x801466769247D89B3d768C4Ad5B74D83466cD14b;

    // Pool member tables (per asset: infinite + classic; CHIP: infinite only).
    address internal constant CHIP_INF = 0x9103B9723e5BffbBcD70Bfb0785AADF64E2D0E35;
    address internal constant USDM_INF = 0x70D3f02A850c197Bc339ba9F8530aBcCb4217Aac;
    address internal constant ETH_INF = 0xb25Fd4A3dEFF1926e6B17B1fF8Eb2beBDd807286;
    address internal constant MEGA_INF = 0x6EF4dEf337D24631efEe0e0ffb145Ef835430644;
    address internal constant USDM_TABLE = 0x700762a0DB39AA3Dc8a84260FCd0e7A52cbc4003;
    address internal constant ETH_TABLE = 0x756595C7d4e3d2668700d0f3d72CDC377b66d116;
    address internal constant MEGA_TABLE = 0x480F77B89B498DD995B72FE9672053836983D272;

    // Non-pool tables whose admin also moves behind the timelock.
    address internal constant V1_TABLE = 0x261ab01D3c6F06BccBb49380bD27cd9303A4dB2f;
    address internal constant T_CLASSIC = 0x457e5eb30973af0654aE3f6b5E1ba62d5c97C1cF;
    address internal constant T_VEGAS = 0xe4eDc43D1cD0cC5370fAB275EcB1c50C1CC0b6Ee;
    address internal constant T_PRO = 0xb414D2B3AAe5Da85813Ea3680895a457e0a08577;
    address internal constant T_SPLIT = 0x1d8DD0B8D825c939024582f31Dc512955187Dc2E;

    // v2 governed pools (zero LP shares — instant re-point) and v1 pools whose
    // matured exits this script claims.
    address internal constant V2_HP_CHIP = 0x9360f0d73cE4f982b56434e85459550Aa0791fDA;
    address internal constant V2_HP_USDM = 0xFb26980EBE8BcEdcaa40aD5B561Da33f8894cdAD;
    address internal constant V2_HP_ETH = 0xbae7289F86E4893a69c6bD73E46EC2547C6FA829;
    address internal constant V2_HP_MEGA = 0x5d151dDb5ef6Fb2F9F2a290411F44eD77014c550;
    address internal constant V1_HP_CHIP = 0xDD796fb9BfDCAb8210884Ccc8634B8f8a2324Bc0;
    address internal constant V1_HP_ETH = 0x6558427457B8bf3C36Ab1E1be88F2a5223cd55D4;

    uint64 internal constant EXIT_DELAY = 1 hours;
    uint64 internal constant MEMBERSHIP_DELAY = 48 hours; // tier 1 waits 12 h
    uint256 internal constant TIMELOCK_DELAY = 12 hours;
    uint256 internal constant TIER2_BOND = 1_000e18; // MEGA

    TimelockController internal tlc;

    function _newPool(address token, string memory name, string memory symbol)
        internal
        returns (SharedBankrollVault)
    {
        return new SharedBankrollVault(
            IERC20(token),
            EXIT_DELAY,
            MEMBERSHIP_DELAY,
            IERC20(MEGA),
            address(tlc),
            TIER2_BOND,
            name,
            symbol,
            msg.sender
        );
    }

    /// @dev Re-point `table` from the v2 pool to `pool` and register membership
    ///      (instant + bond-free while the new pool has zero shares).
    function _adopt(address table, address v2Pool, SharedBankrollVault pool, uint256 maxFloat)
        internal
    {
        IRolesTable t = IRolesTable(table);
        bytes32 role = t.TREASURY_ROLE();
        t.grantRole(role, address(pool));
        t.revokeRole(role, v2Pool);
        pool.proposeTable(IBankrollTable(table), maxFloat);
    }

    /// @dev Hand a contract's DEFAULT_ADMIN_ROLE to the timelock and drop the
    ///      deployer's. Every future privileged action is then public + delayed.
    function _adminToTimelock(address target) internal {
        IAccessControl(target).grantRole(0x00, address(tlc));
        IAccessControl(target).renounceRole(0x00, msg.sender);
    }

    function _poolHandover(SharedBankrollVault pool) internal {
        pool.grantRole(pool.REBALANCER_ROLE(), address(tlc));
        _adminToTimelock(address(pool)); // deployer keeps REBALANCER only
    }

    function runTestnet() external {
        require(block.chainid == 6343, "not MegaETH testnet");
        require(
            ILegacyPool(V1_HP_CHIP).totalSupply() > 0 && ILegacyPool(V1_HP_ETH).totalSupply() > 0,
            "v1 exits already claimed?"
        );
        vm.startBroadcast();

        // ---- rung 1: the timelock -------------------------------------------
        address[] memory proposers = new address[](1);
        proposers[0] = msg.sender;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution: matured ops runnable by anyone
        tlc = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));

        // ---- rung 2: provenance-recording factories -------------------------
        TableFactory fChip = new TableFactory(IERC20(CHIP), IRandomnessProvider(PROVIDER));
        TableFactoryV3 fChipV3 = new TableFactoryV3(IERC20(CHIP), IRandomnessProvider(PROVIDER));
        TableFactory fUsdm = new TableFactory(IERC20(USDM), IRandomnessProvider(PROVIDER));
        TableFactory fEth = new TableFactory(IERC20(WETH), IRandomnessProvider(PROVIDER));
        TableFactory fMega = new TableFactory(IERC20(MEGA), IRandomnessProvider(PROVIDER));

        // ---- rung 3: bonded, capped, governed pools -------------------------
        SharedBankrollVault hpCHIP = _newPool(CHIP, "Blackjack CHIP House Pool", "hpCHIP");
        SharedBankrollVault hpUSDm = _newPool(USDM, "Blackjack USDm House Pool", "hpUSDm");
        SharedBankrollVault hpETH = _newPool(WETH, "Blackjack ETH House Pool", "hpETH");
        SharedBankrollVault hpMEGA = _newPool(MEGA, "Blackjack MEGA House Pool", "hpMEGA");
        hpCHIP.setTrustedFactory(address(fChip), true);
        hpCHIP.setTrustedFactory(address(fChipV3), true);
        hpUSDm.setTrustedFactory(address(fUsdm), true);
        hpETH.setTrustedFactory(address(fEth), true);
        hpMEGA.setTrustedFactory(address(fMega), true);

        // ---- claim the matured v1 exits (deployer = sole LP, verified) ------
        uint256 chipOut = ILegacyPool(V1_HP_CHIP).claim(msg.sender);
        uint256 wethOut = ILegacyPool(V1_HP_ETH).claim(msg.sender);

        // ---- adopt every member table into the final pools ------------------
        _adopt(CHIP_INF, V2_HP_CHIP, hpCHIP, 500_000e18);
        _adopt(USDM_INF, V2_HP_USDM, hpUSDm, 50_000e18);
        _adopt(USDM_TABLE, V2_HP_USDM, hpUSDm, 50_000e18);
        _adopt(ETH_INF, V2_HP_ETH, hpETH, 1e18);
        _adopt(ETH_TABLE, V2_HP_ETH, hpETH, 1e18);
        _adopt(MEGA_INF, V2_HP_MEGA, hpMEGA, 50_000e18);
        _adopt(MEGA_TABLE, V2_HP_MEGA, hpMEGA, 50_000e18);

        // ---- fund ------------------------------------------------------------
        IERC20(CHIP).approve(address(hpCHIP), chipOut);
        hpCHIP.deposit(chipOut, msg.sender);
        hpCHIP.fundTable(IBankrollTable(CHIP_INF), chipOut);
        IERC20(WETH).approve(address(hpETH), wethOut);
        hpETH.deposit(wethOut, msg.sender);
        hpETH.fundTable(IBankrollTable(ETH_TABLE), wethOut / 2);
        hpETH.fundTable(IBankrollTable(ETH_INF), wethOut - wethOut / 2);

        // ---- rung 1 completion: every admin key behind the timelock ---------
        _poolHandover(hpCHIP);
        _poolHandover(hpUSDm);
        _poolHandover(hpETH);
        _poolHandover(hpMEGA);
        address[12] memory allTables = [
            V1_TABLE,
            T_CLASSIC,
            T_VEGAS,
            T_PRO,
            T_SPLIT,
            USDM_TABLE,
            ETH_TABLE,
            MEGA_TABLE,
            CHIP_INF,
            USDM_INF,
            ETH_INF,
            MEGA_INF
        ];
        for (uint256 i; i < allTables.length; ++i) {
            _adminToTimelock(allTables[i]);
        }

        vm.stopBroadcast();
        console.log("timelock:  ", address(tlc));
        console.log("hpCHIP v3: ", address(hpCHIP));
        console.log("hpUSDm v3: ", address(hpUSDm));
        console.log("hpETH v3:  ", address(hpETH));
        console.log("hpMEGA v3: ", address(hpMEGA));
        console.log("factory CHIP v2:", address(fChip));
        console.log("factory CHIP v3:", address(fChipV3));
        console.log("factory USDm:   ", address(fUsdm));
        console.log("factory ETH:    ", address(fEth));
        console.log("factory MEGA:   ", address(fMega));
        console.log("CHIP recovered:", chipOut);
        console.log("WETH recovered:", wethOut);
    }
}
