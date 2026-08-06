// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TableTestBase} from "./utils/TableTestBase.sol";
import {BlackjackTable} from "../src/BlackjackTable.sol";

/// @notice Property-based tests over full games with arbitrary seeds and strategies.
contract FuzzGameFlowTest is TableTestBase {
    /// Play one complete game with a threshold strategy and arbitrary randomness;
    /// check settlement, payout bounds and accounting conservation.
    function testFuzz_fullGame_settlesWithBoundedPayoutAndConservation(
        uint256 wager,
        bytes32 entropy,
        uint8 standThreshold
    ) public {
        wager = bound(wager, MIN_WAGER, MAX_WAGER);
        standThreshold = uint8(bound(standThreshold, 4, 21));

        uint256 playerBefore = chip.balanceOf(player);
        uint256 tableBefore = chip.balanceOf(address(table));
        uint256 houseBefore = table.houseFunds();

        uint256 gameId = bet(wager);
        fulfill(gameId, keccak256(abi.encode(entropy, "deal")));

        uint256 round;
        while (gameState(gameId) == BlackjackTable.GameState.PLAYER_TURN) {
            (uint8 pTotal,,,) = table.handValues(gameId);
            vm.prank(player);
            if (pTotal < standThreshold) {
                table.hit();
            } else {
                table.stand();
            }
            BlackjackTable.Game memory g = table.getGame(gameId);
            if (g.pendingRequestId != 0) {
                fulfill(gameId, keccak256(abi.encode(entropy, "card", round++)));
            }
        }
        // Any remaining awaited phase (hit already fulfilled above; dealer phase here).
        if (gameState(gameId) == BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS) {
            fulfill(gameId, keccak256(abi.encode(entropy, "dealer")));
        }

        BlackjackTable.Game memory done = table.getGame(gameId);
        assertEq(uint8(done.state), uint8(BlackjackTable.GameState.SETTLED), "must settle");

        // Payout is one of: 0, push (stake), win (2x stake), natural (2.5x wager floored).
        uint256 payout = done.payout;
        bool valid = payout == 0 || payout == wager || payout == 2 * wager
            || payout == wager + (wager * 3) / 2;
        assertTrue(valid, "payout in allowed set");
        // Never exceeds escrow + reserved worst case.
        assertLe(payout, wager + done.reservedLiability, "payout bounded by reservation");

        // Accounting fully unwound.
        assertEq(table.totalPlayerEscrow(), 0);
        assertEq(table.totalReservedLiability(), 0);
        // Player delta mirrors house delta exactly; chips conserved.
        assertEq(chip.balanceOf(player), playerBefore - wager + payout);
        assertEq(table.houseFunds(), houseBefore + wager - payout);
        assertEq(chip.balanceOf(address(table)), tableBefore + wager - payout);
        assertEq(chip.balanceOf(address(table)), table.houseFunds(), "solvency");
    }

    /// The initial deal always leaves a legal position: 2 player cards, 1 dealer card,
    /// and a state consistent with the player's total.
    function testFuzz_initialDeal_alwaysLegal(bytes32 entropy) public {
        uint256 gameId = bet(MIN_WAGER);
        fulfill(gameId, entropy);
        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(g.playerCount, 2);
        assertEq(g.dealerCount, 1);
        (uint8 pTotal,,,) = table.handValues(gameId);
        if (pTotal == 21) {
            assertEq(uint8(g.state), uint8(BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS));
        } else {
            assertLt(pTotal, 21);
            assertEq(uint8(g.state), uint8(BlackjackTable.GameState.PLAYER_TURN));
        }
    }

    /// Hitting from PLAYER_TURN always yields exactly one more card and a legal follow-up
    /// state; the game can never be stuck.
    function testFuzz_hit_alwaysLegalFollowUp(bytes32 entropy) public {
        uint256 gameId = dealHand(MIN_WAGER, TEN, FIVE, SIX); // 15 vs 6
        vm.prank(player);
        table.hit();
        fulfill(gameId, entropy);

        BlackjackTable.Game memory g = table.getGame(gameId);
        assertEq(g.playerCount, 3);
        (uint8 pTotal,,,) = table.handValues(gameId);
        if (pTotal > 21) {
            assertEq(uint8(g.state), uint8(BlackjackTable.GameState.SETTLED));
            assertEq(uint8(g.outcome), uint8(BlackjackTable.Outcome.PLAYER_BUST));
        } else if (pTotal == 21) {
            assertEq(uint8(g.state), uint8(BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS));
        } else {
            assertEq(uint8(g.state), uint8(BlackjackTable.GameState.PLAYER_TURN));
        }
    }
}
