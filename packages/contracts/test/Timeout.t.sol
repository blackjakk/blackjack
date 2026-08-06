// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TableTestBase} from "./utils/TableTestBase.sol";
import {BlackjackTable} from "../src/BlackjackTable.sol";

/// @notice Randomness-timeout and cancellation tests (Phase 3).
contract TimeoutTest is TableTestBase {
    uint256 constant W = 100e18;

    function test_cancel_beforeTimeout_reverts() public {
        uint256 gameId = bet(W);
        uint256 cancellableAt = block.timestamp + table.randomnessTimeout();
        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(BlackjackTable.TimeoutNotReached.selector, gameId, cancellableAt)
        );
        table.cancelTimedOutGame(gameId);
    }

    function test_cancel_afterTimeout_refundsFullStake() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = bet(W);
        vm.warp(block.timestamp + table.randomnessTimeout());

        vm.prank(player);
        table.cancelTimedOutGame(gameId);

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.CANCELLED));
        assertEq(uint8(g.outcome), uint8(BlackjackTable.Outcome.CANCELLED_REFUND));
        assertEq(g.payout, W);
        assertEq(chip.balanceOf(player), playerBefore); // made whole
        assertEq(table.totalPlayerEscrow(), 0);
        assertEq(table.totalReservedLiability(), 0);
        assertEq(table.houseFunds(), HOUSE_BANKROLL);
        assertEq(table.activeGameOf(player), 0);

        bet(W); // slot free again
    }

    function test_cancel_doubledGame_refundsDoubleStake() public {
        uint256 playerBefore = chip.balanceOf(player);
        uint256 gameId = dealHand(W, FIVE, SIX, TEN);
        vm.prank(player);
        table.double(); // now awaiting the double card
        vm.warp(block.timestamp + table.randomnessTimeout());

        vm.prank(player);
        table.cancelTimedOutGame(gameId);
        assertEq(table.getGame(gameId).payout, 2 * W);
        assertEq(chip.balanceOf(player), playerBefore);
    }

    function test_cancel_byAdminWorks_byStrangerReverts() public {
        uint256 gameId = bet(W);
        vm.warp(block.timestamp + table.randomnessTimeout());

        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(
            abi.encodeWithSelector(BlackjackTable.NotAuthorizedToCancel.selector, gameId)
        );
        table.cancelTimedOutGame(gameId);

        vm.prank(admin);
        table.cancelTimedOutGame(gameId);
        // Admin cancel refunds the PLAYER, not the admin.
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.CANCELLED));
        assertEq(chip.balanceOf(player), PLAYER_STACK);
    }

    function test_cancel_duringPlayerTurn_reverts() public {
        // No pending randomness — nothing to bail out of mid-hand.
        uint256 gameId = dealHand(W, TEN, FIVE, SIX);
        vm.warp(block.timestamp + 30 days);
        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.InvalidState.selector, gameId, BlackjackTable.GameState.PLAYER_TURN
            )
        );
        table.cancelTimedOutGame(gameId);
    }

    function test_lateFulfill_afterCancel_reverts() public {
        uint256 gameId = bet(W);
        uint256 requestId = table.getGame(gameId).pendingRequestId;
        vm.warp(block.timestamp + table.randomnessTimeout());
        vm.prank(player);
        table.cancelTimedOutGame(gameId);

        // The beacon arrives late: the request binding was consumed at cancel time.
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.UnknownRequest.selector, requestId));
        mock.fulfill(requestId, bytes32(uint256(1)));
    }

    function test_fulfillWinsRaceOverCancel() public {
        uint256 gameId = bet(W);
        vm.warp(block.timestamp + table.randomnessTimeout());

        // Keeper lands first, even after the timeout: game proceeds normally.
        fulfill(gameId, findInitialSeed(TEN, FIVE, SIX, gameId));
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.PLAYER_TURN));

        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.InvalidState.selector, gameId, BlackjackTable.GameState.PLAYER_TURN
            )
        );
        table.cancelTimedOutGame(gameId);
    }

    function test_cancel_secondCancelReverts() public {
        uint256 gameId = bet(W);
        vm.warp(block.timestamp + table.randomnessTimeout());
        vm.startPrank(player);
        table.cancelTimedOutGame(gameId);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.InvalidState.selector, gameId, BlackjackTable.GameState.CANCELLED
            )
        );
        table.cancelTimedOutGame(gameId);
        vm.stopPrank();
    }

    function test_cancel_worksWhilePaused() public {
        uint256 gameId = bet(W);
        vm.prank(admin);
        table.pause();
        vm.warp(block.timestamp + table.randomnessTimeout());
        // A pause can never trap escrowed funds.
        vm.prank(player);
        table.cancelTimedOutGame(gameId);
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.CANCELLED));
        assertEq(chip.balanceOf(player), PLAYER_STACK);
    }

    function test_timeoutRestartsPerRequest() public {
        // Each randomness request gets its own full window: the timer restarts on every
        // new request (hit after a fulfilled deal, etc.).
        uint256 gameId = dealHand(W, TEN, FIVE, SIX); // deal fulfilled promptly
        vm.warp(block.timestamp + table.randomnessTimeout() - 1);
        vm.prank(player);
        table.hit(); // fresh request now
        uint256 cancellableAt = block.timestamp + table.randomnessTimeout();

        vm.warp(cancellableAt - 1);
        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(BlackjackTable.TimeoutNotReached.selector, gameId, cancellableAt)
        );
        table.cancelTimedOutGame(gameId);

        vm.warp(cancellableAt);
        vm.prank(player);
        table.cancelTimedOutGame(gameId);
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.CANCELLED));
    }
}
