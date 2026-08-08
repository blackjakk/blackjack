// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InfiniteTestBase} from "./utils/InfiniteTestBase.sol";
import {InfiniteBlackjack} from "../src/InfiniteBlackjack.sol";
import {MockRandomnessProvider} from "../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlackjackLib} from "../src/lib/BlackjackLib.sol";

contract InfiniteBlackjackTest is InfiniteTestBase {
    uint8 internal constant TWO = 1;
    uint8 internal constant THREE = 2;
    uint8 internal constant SEVEN = 6;
    uint8 internal constant EIGHT = 7;
    uint8 internal constant NINE = 8;

    // ------------------------------------------------------------ full round

    /// @notice Three players, one shared deal, three different actions, one beacon
    ///         pair; each outcome recomputed independently and every unit accounted.
    function test_fullRoundThreePlayers_mixedActions() public {
        uint256 roundId = betAs(alice, W);
        assertEq(betAs(bob, W), roundId, "same round");
        assertEq(betAs(carol, 2 * W), roundId, "same round");
        assertEq(tbl.totalReservedLiability(), 2 * (W + W + 2 * W));

        lockAndDeal(SEVEN, SEVEN, NINE); // shared 14 vs dealer 9
        actAs(alice, InfiniteBlackjack.Action.STAND, 0);
        actAs(bob, InfiniteBlackjack.Action.HIT, 18);
        actAs(carol, InfiniteBlackjack.Action.DOUBLE, 0);

        uint256 aliceBefore = chip.balanceOf(alice);
        uint256 bobBefore = chip.balanceOf(bob);
        uint256 carolBefore = chip.balanceOf(carol);

        bytes32 drawSeed = findDrawSeedDealer(NINE, 18, 1);
        lockAndDraw(drawSeed); // early lock: everyone acted
        tbl.settle(10);
        assertEq(uint8(round().state), uint8(InfiniteBlackjack.RoundState.DONE));

        // Alice stood on 14 vs dealer 18: loses her wager.
        InfiniteBlackjack.Bet memory a = tbl.betOf(roundId, alice);
        assertEq(uint8(a.outcome), uint8(InfiniteBlackjack.Outcome.DEALER_WIN));
        assertEq(chip.balanceOf(alice), aliceBefore);

        _checkBobHit(roundId, drawSeed, bobBefore);
        _checkCarolDouble(roundId, drawSeed, carolBefore);

        assertEq(tbl.totalPlayerEscrow(), 0);
        assertEq(tbl.totalReservedLiability(), 0);
        assertSolvent();
    }

    /// @dev Bob hit to 18: recompute his exact hand from the shared draw seed.
    function _checkBobHit(uint256 roundId, bytes32 drawSeed, uint256 balanceBefore) internal view {
        (uint256 cards, uint8 count, uint8 total) =
            expectedHitHand(drawSeed, bob, round().playerCards, 18);
        InfiniteBlackjack.Bet memory b = tbl.betOf(roundId, bob);
        assertEq(b.cards, cards, "bob hand");
        assertEq(b.cardCount, count, "bob count");
        uint256 expected = total > 21 ? 0 : (total > 18 ? 2 * W : W); // vs dealer 18
        assertEq(b.payout, expected, "bob payout");
        assertEq(chip.balanceOf(bob), balanceBefore + expected);
    }

    /// @dev Carol doubled: exactly one draw card on a 4W stake (2W wager).
    function _checkCarolDouble(uint256 roundId, bytes32 drawSeed, uint256 balanceBefore)
        internal
        view
    {
        InfiniteBlackjack.Bet memory c = tbl.betOf(roundId, carol);
        assertEq(c.cardCount, 3, "double takes one card");
        bytes32 cSeed = tbl.playerDrawSeed(drawSeed, carol);
        (uint256 cc, uint8 cn) =
            BlackjackLib.pushCard(round().playerCards, 2, BlackjackLib.drawCard(cSeed, 0));
        assertEq(c.cards, cc, "carol hand");
        (uint8 cTotal,) = BlackjackLib.handValue(cc, cn);
        uint256 expected = cTotal > 21 ? 0 : (cTotal > 18 ? 8 * W : (cTotal == 18 ? 4 * W : 0));
        assertEq(c.payout, expected, "carol payout");
        assertEq(chip.balanceOf(carol), balanceBefore + expected);
    }

    // ------------------------------------------------------------ naturals

    function test_sharedNaturalSkipsActingAndPaysEveryone() public {
        uint256 roundId = betAs(alice, W);
        betAs(bob, 3 * W);
        lockAndDeal(ACE, KING, NINE); // shared natural; 9 up-card can never be one
        assertEq(uint8(round().state), uint8(InfiniteBlackjack.RoundState.DRAW_PENDING));

        fulfillPending(keccak256("any draw seed"));
        tbl.settle(10);

        InfiniteBlackjack.Bet memory a = tbl.betOf(roundId, alice);
        assertEq(uint8(a.outcome), uint8(InfiniteBlackjack.Outcome.PLAYER_BLACKJACK));
        assertEq(a.payout, W + (W * 3) / 2);
        InfiniteBlackjack.Bet memory b = tbl.betOf(roundId, bob);
        assertEq(b.payout, 3 * W + (3 * W * 3) / 2);
        assertSolvent();
    }

    function test_dealerNaturalTakesStandAndDoubledStakes() public {
        uint256 roundId = betAs(alice, W);
        betAs(bob, W);
        lockAndDeal(SEVEN, NINE, ACE); // shared 16 vs dealer ace
        actAs(alice, InfiniteBlackjack.Action.STAND, 0);
        actAs(bob, InfiniteBlackjack.Action.DOUBLE, 0);

        uint256 houseBefore = tbl.houseFunds();
        // Dealer natural AND a non-busting double card for bob (16 + <=5), so both
        // outcomes read DEALER_BLACKJACK (a busted double is labeled PLAYER_BUST,
        // matching v2 — same money either way).
        lockAndDraw(findDrawSeedDealerNaturalNoBust(ACE, bob, 16, 2));
        tbl.settle(10);

        assertEq(
            uint8(tbl.betOf(roundId, alice).outcome),
            uint8(InfiniteBlackjack.Outcome.DEALER_BLACKJACK)
        );
        assertEq(
            uint8(tbl.betOf(roundId, bob).outcome),
            uint8(InfiniteBlackjack.Outcome.DEALER_BLACKJACK)
        );
        // ENHC: the whole doubled stake is lost — house gains W + 2W.
        assertEq(tbl.houseFunds(), houseBefore + 3 * W);
        assertSolvent();
    }

    function test_surrenderKeepsHalfEvenAgainstDealerNatural() public {
        uint256 roundId = betAs(alice, W);
        lockAndDeal(SEVEN, NINE, ACE);
        actAs(alice, InfiniteBlackjack.Action.SURRENDER, 0);
        lockAndDraw(findDrawSeedDealerNatural(ACE, 3));
        tbl.settle(10);
        InfiniteBlackjack.Bet memory a = tbl.betOf(roundId, alice);
        // Same player-friendly surrender as the v2 tables: half back, always.
        assertEq(uint8(a.outcome), uint8(InfiniteBlackjack.Outcome.SURRENDERED));
        assertEq(a.payout, W / 2);
        assertSolvent();
    }

    // ------------------------------------------------------------ acting

    function test_afkPlayerAutoStands() public {
        uint256 roundId = betAs(alice, W);
        lockAndDeal(KING, KING, NINE); // 20 — auto-stand should win vs dealer 18
        uint256 before = chip.balanceOf(alice);
        lockAndDraw(findDrawSeedDealer(NINE, 18, 4)); // warps past the act deadline
        tbl.settle(10);
        InfiniteBlackjack.Bet memory a = tbl.betOf(roundId, alice);
        assertEq(uint8(a.action), uint8(InfiniteBlackjack.Action.PENDING));
        assertEq(uint8(a.outcome), uint8(InfiniteBlackjack.Outcome.PLAYER_WIN));
        assertEq(chip.balanceOf(alice), before + 2 * W);
    }

    function test_hitToTargetDrawsExactlyToCommitment() public {
        uint256 roundId = betAs(alice, W);
        lockAndDeal(TWO, THREE, EIGHT); // 5 vs dealer 8
        actAs(alice, InfiniteBlackjack.Action.HIT, 19);
        bytes32 drawSeed = findDrawSeedDealer(EIGHT, 17, 5);
        uint256 shared = round().playerCards;
        lockAndDraw(drawSeed);
        tbl.settle(10);

        (uint256 cards, uint8 count, uint8 total) = expectedHitHand(drawSeed, alice, shared, 19);
        InfiniteBlackjack.Bet memory a = tbl.betOf(roundId, alice);
        assertEq(a.cards, cards);
        assertEq(a.cardCount, count);
        assertTrue(total > 21 || total >= 19, "drew to target or bust");
        uint256 expected = total > 21 ? 0 : (total > 17 ? 2 * W : (total == 17 ? W : 0));
        assertEq(a.payout, expected);
    }

    function test_actValidation() public {
        betAs(alice, W);

        vm.expectRevert(); // acting before the deal
        vm.prank(alice);
        tbl.act(InfiniteBlackjack.Action.STAND, 0);

        lockAndDeal(SEVEN, SEVEN, NINE); // shared 14

        vm.prank(bob); // never bet
        vm.expectRevert(abi.encodeWithSelector(InfiniteBlackjack.NoBet.selector, 1));
        tbl.act(InfiniteBlackjack.Action.STAND, 0);

        vm.prank(alice); // target must beat the current total
        vm.expectRevert(InfiniteBlackjack.InvalidAction.selector);
        tbl.act(InfiniteBlackjack.Action.HIT, 14);

        vm.prank(alice);
        vm.expectRevert(InfiniteBlackjack.InvalidAction.selector);
        tbl.act(InfiniteBlackjack.Action.HIT, 22);

        actAs(alice, InfiniteBlackjack.Action.HIT, 18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InfiniteBlackjack.AlreadyActed.selector, 1));
        tbl.act(InfiniteBlackjack.Action.STAND, 0);
    }

    function test_actAfterDeadlineReverts() public {
        betAs(alice, W);
        lockAndDeal(SEVEN, SEVEN, NINE);
        vm.warp(round().actDeadline);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InfiniteBlackjack.ActingClosed.selector, 1));
        tbl.act(InfiniteBlackjack.Action.STAND, 0);
    }

    function test_earlyLockOnlyWhenAllActed() public {
        betAs(alice, W);
        betAs(bob, W);
        lockAndDeal(SEVEN, SEVEN, NINE);
        actAs(alice, InfiniteBlackjack.Action.STAND, 0);
        vm.expectRevert(abi.encodeWithSelector(InfiniteBlackjack.ActionsStillOpen.selector, 1));
        tbl.lockActions();
        actAs(bob, InfiniteBlackjack.Action.STAND, 0);
        tbl.lockActions(); // before the deadline — everyone has committed
        assertEq(uint8(round().state), uint8(InfiniteBlackjack.RoundState.DRAW_PENDING));
    }

    // ------------------------------------------------------------ windows / joining

    function test_bettingWindowClosesRoundToNewJoiners() public {
        betAs(alice, W);
        vm.warp(round().betDeadline);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InfiniteBlackjack.BettingClosed.selector, 1));
        tbl.placeBet(W);
    }

    function test_lockDealBeforeDeadlineReverts() public {
        betAs(alice, W);
        vm.expectRevert(abi.encodeWithSelector(InfiniteBlackjack.BettingStillOpen.selector, 1));
        tbl.lockDeal();
    }

    function test_oneBetPerPlayerPerRound() public {
        betAs(alice, W);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InfiniteBlackjack.AlreadyBet.selector, 1));
        tbl.placeBet(W);
    }

    function test_newRoundOpensAfterDone() public {
        betAs(alice, W);
        lockAndDeal(KING, KING, NINE);
        lockAndDraw(findDrawSeedDealer(NINE, 18, 6));
        tbl.settle(10);
        assertEq(betAs(bob, W), 2, "fresh round id");
        assertEq(uint8(round().state), uint8(InfiniteBlackjack.RoundState.BETTING));
    }

    // ------------------------------------------------------------ settle sweep

    function test_settleIsPaginatedAndIdempotent() public {
        betAs(alice, W);
        betAs(bob, W);
        betAs(carol, W);
        lockAndDeal(KING, KING, NINE);
        lockAndDraw(findDrawSeedDealer(NINE, 18, 7));

        tbl.settle(1);
        assertEq(uint8(round().state), uint8(InfiniteBlackjack.RoundState.SETTLING));
        assertTrue(tbl.betOf(1, alice).settled);
        assertFalse(tbl.betOf(1, carol).settled);
        tbl.settle(2);
        assertEq(uint8(round().state), uint8(InfiniteBlackjack.RoundState.DONE));
        assertEq(tbl.totalPlayerEscrow(), 0);
        assertEq(tbl.totalReservedLiability(), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                InfiniteBlackjack.InvalidRoundState.selector, 1, InfiniteBlackjack.RoundState.DONE
            )
        );
        tbl.settle(1);
    }

    // ------------------------------------------------------------ cancel / refunds

    function test_cancelStuckDrawRefundsEveryoneIncludingDoubles() public {
        uint256 roundId = betAs(alice, W);
        betAs(bob, W);
        betAs(carol, 2 * W);
        lockAndDeal(SEVEN, SEVEN, NINE);
        actAs(alice, InfiniteBlackjack.Action.STAND, 0);
        actAs(carol, InfiniteBlackjack.Action.DOUBLE, 0); // stake now 4W
        vm.warp(round().actDeadline);
        tbl.lockActions(); // DRAW_PENDING, beacon never arrives

        uint256 aliceBefore = chip.balanceOf(alice);
        uint256 bobBefore = chip.balanceOf(bob);
        uint256 carolBefore = chip.balanceOf(carol);

        vm.expectRevert(); // too early
        tbl.cancelRound(roundId);
        vm.warp(block.timestamp + tbl.randomnessTimeout());
        tbl.cancelRound(roundId);

        tbl.refund(roundId, 1); // paginated
        tbl.refund(roundId, 10);
        assertEq(chip.balanceOf(alice), aliceBefore + W);
        assertEq(chip.balanceOf(bob), bobBefore + W);
        assertEq(chip.balanceOf(carol), carolBefore + 4 * W);
        assertEq(
            uint8(tbl.betOf(roundId, bob).outcome),
            uint8(InfiniteBlackjack.Outcome.CANCELLED_REFUND)
        );
        assertEq(tbl.totalPlayerEscrow(), 0);
        assertEq(tbl.totalReservedLiability(), 0);
        assertSolvent();
    }

    function test_newRoundOpensWhileOldRefundsPending() public {
        uint256 oldRound = betAs(alice, W);
        vm.warp(round().betDeadline);
        tbl.lockDeal();
        vm.warp(block.timestamp + tbl.randomnessTimeout());
        tbl.cancelRound(oldRound);

        uint256 fresh = betAs(bob, W); // opens round 2 before round 1 is refunded
        assertEq(fresh, oldRound + 1);
        uint256 before = chip.balanceOf(alice);
        tbl.refund(oldRound, 10);
        assertEq(chip.balanceOf(alice), before + W);
    }

    function test_stuckBettingIsCancellableAfterTimeout() public {
        uint256 roundId = betAs(alice, W);
        vm.warp(uint256(round().betDeadline) + tbl.randomnessTimeout());
        tbl.cancelRound(roundId);
        uint256 before = chip.balanceOf(alice);
        tbl.refund(roundId, 10);
        assertEq(chip.balanceOf(alice), before + W);
    }

    function test_lateBeaconCannotTouchCancelledRound() public {
        uint256 roundId = betAs(alice, W);
        vm.warp(round().betDeadline);
        tbl.lockDeal();
        uint256 requestId = round().pendingRequestId;
        vm.warp(block.timestamp + tbl.randomnessTimeout());
        tbl.cancelRound(roundId);
        vm.expectRevert(
            abi.encodeWithSelector(InfiniteBlackjack.UnknownRequest.selector, requestId)
        );
        mock.fulfillUnchecked(requestId, keccak256("late"));
    }

    // ------------------------------------------------------------ liquidity

    function test_betRevertsWhenLiabilityExceedsLiquidity() public {
        InfiniteBlackjack poor = new InfiniteBlackjack(
            IERC20(address(chip)),
            IRandomnessProvider(address(mock)),
            _rules(),
            MIN_WAGER,
            MAX_WAGER,
            BET_WINDOW,
            ACT_WINDOW,
            100,
            admin
        );
        vm.startPrank(admin);
        chip.mint(admin, 15e18);
        chip.approve(address(poor), 15e18);
        poor.fundHouse(15e18);
        vm.stopPrank();
        vm.startPrank(alice);
        chip.approve(address(poor), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(InfiniteBlackjack.InsufficientLiquidity.selector, 20e18, 15e18)
        );
        poor.placeBet(W);
        vm.stopPrank();
    }

    function test_reservationsScaleWithPlayers() public {
        betAs(alice, W);
        betAs(bob, 5 * W);
        assertEq(tbl.totalReservedLiability(), 12 * W);
        assertEq(tbl.availableLiquidity(), HOUSE_BANKROLL - 12 * W);
        assertEq(tbl.totalPlayerEscrow(), 6 * W);
    }

    // ------------------------------------------------------------ fuzz soak

    /// @notice Random players/wagers/actions/seeds through full rounds; the books
    ///         must balance to zero escrow and zero reservations after every round.
    function testFuzz_roundSoak(uint256 fseed) public {
        address[3] memory players = [alice, bob, carol];
        for (uint256 n; n < 3; ++n) {
            bool[3] memory joined;
            uint256 count;
            for (uint256 i; i < 3; ++i) {
                if (uint256(keccak256(abi.encode(fseed, n, i, "join"))) % 4 == 0) continue;
                uint256 wager =
                    ((uint256(keccak256(abi.encode(fseed, n, i, "wager"))) % 100) + 1) * 1e18;
                betAs(players[i], wager);
                joined[i] = true;
                ++count;
            }
            if (count == 0) continue;

            vm.warp(round().betDeadline);
            tbl.lockDeal();
            fulfillPending(keccak256(abi.encode(fseed, n, "deal")));

            if (round().state == InfiniteBlackjack.RoundState.ACTING) {
                (uint8 total,) = BlackjackLib.handValue(round().playerCards, 2);
                for (uint256 i; i < 3; ++i) {
                    if (!joined[i]) continue;
                    uint256 pick = uint256(keccak256(abi.encode(fseed, n, i, "act"))) % 5;
                    if (pick == 0) {
                        actAs(players[i], InfiniteBlackjack.Action.STAND, 0);
                    } else if (pick == 1 && total < 21) {
                        uint8 target = total + 1
                            + uint8(uint256(keccak256(abi.encode(fseed, n, i, "t"))) % (21 - total));
                        actAs(players[i], InfiniteBlackjack.Action.HIT, target);
                    } else if (pick == 2) {
                        actAs(players[i], InfiniteBlackjack.Action.DOUBLE, 0);
                    } else if (pick == 3) {
                        actAs(players[i], InfiniteBlackjack.Action.SURRENDER, 0);
                    } // pick == 4: AFK — auto-stand
                }
                InfiniteBlackjack.Round memory r = round();
                if (r.actedCount < r.playerCount) vm.warp(r.actDeadline);
                tbl.lockActions();
            }
            fulfillPending(keccak256(abi.encode(fseed, n, "draw")));
            tbl.settle(10);

            assertEq(uint8(round().state), uint8(InfiniteBlackjack.RoundState.DONE));
            assertEq(tbl.totalPlayerEscrow(), 0, "escrow leak");
            assertEq(tbl.totalReservedLiability(), 0, "reservation leak");
            assertSolvent();
        }
    }
}
