// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {V3TableTestBase} from "./utils/V3TableTestBase.sol";
import {BlackjackTableV3} from "../src/BlackjackTableV3.sol";
import {BlackjackLib} from "../src/lib/BlackjackLib.sol";

/// @notice Split-pair engine: sequencing, rules, payouts, accounting.
contract V3SplitTest is V3TableTestBase {
    uint256 internal constant W = 10e18;

    /// @dev Deal a pair of eights vs a dealer six and split it.
    function splitEights() internal returns (uint256 gameId) {
        gameId = dealHand(W, 7, 7, SIX); // 8+8 = 16 vs 6 (rank index 7 = eight)
        vm.prank(player);
        tbl.split(gameId);
    }

    /// @dev Dealer seed where playout from `upRank` is a 2-card natural 21.
    function findDealerNaturalSeed(uint8 upRank, uint256 salt) internal pure returns (bytes32) {
        (uint256 start, uint8 n) = BlackjackLib.pushCard(0, 0, upRank);
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("dnat", salt, i));
            (uint256 hand, uint8 count) = BlackjackLib.dealerPlay(start, n, seed);
            if (count == 2 && BlackjackLib.isNatural(hand, count)) return seed;
        }
    }

    // ------------------------------------------------------------ guards

    function test_cannotSplitNonPair() public {
        uint256 gameId = dealHand(W, TEN, 8, SIX);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV3.CannotSplit.selector, gameId));
        tbl.split(gameId);
    }

    function test_tenValuePairSplits() public {
        // K + 10: equal VALUE (10) even though ranks differ.
        uint256 gameId = dealHand(W, KING, TEN, SIX);
        vm.prank(player);
        tbl.split(gameId);
        assertTrue(tbl.getGame(gameId).split);
    }

    function test_noResplitNoDoubleNoSurrenderAfterSplit() public {
        uint256 gameId = splitEights();
        fulfill(gameId, findCardSeed(8, gameId)); // hand1: 8+8 = 16, PLAYER_TURN
        vm.startPrank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV3.CannotSplit.selector, gameId));
        tbl.split(gameId); // even though hand1 is again a pair of 8s
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV3.CannotDouble.selector, gameId));
        tbl.double(gameId);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV3.CannotSurrender.selector, gameId));
        tbl.surrender(gameId);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ flows

    function test_splitBothWin() public {
        uint256 escrowBefore = tbl.totalPlayerEscrow();
        uint256 houseBefore = tbl.houseFunds();
        uint256 gameId = splitEights();
        assertEq(tbl.totalPlayerEscrow(), escrowBefore + 2 * W); // second wager escrowed

        fulfill(gameId, findCardSeed(TEN, gameId)); // hand1: 18
        vm.prank(player);
        tbl.stand(gameId); // -> deal hand2's second card
        fulfill(gameId, findCardSeed(TEN, gameId + 1)); // hand2: 18
        vm.prank(player);
        tbl.stand(gameId); // -> dealer
        fulfill(gameId, findDealerSeedRule(SIX, 17, false, gameId));

        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        assertTrue(g.state == BlackjackTableV3.GameState.SETTLED);
        assertTrue(g.outcome == BlackjackTableV3.Outcome.PLAYER_WIN);
        assertTrue(g.outcome2 == BlackjackTableV3.Outcome.PLAYER_WIN);
        assertEq(g.payout, 4 * W); // both hands paid 1:1
        assertEq(tbl.houseFunds(), houseBefore - 2 * W);
        assertEq(tbl.totalPlayerEscrow(), escrowBefore);
        assertEq(tbl.totalReservedLiability(), 0);
    }

    function test_splitWinAndBust() public {
        uint256 gameId = splitEights();
        fulfill(gameId, findCardSeed(TEN, gameId)); // hand1: 18
        vm.prank(player);
        tbl.stand(gameId);
        fulfill(gameId, findCardSeed(SIX, gameId)); // hand2: 8+6 = 14
        vm.prank(player);
        tbl.hit(gameId);
        fulfill(gameId, findCardSeed(TEN, gameId + 2)); // hand2 busts at 24
        // hand1 is alive, so the dealer must still draw.
        assertTrue(
            tbl.getGame(gameId).state == BlackjackTableV3.GameState.AWAITING_DEALER_RANDOMNESS
        );
        fulfill(gameId, findDealerSeedRule(SIX, 19, false, gameId));

        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        assertTrue(g.outcome == BlackjackTableV3.Outcome.DEALER_WIN); // 18 < 19
        assertTrue(g.outcome2 == BlackjackTableV3.Outcome.PLAYER_BUST);
        assertEq(g.payout, 0);
    }

    function test_splitBothBustDealerNeverDraws() public {
        uint256 gameId = splitEights();
        fulfill(gameId, findCardSeed(SIX, gameId)); // hand1: 14
        vm.prank(player);
        tbl.hit(gameId);
        fulfill(gameId, findCardSeed(TEN, gameId + 1)); // hand1 busts (24) -> hand2
        fulfill(gameId, findCardSeed(SIX, gameId + 2)); // hand2: 14
        vm.prank(player);
        tbl.hit(gameId);
        fulfill(gameId, findCardSeed(KING, gameId + 3)); // hand2 busts (24)

        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        assertTrue(g.state == BlackjackTableV3.GameState.SETTLED);
        assertEq(g.dealerCount, 1); // ENHC: dealer never drew
        assertTrue(g.outcome == BlackjackTableV3.Outcome.PLAYER_BUST);
        assertTrue(g.outcome2 == BlackjackTableV3.Outcome.PLAYER_BUST);
        assertEq(g.payout, 0);
    }

    function test_splitAcesOneCardEach_and21NotNatural() public {
        uint256 gameId = dealHand(W, ACE, ACE, SIX);
        vm.prank(player);
        tbl.split(gameId);
        // Hand 1 draws a ten-value: 21 — auto-stands (no player turn), NOT a natural.
        fulfill(gameId, findCardSeed(KING, gameId));
        assertTrue(tbl.getGame(gameId).state == BlackjackTableV3.GameState.AWAITING_HIT_RANDOMNESS);
        // Hand 2 draws a 9: 20 — auto-stands into the dealer phase.
        fulfill(gameId, findCardSeed(8, gameId)); // 9-rank card = index 8
        assertTrue(
            tbl.getGame(gameId).state == BlackjackTableV3.GameState.AWAITING_DEALER_RANDOMNESS
        );
        fulfill(gameId, findDealerSeedRule(SIX, 19, false, gameId));

        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        assertTrue(g.outcome == BlackjackTableV3.Outcome.PLAYER_WIN);
        assertTrue(g.outcome2 == BlackjackTableV3.Outcome.PLAYER_WIN);
        // 1:1 on both hands — 21 after splitting aces is NOT paid 3:2.
        assertEq(g.payout, 4 * W);
    }

    function test_dealerNaturalTakesBothHands() public {
        uint256 gameId = dealHand(W, 7, 7, ACE); // pair of eights, dealer shows an ace
        vm.prank(player);
        tbl.split(gameId);
        fulfill(gameId, findCardSeed(TEN, gameId)); // hand1 18
        vm.prank(player);
        tbl.stand(gameId);
        fulfill(gameId, findCardSeed(TEN, gameId + 1)); // hand2 18
        vm.prank(player);
        tbl.stand(gameId);
        fulfill(gameId, findDealerNaturalSeed(ACE, gameId));

        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        assertTrue(g.outcome == BlackjackTableV3.Outcome.DEALER_BLACKJACK);
        assertTrue(g.outcome2 == BlackjackTableV3.Outcome.DEALER_BLACKJACK);
        assertEq(g.payout, 0); // ENHC: the whole doubled stake is lost
    }

    function test_splitPushMix() public {
        uint256 gameId = splitEights();
        fulfill(gameId, findCardSeed(TEN, gameId)); // hand1 18
        vm.prank(player);
        tbl.stand(gameId);
        fulfill(gameId, findCardSeed(9, gameId)); // hand2: 8+10 = 18? index 9 = rank 10
        vm.prank(player);
        tbl.stand(gameId);
        fulfill(gameId, findDealerSeedRule(SIX, 18, false, gameId));

        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        assertTrue(g.outcome == BlackjackTableV3.Outcome.PUSH);
        assertTrue(g.outcome2 == BlackjackTableV3.Outcome.PUSH);
        assertEq(g.payout, 2 * W); // both stakes returned
    }

    function test_timeoutRefundsMidSplit() public {
        uint256 balBefore = chip.balanceOf(player);
        uint256 gameId = splitEights(); // awaiting hand1's second card
        vm.warp(block.timestamp + tbl.randomnessTimeout() + 1);
        vm.prank(player);
        tbl.cancelTimedOutGame(gameId);
        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        assertEq(g.payout, 2 * W); // BOTH wagers refunded
        assertEq(chip.balanceOf(player), balBefore);
        assertEq(tbl.totalPlayerEscrow(), 0);
    }

    function test_reservationNeverExceededBySplit() public {
        // Reservation stays 2x the base wager through the whole split.
        uint256 gameId = splitEights();
        assertEq(tbl.getGame(gameId).reservedLiability, 2 * W);
        assertEq(tbl.totalReservedLiability(), 2 * W);
    }
}
