// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TableTestBase} from "./utils/TableTestBase.sol";
import {BlackjackTable} from "../src/BlackjackTable.sol";

/// @notice Full game-flow and settlement/payout tests (Phase 2).
contract GameFlowTest is TableTestBase {
    uint256 constant W = 100e18;

    function assertSettled(uint256 gameId, BlackjackTable.Outcome outcome, uint256 payout)
        internal
        view
    {
        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.SETTLED), "state");
        assertEq(uint8(g.outcome), uint8(outcome), "outcome");
        assertEq(g.payout, payout, "payout");
        // Per-game reservation and escrow are always fully released on settlement.
        assertEq(table.totalPlayerEscrow(), 0, "escrow released");
        assertEq(table.totalReservedLiability(), 0, "reservation released");
    }

    // ---------------------------------------------------------- naturals

    function test_playerNatural_pays3to2() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(W, ACE, KING, FIVE); // natural vs 5 up
        // auto dealer phase; dealer cannot have a natural from a 5 up-card
        fulfill(gameId, findDealerSeed(FIVE, 19, gameId));

        assertSettled(gameId, BlackjackTable.Outcome.PLAYER_BLACKJACK, W + (W * 3) / 2);
        assertEq(chip.balanceOf(player), playerBefore + (W * 3) / 2);
        assertEq(table.houseFunds(), HOUSE_BANKROLL - (W * 3) / 2);
    }

    function test_playerNatural_vsDealerNatural_pushes() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(W, ACE, KING, TEN); // natural vs 10 up
        fulfill(gameId, findCardSeed(ACE, gameId)); // dealer draws ace: 2-card 21 = natural

        assertSettled(gameId, BlackjackTable.Outcome.PUSH, W);
        assertEq(chip.balanceOf(player), playerBefore);
        assertEq(table.houseFunds(), HOUSE_BANKROLL);
    }

    function test_dealerNatural_beatsTwenty() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(W, TEN, TEN, ACE); // player 20 vs A up
        vm.prank(player);
        table.stand();
        fulfill(gameId, findCardSeed(TEN, gameId)); // dealer A+10 = natural

        assertSettled(gameId, BlackjackTable.Outcome.DEALER_BLACKJACK, 0);
        assertEq(chip.balanceOf(player), playerBefore - W);
        assertEq(table.houseFunds(), HOUSE_BANKROLL + W);
    }

    function test_dealerNatural_beatsNonNatural21() public {
        uint256 gameId = dealHand(W, TEN, SIX, TEN); // 16 vs 10 up
        vm.prank(player);
        table.hit();
        fulfill(gameId, findCardSeed(FIVE, gameId)); // 21 (3 cards) → auto-stand
        fulfill(gameId, findCardSeed(ACE, gameId)); // dealer 10+A = natural

        assertSettled(gameId, BlackjackTable.Outcome.DEALER_BLACKJACK, 0);
    }

    function test_nonNatural21_vsDealer21_pushes() public {
        uint256 gameId = dealHand(W, TEN, SIX, SIX); // 16 vs 6 up
        vm.prank(player);
        table.hit();
        fulfill(gameId, findCardSeed(FIVE, gameId)); // 21 in 3 cards → auto-stand
        // From a 6 up-card, reaching 21 always takes 3+ cards → never a natural.
        fulfill(gameId, findDealerSeed(SIX, 21, gameId));

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertGe(g.dealerCount, 3);
        assertSettled(gameId, BlackjackTable.Outcome.PUSH, W);
    }

    // ---------------------------------------------------------- dealer behavior

    function test_dealerDrawsFromTwo_reaches17Plus() public {
        uint8 TWO = 1;
        uint256 gameId = dealHand(W, TEN, TEN, TWO); // player 20 vs 2 up
        vm.prank(player);
        table.stand();
        fulfill(gameId, findDealerSeed(TWO, 17, gameId));

        BlackjackTable.Game memory g = table.getGame(gameId);
        // From 2, reaching 17 requires at least two more cards.
        assertGe(g.dealerCount, 3);
        (,, uint8 dTotal,) = table.handValues(gameId);
        assertEq(dTotal, 17);
        assertSettled(gameId, BlackjackTable.Outcome.PLAYER_WIN, 2 * W);
    }

    function test_dealerStandsOnSoft17_playerEighteenWins() public {
        uint8 EIGHT = 7;
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(W, TEN, EIGHT, ACE); // player 18 vs A up
        vm.prank(player);
        table.stand();
        // Dealer draws a Six: A+6 = soft 17 → must stand (S17 rule) → 18 beats 17.
        fulfill(gameId, findCardSeed(SIX, gameId));

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(g.dealerCount, 2);
        (,, uint8 dTotal, bool dSoft) = table.handValues(gameId);
        assertEq(dTotal, 17);
        assertTrue(dSoft);
        assertSettled(gameId, BlackjackTable.Outcome.PLAYER_WIN, 2 * W);
        assertEq(chip.balanceOf(player), playerBefore + W);
    }

    function test_dealerBust_playerWins() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(W, TEN, SIX, TEN); // 16 vs 10
        vm.prank(player);
        table.stand();
        fulfill(gameId, findDealerBustSeed(TEN, gameId));

        (,, uint8 dTotal,) = table.handValues(gameId);
        assertGt(dTotal, 21);
        assertSettled(gameId, BlackjackTable.Outcome.PLAYER_WIN, 2 * W);
        assertEq(chip.balanceOf(player), playerBefore + W);
        assertEq(table.houseFunds(), HOUSE_BANKROLL - W);
    }

    // ---------------------------------------------------------- push / loss

    function test_push_returnsStake() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(W, TEN, TEN, TEN); // 20 vs 10
        vm.prank(player);
        table.stand();
        fulfill(gameId, findDealerSeed(TEN, 20, gameId));

        assertSettled(gameId, BlackjackTable.Outcome.PUSH, W);
        assertEq(chip.balanceOf(player), playerBefore);
        assertEq(table.houseFunds(), HOUSE_BANKROLL);
    }

    function test_dealerHigherTotal_wins() public {
        uint8 EIGHT = 7;
        uint256 gameId = dealHand(W, TEN, EIGHT, TEN); // player 18 vs 10
        vm.prank(player);
        table.stand();
        fulfill(gameId, findDealerSeed(TEN, 19, gameId));

        assertSettled(gameId, BlackjackTable.Outcome.DEALER_WIN, 0);
        assertEq(table.houseFunds(), HOUSE_BANKROLL + W);
    }

    // ---------------------------------------------------------- payout edges

    function test_maxWager_naturalMaxPayout() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(MAX_WAGER, ACE, TEN, SIX);
        fulfill(gameId, findDealerSeed(SIX, 18, gameId));

        uint256 expected = MAX_WAGER + (MAX_WAGER * 3) / 2;
        assertSettled(gameId, BlackjackTable.Outcome.PLAYER_BLACKJACK, expected);
        assertEq(chip.balanceOf(player), playerBefore + (MAX_WAGER * 3) / 2);
    }

    function test_blackjackPayout_floorsOddWei() public {
        uint256 oddWager = W + 1; // odd number of wei
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(oddWager, ACE, KING, FIVE);
        fulfill(gameId, findDealerSeed(FIVE, 18, gameId));

        uint256 winnings = (oddWager * 3) / 2; // floored: house keeps the odd wei
        assertSettled(gameId, BlackjackTable.Outcome.PLAYER_BLACKJACK, oddWager + winnings);
        assertEq(chip.balanceOf(player), playerBefore + winnings);
    }

    // ---------------------------------------------------------- conservation

    function test_chipConservation_acrossManyGames() public {
        uint256 total = chip.totalSupply();
        for (uint256 i; i < 5; ++i) {
            uint256 gameId = bet(W);
            fulfill(gameId, keccak256(abi.encode("any", i)));
            BlackjackTable.Game memory g = table.getGame(gameId);
            if (g.state == BlackjackTable.GameState.PLAYER_TURN) {
                vm.prank(player);
                table.stand();
                fulfill(gameId, keccak256(abi.encode("dealer", i)));
            } else if (g.state == BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS) {
                fulfill(gameId, keccak256(abi.encode("dealer", i)));
            }
            assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.SETTLED));
        }
        assertEq(chip.totalSupply(), total);
        assertEq(
            chip.balanceOf(address(table)),
            table.houseFunds() + table.totalPlayerEscrow(),
            "solvency"
        );
    }
}
