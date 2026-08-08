// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestChip} from "../src/TestChip.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {BankrollVault} from "../src/BankrollVault.sol";
import {TableFactory} from "../src/TableFactory.sol";
import {MockRandomnessProvider} from "../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SeedSearch} from "./utils/SeedSearch.sol";

/// @notice BankrollVault: LP shares over a live table's bankroll.
contract BankrollVaultTest is SeedSearch {
    TestChip internal chip;
    MockRandomnessProvider internal mock;
    BlackjackTableV2 internal tbl;
    BankrollVault internal vault;

    address internal admin = makeAddr("admin");
    address internal lp1 = makeAddr("lp1");
    address internal lp2 = makeAddr("lp2");
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant SEED_LIQ = 100_000e18;

    function setUp() public {
        chip = new TestChip(admin);
        mock = new MockRandomnessProvider();
        TableFactory factory =
            new TableFactory(IERC20(address(chip)), IRandomnessProvider(address(mock)));
        tbl = BlackjackTableV2(
            factory.createTable(
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
            )
        );
        vault = new BankrollVault(tbl, 1 hours, "Blackjack Classic LP", "bjCHIP");

        // The vault becomes the table's ONLY treasury.
        vm.startPrank(admin);
        tbl.grantRole(tbl.TREASURY_ROLE(), address(vault));
        tbl.revokeRole(tbl.TREASURY_ROLE(), admin);
        chip.mint(lp1, 1_000_000e18);
        chip.mint(lp2, 1_000_000e18);
        chip.mint(player, 100_000e18);
        vm.stopPrank();

        vm.prank(lp1);
        chip.approve(address(vault), type(uint256).max);
        vm.prank(lp2);
        chip.approve(address(vault), type(uint256).max);
        vm.prank(player);
        chip.approve(address(tbl), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers

    function seedVault() internal returns (uint256 shares) {
        vm.prank(lp1);
        shares = vault.deposit(SEED_LIQ, lp1);
    }

    function fulfill(uint256 gameId, bytes32 seed) internal {
        BlackjackTableV2.Game memory g = tbl.getGame(gameId);
        vm.prank(keeper);
        mock.fulfill(g.pendingRequestId, seed);
    }

    /// @dev Play one hand to a HOUSE win (player 18 stands, dealer 20).
    function houseWinsHand(uint256 wager) internal {
        vm.prank(player);
        uint256 gameId = tbl.placeBet(wager);
        fulfill(gameId, findInitialSeed(TEN, 8, TEN, gameId)); // player 18 vs 10
        vm.prank(player);
        tbl.stand(gameId);
        fulfill(gameId, findDealerSeedRule(TEN, 20, false, gameId));
        assertTrue(tbl.getGame(gameId).outcome == BlackjackTableV2.Outcome.DEALER_WIN);
    }

    /// @dev Play one hand to a PLAYER win (player 20 stands, dealer 18).
    function playerWinsHand(uint256 wager) internal {
        vm.prank(player);
        uint256 gameId = tbl.placeBet(wager);
        fulfill(gameId, findInitialSeed(TEN, TEN, SIX, gameId)); // player 20 vs 6
        vm.prank(player);
        tbl.stand(gameId);
        fulfill(gameId, findDealerSeedRule(SIX, 18, false, gameId));
        assertTrue(tbl.getGame(gameId).outcome == BlackjackTableV2.Outcome.PLAYER_WIN);
    }

    // ------------------------------------------------------------ tests

    function test_depositForwardsToTable() public {
        uint256 shares = seedVault();
        assertGt(shares, 0);
        assertEq(tbl.houseFunds(), SEED_LIQ); // all forwarded
        assertEq(chip.balanceOf(address(vault)), 0); // nothing idle
        assertEq(vault.totalAssets(), SEED_LIQ);
        assertEq(vault.balanceOf(lp1), shares);
    }

    function test_sharePriceRisesWhenHouseWins() public {
        seedVault();
        houseWinsHand(1_000e18);
        // House gained the player's stake.
        assertEq(vault.totalAssets(), SEED_LIQ + 1_000e18);
        // LP1's shares now redeem for more than deposited.
        uint256 out = vault.previewRedeem(vault.balanceOf(lp1));
        assertGt(out, SEED_LIQ);
    }

    function test_sharePriceFallsWhenPlayerWins() public {
        seedVault();
        playerWinsHand(1_000e18);
        assertEq(vault.totalAssets(), SEED_LIQ - 1_000e18);
        uint256 out = vault.previewRedeem(vault.balanceOf(lp1));
        assertLt(out, SEED_LIQ);
    }

    function test_exitQueueHappyPath() public {
        uint256 shares = seedVault();
        uint256 balBefore = chip.balanceOf(lp1);
        vm.prank(lp1);
        vault.requestRedeem(shares / 5);
        // Shares are escrowed immediately.
        assertEq(vault.balanceOf(lp1), shares - shares / 5);
        assertEq(vault.balanceOf(address(vault)), shares / 5);
        // Too early: claim reverts.
        vm.prank(lp1);
        vm.expectRevert();
        vault.claim(lp1);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(lp1);
        uint256 assets = vault.claim(lp1);
        assertApproxEqAbs(assets, SEED_LIQ / 5, 10);
        assertEq(chip.balanceOf(lp1), balBefore + assets);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    function test_freeLookIsDead() public {
        // LP requests an exit while a hand it "knows" the house will lose is
        // pending; the price is struck at CLAIM time, after the loss landed.
        uint256 shares = seedVault();
        vm.prank(lp1);
        vault.requestRedeem(shares);
        playerWinsHand(1_000e18); // the foreseen house loss settles
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(lp1);
        uint256 assets = vault.claim(lp1);
        // The claimant EATS the loss — exactly what kills the free look.
        assertApproxEqAbs(assets, SEED_LIQ - 1_000e18, 10);
    }

    function test_instantExitsDisabled() public {
        uint256 shares = seedVault();
        assertEq(vault.maxWithdraw(lp1), 0);
        assertEq(vault.maxRedeem(lp1), 0);
        vm.prank(lp1);
        vm.expectRevert();
        vault.withdraw(1e18, lp1, lp1);
        vm.prank(lp1);
        vm.expectRevert();
        vault.redeem(shares, lp1, lp1);
    }

    function test_topUpRestartsClock() public {
        uint256 shares = seedVault();
        vm.prank(lp1);
        vault.requestRedeem(shares / 2);
        vm.warp(block.timestamp + 50 minutes);
        vm.prank(lp1);
        vault.requestRedeem(shares / 2); // top-up restarts the delay
        vm.warp(block.timestamp + 30 minutes); // 80min total, 30 since top-up
        vm.prank(lp1);
        vm.expectRevert();
        vault.claim(lp1);
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(lp1);
        vault.claim(lp1);
    }

    function test_reservedLiabilityBlocksClaim() public {
        uint256 shares = seedVault();
        vm.prank(lp1);
        vault.requestRedeem(shares); // full exit requested
        vm.warp(block.timestamp + 1 hours + 1);
        // A max-wager game opens before the claim: 2x reserved cannot be pulled.
        vm.prank(player);
        tbl.placeBet(1_000e18);
        vm.prank(lp1);
        vm.expectRevert(); // WithdrawExceedsAvailable inside the table
        vault.claim(lp1);
        // Once the hand settles, the claim goes through.
        uint256 gameId = tbl.activeGamesOf(player)[0];
        fulfill(gameId, findInitialSeed(TEN, 8, TEN, gameId));
        vm.prank(player);
        tbl.stand(gameId);
        fulfill(gameId, findDealerSeedRule(TEN, 20, false, gameId));
        vm.prank(lp1);
        uint256 assets = vault.claim(lp1);
        assertApproxEqAbs(assets, SEED_LIQ + 1_000e18, 10); // house won that hand
    }

    function test_proportionalShares() public {
        seedVault();
        houseWinsHand(1_000e18); // price up before lp2 enters
        vm.prank(lp2);
        uint256 shares2 = vault.deposit(SEED_LIQ, lp2);
        // lp2 pays a higher price per share than lp1 did.
        assertLt(shares2, vault.balanceOf(lp1));
        // Both can preview-exit to their fair value; sum matches total (±rounding dust).
        uint256 v1 = vault.previewRedeem(vault.balanceOf(lp1));
        uint256 v2 = vault.previewRedeem(shares2);
        assertApproxEqAbs(v1 + v2, vault.totalAssets(), 10);
        assertGt(v1, v2); // lp1 carries the earlier profit
    }

    function test_donationInflationIsUnprofitable() public {
        // Attacker front-runs the first depositor with a 1-wei deposit + donation.
        vm.prank(admin);
        chip.mint(address(this), 20_000e18);
        chip.approve(address(vault), type(uint256).max);
        vault.deposit(1, address(this));
        chip.approve(address(tbl), type(uint256).max);
        tbl.fundHouse(10_000e18); // donation to inflate totalAssets

        // Victim deposits; virtual shares keep the pricing fair.
        vm.prank(lp1);
        vault.deposit(10_000e18, lp1);
        uint256 victimValue = vault.previewRedeem(vault.balanceOf(lp1));
        assertGt(victimValue, 9_999e18); // loss bounded to rounding dust

        // Attacker cannot profit: their redeemable value <= what they put in.
        uint256 attackerValue = vault.previewRedeem(vault.balanceOf(address(this)));
        assertLe(attackerValue, 10_000e18 + 1);
    }

    function test_treasuryExclusivity() public {
        assertTrue(tbl.hasRole(tbl.TREASURY_ROLE(), address(vault)));
        assertFalse(tbl.hasRole(tbl.TREASURY_ROLE(), admin));
        seedVault();
        vm.prank(admin);
        vm.expectRevert();
        tbl.withdrawHouseFunds(admin, 1e18);
    }

    function test_fuzz_depositExitRoundTrip(uint256 amount) public {
        amount = bound(amount, 1e18, 500_000e18);
        vm.prank(lp1);
        uint256 shares = vault.deposit(amount, lp1);
        vm.prank(lp1);
        vault.requestRedeem(shares);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(lp1);
        uint256 out = vault.claim(lp1);
        // No games played: round trip returns the deposit (±rounding dust).
        assertApproxEqAbs(out, amount, 10);
    }
}
