// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TableTestBase} from "./utils/TableTestBase.sol";
import {BlackjackTable} from "../src/BlackjackTable.sol";

/// @notice Double-down rules and accounting (Phase 3).
contract DoubleDownTest is TableTestBase {
    uint256 constant W = 100e18;

    function dealAndDouble() internal returns (uint256 gameId) {
        gameId = dealHand(W, FIVE, SIX, TEN); // player 11 vs 10 up
        vm.prank(player);
        table.double();
    }

    function test_double_escrowsExtraWager_keepsReservation() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealAndDouble();

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertTrue(g.doubled);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.AWAITING_HIT_RANDOMNESS));
        assertEq(table.totalPlayerEscrow(), 2 * W);
        // Reservation was 2x from the start — unchanged, and by construction sufficient.
        assertEq(table.totalReservedLiability(), 2 * W);
        // Bet (W) + double (W) have both left the player's wallet.
        assertEq(chip.balanceOf(player), playerBefore - 2 * W);
    }

    function test_double_winPaysDoubleStake() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealAndDouble();
        fulfill(gameId, findCardSeed(TEN, gameId)); // 21 in three cards
        fulfill(gameId, findDealerSeed(TEN, 20, gameId)); // dealer 20

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.outcome), uint8(BlackjackTable.Outcome.PLAYER_WIN));
        assertEq(g.payout, 4 * W); // 2W stake back + 2W winnings
        assertEq(chip.balanceOf(player), playerBefore + 2 * W);
        assertEq(table.houseFunds(), HOUSE_BANKROLL - 2 * W);
        assertEq(table.totalPlayerEscrow(), 0);
        assertEq(table.totalReservedLiability(), 0);
    }

    function test_double_lossLosesDoubleStake() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealAndDouble();
        fulfill(gameId, findCardSeed(SIX, gameId)); // 17
        fulfill(gameId, findDealerSeed(TEN, 20, gameId)); // dealer 20 beats 17

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.outcome), uint8(BlackjackTable.Outcome.DEALER_WIN));
        assertEq(g.payout, 0);
        assertEq(chip.balanceOf(player), playerBefore - 2 * W);
        assertEq(table.houseFunds(), HOUSE_BANKROLL + 2 * W);
    }

    function test_double_pushReturnsDoubleStake() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(W, FIVE, SIX, SIX); // player 11 vs 6 up
        vm.prank(player);
        table.double();
        fulfill(gameId, findCardSeed(TEN, gameId)); // 21 (three cards, not natural)
        // From a 6 up-card, 21 always takes 3+ cards → guaranteed non-natural.
        fulfill(gameId, findDealerSeed(SIX, 21, gameId));

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.outcome), uint8(BlackjackTable.Outcome.PUSH));
        assertEq(g.payout, 2 * W);
        assertEq(chip.balanceOf(player), playerBefore);
    }

    function test_double_bustSettlesImmediately() public {
        uint256 gameId = dealHand(W, TEN, SIX, FIVE); // 16 vs 5
        vm.prank(player);
        table.double();
        fulfill(gameId, findCardSeed(TEN, gameId)); // 26 bust

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.SETTLED));
        assertEq(uint8(g.outcome), uint8(BlackjackTable.Outcome.PLAYER_BUST));
        assertEq(g.dealerCount, 1); // dealer never drew
        assertEq(table.houseFunds(), HOUSE_BANKROLL + 2 * W);
    }

    function test_double_vsDealerNatural_losesWholeDoubledStake() public {
        // ENHC: dealer blackjack takes the entire stake including the doubled portion.
        uint256 gameId = dealHand(W, FIVE, SIX, ACE); // 11 vs A up
        vm.prank(player);
        table.double();
        fulfill(gameId, findCardSeed(SIX, gameId)); // 17
        fulfill(gameId, findCardSeed(TEN, gameId)); // dealer A+10 natural

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.outcome), uint8(BlackjackTable.Outcome.DEALER_BLACKJACK));
        assertEq(g.payout, 0);
        assertEq(table.houseFunds(), HOUSE_BANKROLL + 2 * W);
    }

    function test_double_takesExactlyOneCard_thenDealer() public {
        uint256 gameId = dealAndDouble();
        fulfill(gameId, findCardSeed(FIVE, gameId)); // 16, no bust
        // Even at 16, a doubled hand cannot hit again: it auto-advanced to dealer phase.
        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(g.playerCount, 3);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS));
    }

    function test_double_rejectedAfterHit() public {
        uint256 gameId = dealHand(W, FIVE, SIX, TEN); // 11
        vm.prank(player);
        table.hit();
        fulfill(gameId, findCardSeed(FIVE, gameId)); // 16, three cards
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.CannotDouble.selector, gameId));
        table.double();
    }

    function test_double_rejectedOutsidePlayerTurn() public {
        uint256 gameId = bet(W);
        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.InvalidState.selector,
                gameId,
                BlackjackTable.GameState.AWAITING_INITIAL_RANDOMNESS
            )
        );
        table.double();
    }

    function test_double_rejectedWithoutFunds() public {
        // Player spends everything else, keeping only the original wager escrowed.
        uint256 gameId = dealHand(W, FIVE, SIX, TEN);
        vm.startPrank(player);
        chip.transfer(admin, chip.balanceOf(player));
        vm.expectRevert(); // ERC20InsufficientBalance from transferFrom
        table.double();
        vm.stopPrank();
        // Game unaffected.
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.PLAYER_TURN));
        assertFalse(table.getGame(gameId).doubled);
    }
}
