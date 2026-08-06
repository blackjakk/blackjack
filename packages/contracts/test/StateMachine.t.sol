// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TableTestBase} from "./utils/TableTestBase.sol";
import {BlackjackTable} from "../src/BlackjackTable.sol";

/// @notice State-machine transition and guard tests (Phase 1).
contract StateMachineTest is TableTestBase {
    // ---------------------------------------------------------- placeBet

    function test_placeBet_createsGameAwaitingInitialRandomness() public {
        uint256 before = chip.balanceOf(player);
        uint256 gameId = bet(100e18);

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.AWAITING_INITIAL_RANDOMNESS));
        assertEq(g.player, player);
        assertEq(g.wager, 100e18);
        assertEq(g.reservedLiability, 200e18);
        assertGt(g.pendingRequestId, 0);
        assertEq(g.pendingProvider, address(mock));

        assertEq(table.activeGameOf(player), gameId);
        assertEq(table.totalPlayerEscrow(), 100e18);
        assertEq(table.totalReservedLiability(), 200e18);
        assertEq(table.availableLiquidity(), HOUSE_BANKROLL - 200e18);
        assertEq(chip.balanceOf(player), before - 100e18);
    }

    function test_placeBet_rejectsOutOfBoundsWagers() public {
        vm.startPrank(player);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.WagerOutOfBounds.selector, MIN_WAGER - 1, MIN_WAGER, MAX_WAGER
            )
        );
        table.placeBet(MIN_WAGER - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.WagerOutOfBounds.selector, MAX_WAGER + 1, MIN_WAGER, MAX_WAGER
            )
        );
        table.placeBet(MAX_WAGER + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.WagerOutOfBounds.selector, 0, MIN_WAGER, MAX_WAGER
            )
        );
        table.placeBet(0);
        vm.stopPrank();
    }

    function test_placeBet_rejectsSecondSimultaneousGame() public {
        uint256 gameId = bet(100e18);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.ActiveGameExists.selector, gameId));
        table.placeBet(100e18);
    }

    function test_placeBet_rejectsWhenHouseCannotCover() public {
        // Drain house down to less than 2x the wager.
        vm.startPrank(admin);
        table.withdrawHouseFunds(admin, HOUSE_BANKROLL - 199e18);
        vm.stopPrank();

        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(BlackjackTable.InsufficientLiquidity.selector, 200e18, 199e18)
        );
        table.placeBet(100e18);
    }

    // ---------------------------------------------------------- guards

    function test_actionsRevertWhileAwaitingRandomness() public {
        uint256 gameId = bet(100e18);
        vm.startPrank(player);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.InvalidState.selector,
                gameId,
                BlackjackTable.GameState.AWAITING_INITIAL_RANDOMNESS
            )
        );
        table.hit();
        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.InvalidState.selector,
                gameId,
                BlackjackTable.GameState.AWAITING_INITIAL_RANDOMNESS
            )
        );
        table.stand();
        vm.stopPrank();
    }

    function test_actionsRevertWithNoActiveGame() public {
        vm.startPrank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.NoSuchGame.selector, 0));
        table.hit();
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.NoSuchGame.selector, 0));
        table.stand();
        vm.stopPrank();
    }

    function test_fulfill_revertsFromNonProvider() public {
        uint256 gameId = bet(100e18);
        uint256 requestId = table.getGame(gameId).pendingRequestId;
        // Direct call to the table from an address that is not the bound provider:
        // the (provider, requestId) mapping doesn't exist for the attacker.
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.UnknownRequest.selector, requestId));
        table.fulfillRandomness(requestId, bytes32(uint256(1)));
    }

    function test_fulfill_duplicateCallbackRejectedByTable() public {
        uint256 gameId = bet(100e18);
        uint256 requestId = table.getGame(gameId).pendingRequestId;
        bytes32 seed = findInitialSeed(TEN, SIX, FIVE, gameId);
        fulfill(gameId, seed);
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.PLAYER_TURN));

        // Bypass the mock's own guard to prove the TABLE rejects duplicates itself.
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.UnknownRequest.selector, requestId));
        mock.fulfillUnchecked(requestId, seed);
    }

    // ---------------------------------------------------------- transitions

    function test_initialDeal_toPlayerTurn() public {
        uint256 gameId = dealHand(100e18, TEN, SIX, FIVE);
        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.PLAYER_TURN));
        assertEq(g.playerCount, 2);
        assertEq(g.dealerCount, 1);
        (uint8 pTotal,, uint8 dTotal,) = table.handValues(gameId);
        assertEq(pTotal, 16);
        assertEq(dTotal, 5);
        assertEq(g.pendingRequestId, 0);
    }

    function test_initialDeal_naturalAutoStandsToDealerPhase() public {
        uint256 gameId = dealHand(100e18, ACE, KING, FIVE);
        BlackjackTable.Game memory g = table.getGame(gameId);
        // Natural: no player decision; a fresh dealer seed was requested automatically.
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS));
        assertGt(g.pendingRequestId, 0);
    }

    function test_hit_toAwaitingHitThenBackToPlayerTurn() public {
        uint256 gameId = dealHand(100e18, TEN, FIVE, SIX); // player 15
        vm.prank(player);
        table.hit();
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.AWAITING_HIT_RANDOMNESS));

        fulfill(gameId, findCardSeed(FIVE, gameId)); // 15 + 5 = 20
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.PLAYER_TURN));
        (uint8 pTotal,,,) = table.handValues(gameId);
        assertEq(pTotal, 20);
    }

    function test_hit_bustSettlesImmediately() public {
        uint256 gameId = dealHand(100e18, TEN, SIX, FIVE); // player 16
        vm.prank(player);
        table.hit();
        fulfill(gameId, findCardSeed(TEN, gameId)); // 26 → bust

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.SETTLED));
        assertEq(uint8(g.outcome), uint8(BlackjackTable.Outcome.PLAYER_BUST));
        // ENHC: dealer never drew beyond the up-card.
        assertEq(g.dealerCount, 1);
        assertEq(table.activeGameOf(player), 0);
    }

    function test_hit_to21AutoStands() public {
        uint256 gameId = dealHand(100e18, TEN, SIX, FIVE); // 16
        vm.prank(player);
        table.hit();
        fulfill(gameId, findCardSeed(FIVE, gameId)); // 21
        assertEq(
            uint8(gameState(gameId)), uint8(BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS)
        );
    }

    function test_stand_toDealerPhaseAndSettlement() public {
        uint256 gameId = dealHand(100e18, TEN, TEN, SIX); // player 20 vs dealer 6
        vm.prank(player);
        table.stand();
        assertEq(
            uint8(gameState(gameId)), uint8(BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS)
        );

        fulfill(gameId, findDealerSeed(SIX, 18, gameId)); // dealer finishes on 18
        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.SETTLED));
        assertEq(uint8(g.outcome), uint8(BlackjackTable.Outcome.PLAYER_WIN));
        assertEq(g.payout, 200e18);
    }

    function test_settledGame_rejectsAllActions_newGameAllowed() public {
        uint256 gameId = dealHand(100e18, TEN, SIX, FIVE);
        vm.prank(player);
        table.hit();
        fulfill(gameId, findCardSeed(TEN, gameId)); // bust → settled

        vm.startPrank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.NoSuchGame.selector, 0));
        table.hit();
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.NoSuchGame.selector, 0));
        table.stand();
        vm.stopPrank();

        // The slot is free again.
        uint256 next = bet(50e18);
        assertGt(next, gameId);
    }

    function test_accounting_zeroedAfterSettlement() public {
        uint256 gameId = dealHand(100e18, TEN, SIX, FIVE);
        vm.prank(player);
        table.hit();
        fulfill(gameId, findCardSeed(TEN, gameId)); // bust: house wins wager

        assertEq(table.totalPlayerEscrow(), 0);
        assertEq(table.totalReservedLiability(), 0);
        assertEq(table.houseFunds(), HOUSE_BANKROLL + 100e18);
        assertEq(table.availableLiquidity(), HOUSE_BANKROLL + 100e18);
    }
}
