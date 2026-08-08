// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SeedSearch} from "./utils/SeedSearch.sol";
import {TestChip} from "../src/TestChip.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {InfiniteBlackjack} from "../src/InfiniteBlackjack.sol";
import {SharedBankrollVault} from "../src/SharedBankrollVault.sol";
import {IBankrollTable} from "../src/interfaces/IBankrollTable.sol";
import {MockRandomnessProvider} from "../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice One vault, one asset, many games: a classic v2 table and an infinite
///         table share a single LP pool. Every unit of bankroll flows through the
///         vault in this suite so share-price assertions are exact.
contract SharedVaultTest is SeedSearch {
    TestChip internal chip;
    MockRandomnessProvider internal mock;
    BlackjackTableV2 internal tblA;
    InfiniteBlackjack internal tblI;
    SharedBankrollVault internal vault;

    address internal admin = makeAddr("admin");
    address internal lp = makeAddr("lp");
    address internal player = makeAddr("player");

    uint256 internal constant DEPOSIT = 1_000e18;
    uint256 internal constant W = 10e18;

    function setUp() public {
        chip = new TestChip(admin);
        mock = new MockRandomnessProvider();
        BlackjackTableV2.Rules memory rules = BlackjackTableV2.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: BlackjackTableV2.DoubleRule.ANY_TWO,
            lateSurrender: false
        });
        tblA = new BlackjackTableV2(
            IERC20(address(chip)), IRandomnessProvider(address(mock)), rules, 1e18, 1_000e18, 5, admin
        );
        tblI = new InfiniteBlackjack(
            IERC20(address(chip)),
            IRandomnessProvider(address(mock)),
            InfiniteBlackjack.Rules({
                dealerHitsSoft17: false,
                blackjackNum: 3,
                blackjackDen: 2,
                doubleRule: InfiniteBlackjack.DoubleRule.ANY_TWO,
                lateSurrender: true
            }),
            1e18,
            1_000e18,
            60,
            60,
            100,
            admin
        );
        vault =
            new SharedBankrollVault(IERC20(address(chip)), 1 hours, "Blackjack CHIP Pool", "bjCHIP", admin);

        vm.startPrank(admin);
        tblA.grantRole(tblA.TREASURY_ROLE(), address(vault));
        tblA.revokeRole(tblA.TREASURY_ROLE(), admin);
        tblI.grantRole(tblI.TREASURY_ROLE(), address(vault));
        tblI.revokeRole(tblI.TREASURY_ROLE(), admin);
        vault.addTable(IBankrollTable(address(tblA)));
        vault.addTable(IBankrollTable(address(tblI)));
        chip.mint(lp, 10_000e18);
        chip.mint(player, 1_000e18);
        vm.stopPrank();

        vm.prank(lp);
        chip.approve(address(vault), type(uint256).max);
        vm.startPrank(player);
        chip.approve(address(tblA), type(uint256).max);
        chip.approve(address(tblI), type(uint256).max);
        vm.stopPrank();
    }

    function deposit() internal returns (uint256 shares) {
        vm.prank(lp);
        shares = vault.deposit(DEPOSIT, lp);
    }

    // ------------------------------------------------------------ pool mechanics

    function test_depositStaysIdle_permissionlessFundPushes() public {
        deposit();
        assertEq(chip.balanceOf(address(vault)), DEPOSIT, "deposits idle");
        assertEq(vault.totalAssets(), DEPOSIT);

        vm.prank(makeAddr("anyone")); // fundTable is deliberately permissionless
        vault.fundTable(IBankrollTable(address(tblA)), 600e18);
        vault.fundTable(IBankrollTable(address(tblI)), 400e18);

        assertEq(tblA.houseFunds(), 600e18);
        assertEq(tblI.houseFunds(), 400e18);
        assertEq(chip.balanceOf(address(vault)), 0);
        assertEq(vault.totalAssets(), DEPOSIT, "totalAssets unchanged by rebalance");
    }

    function test_defundIsRoleGated() public {
        deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 600e18);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert();
        vault.defundTable(IBankrollTable(address(tblA)), 100e18);

        vm.prank(admin);
        vault.defundTable(IBankrollTable(address(tblA)), 100e18);
        assertEq(tblA.houseFunds(), 500e18);
        assertEq(chip.balanceOf(address(vault)), 500e18);
    }

    function test_addTableGuards() public {
        // Non-admin cannot add.
        BlackjackTableV2 rogue = _newV2Table(chip);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert();
        vault.addTable(IBankrollTable(address(rogue)));

        // Vault must already hold the table's treasury role.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.VaultNotTreasury.selector, address(rogue))
        );
        vault.addTable(IBankrollTable(address(rogue)));

        // Asset must match.
        TestChip other = new TestChip(admin);
        BlackjackTableV2 wrongAsset = _newV2Table(other);
        vm.startPrank(admin);
        wrongAsset.grantRole(wrongAsset.TREASURY_ROLE(), address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.AssetMismatch.selector, address(wrongAsset))
        );
        vault.addTable(IBankrollTable(address(wrongAsset)));

        // No duplicates.
        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.AlreadyMember.selector, address(tblA))
        );
        vault.addTable(IBankrollTable(address(tblA)));
        vm.stopPrank();

        assertEq(vault.tables().length, 2);
    }

    function test_removeTableOnlyWhenDefunded() public {
        deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 100e18);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.TableNotEmpty.selector, address(tblA))
        );
        vault.removeTable(IBankrollTable(address(tblA)));

        vm.startPrank(admin);
        vault.defundTable(IBankrollTable(address(tblA)), 100e18);
        vault.removeTable(IBankrollTable(address(tblA)));
        vm.stopPrank();
        assertFalse(vault.isMember(address(tblA)));
        assertEq(vault.tables().length, 1);
        assertEq(vault.totalAssets(), DEPOSIT);
    }

    // ------------------------------------------------------------ share price

    function test_sharePriceSharedAcrossGames() public {
        uint256 shares = deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 500e18);
        vault.fundTable(IBankrollTable(address(tblI)), 500e18);
        uint256 before = vault.previewRedeem(shares);

        // Player loses W at the classic table: stands on 14, dealer makes 18.
        vm.prank(player);
        uint256 gameId = tblA.placeBet(W);
        mock.fulfill(tblA.getGame(gameId).pendingRequestId, findInitialSeed(6, 6, 8, gameId));
        vm.prank(player);
        tblA.stand(gameId);
        mock.fulfill(tblA.getGame(gameId).pendingRequestId, findDealerSeedRule(8, 18, false, gameId));
        assertEq(
            uint8(tblA.getGame(gameId).outcome), uint8(BlackjackTableV2.Outcome.DEALER_WIN)
        );

        // The loss accrues to the WHOLE pool: every LP share appreciates, and the
        // vault's books see it no matter which member table it happened at.
        assertEq(vault.totalAssets(), DEPOSIT + W);
        assertGt(vault.previewRedeem(shares), before);
    }

    // ------------------------------------------------------------ exit queue

    function test_claimPullsAcrossAllMemberTables() public {
        uint256 shares = deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 600e18);
        vault.fundTable(IBankrollTable(address(tblI)), 400e18); // idle now 0

        vm.prank(lp);
        vault.requestRedeem(shares);
        vm.warp(block.timestamp + 1 hours);
        uint256 before = chip.balanceOf(lp);
        vm.prank(lp);
        uint256 assets = vault.claim(lp);

        assertApproxEqAbs(assets, DEPOSIT, 1e13, "full pool back");
        assertEq(chip.balanceOf(lp), before + assets);
        assertApproxEqAbs(tblA.houseFunds() + tblI.houseFunds(), 0, 1e13, "tables swept");
    }

    function test_claimBlockedWhileReserved_thenSucceeds() public {
        uint256 shares = deposit();
        vault.fundTable(IBankrollTable(address(tblA)), DEPOSIT);

        // A live game reserves 2xW of the bankroll...
        vm.prank(player);
        uint256 gameId = tblA.placeBet(500e18 - 1e18); // reserves ~998, leaves ~2 free

        vm.prank(lp);
        vault.requestRedeem(shares);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(lp);
        vm.expectRevert(); // InsufficientLiquidAssets — most of the pool is reserved
        vault.claim(lp);

        // ...the beacon never arrives, the player cancels, reservations release.
        vm.prank(player);
        tblA.cancelTimedOutGame(gameId);
        vm.prank(lp);
        uint256 assets = vault.claim(lp);
        assertApproxEqAbs(assets, DEPOSIT, 1e13);
    }

    function test_exitQueueSemantics() public {
        uint256 shares = deposit();

        vm.startPrank(lp);
        vm.expectRevert(); // instant 4626 exits are disabled (maxRedeem = 0)
        vault.redeem(shares, lp, lp);
        vm.expectRevert();
        vault.withdraw(100e18, lp, lp);

        vault.requestRedeem(shares / 2);
        (, uint64 claimableAt) = vault.exitRequests(lp);
        assertEq(claimableAt, uint64(block.timestamp) + 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.NotClaimableYet.selector, claimableAt)
        );
        vault.claim(lp);

        // Top-up restarts the clock for the whole aggregate request.
        vm.warp(block.timestamp + 30 minutes);
        vault.requestRedeem(shares / 4);
        (uint192 pending, uint64 newClaimable) = vault.exitRequests(lp);
        assertEq(uint256(pending), shares / 2 + shares / 4);
        assertEq(newClaimable, uint64(block.timestamp) + 1 hours);

        vm.warp(block.timestamp + 1 hours);
        uint256 assets = vault.claim(lp);
        assertApproxEqAbs(assets, (DEPOSIT * 3) / 4, 1e13);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ helpers

    function _newV2Table(TestChip token) internal returns (BlackjackTableV2) {
        return new BlackjackTableV2(
            IERC20(address(token)),
            IRandomnessProvider(address(mock)),
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
            admin
        );
    }
}
