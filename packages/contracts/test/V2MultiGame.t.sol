// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {V2TableTestBase} from "./utils/V2TableTestBase.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";

/// @notice Multiple concurrent games per player: enumeration, caps, isolation.
contract V2MultiGameTest is V2TableTestBase {
    function _maxConcurrent() internal pure override returns (uint256) {
        return 3;
    }

    function _contains(uint256[] memory list, uint256 x) internal pure returns (bool) {
        for (uint256 i; i < list.length; i++) {
            if (list[i] == x) return true;
        }
        return false;
    }

    function test_threeConcurrentGames() public {
        uint256 g1 = bet(10e18);
        uint256 g2 = bet(20e18);
        uint256 g3 = bet(30e18);
        assertTrue(g1 != g2 && g2 != g3);

        uint256[] memory active = tbl.activeGamesOf(player);
        assertEq(active.length, 3);
        assertTrue(_contains(active, g1) && _contains(active, g2) && _contains(active, g3));
        assertEq(tbl.totalPlayerEscrow(), 60e18);
        assertEq(tbl.totalReservedLiability(), 120e18);
    }

    function test_capEnforced() public {
        bet(1e18);
        bet(1e18);
        bet(1e18);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV2.TooManyActiveGames.selector, 3, 3));
        tbl.placeBet(1e18);
    }

    /// @dev Settling the MIDDLE game exercises the swap-and-pop bookkeeping.
    function test_settleMiddleGameKeepsOthersTracked() public {
        uint256 g1 = bet(10e18);
        uint256 g2 = bet(10e18);
        uint256 g3 = bet(10e18);

        // Deal g2 a stand-able hand and play it to settlement.
        fulfill(g2, findInitialSeed(TEN, 8, SIX, g2)); // 18 vs 6
        standAndDealer(g2, SIX, 17); // dealer 17: player wins 18 > 17

        assertTrue(gameState(g2) == BlackjackTableV2.GameState.SETTLED);
        uint256[] memory active = tbl.activeGamesOf(player);
        assertEq(active.length, 2);
        assertTrue(_contains(active, g1) && _contains(active, g3));
        assertFalse(_contains(active, g2));

        // The remaining games still fulfill and settle independently.
        fulfill(g1, findInitialSeed(TEN, 9, SIX, g1)); // 19 vs 6
        standAndDealer(g1, SIX, 18);
        assertTrue(tbl.getGame(g1).outcome == BlackjackTableV2.Outcome.PLAYER_WIN);
        assertEq(tbl.activeGameCountOf(player), 1);
        assertEq(tbl.activeGamesOf(player)[0], g3);
    }

    function test_actionsRequireOwnership() public {
        uint256 gameId = bet(10e18);
        fulfill(gameId, findInitialSeed(TEN, 8, SIX, gameId));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV2.NotYourGame.selector, gameId));
        tbl.hit(gameId);
    }

    function test_cancelOneOfManyLeavesOthers() public {
        uint256 g1 = bet(10e18);
        uint256 g2 = bet(10e18);
        // g1 stays AWAITING_INITIAL_RANDOMNESS; cancel it after the timeout.
        vm.warp(block.timestamp + tbl.randomnessTimeout() + 1);
        vm.prank(player);
        tbl.cancelTimedOutGame(g1);

        assertTrue(gameState(g1) == BlackjackTableV2.GameState.CANCELLED);
        assertEq(tbl.activeGameCountOf(player), 1);
        assertEq(tbl.activeGamesOf(player)[0], g2);
        // g2's request still fulfills after the warp (mock has no freshness rule).
        fulfill(g2, findInitialSeed(TEN, 8, SIX, g2));
        assertTrue(gameState(g2) == BlackjackTableV2.GameState.PLAYER_TURN);
    }

    function test_setMaxConcurrentGames() public {
        bet(1e18);
        bet(1e18);
        vm.prank(admin);
        tbl.setMaxConcurrentGames(1);
        // Existing games unaffected; new bets blocked while above the cap.
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV2.TooManyActiveGames.selector, 2, 1));
        tbl.placeBet(1e18);

        vm.prank(admin);
        vm.expectRevert(BlackjackTableV2.InvalidConfig.selector);
        tbl.setMaxConcurrentGames(0);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        tbl.setMaxConcurrentGames(2);
    }

    function test_perGameLiquidityReservation() public {
        // Each game reserves 2x its own wager; the sum must gate new bets.
        uint256 avail = tbl.availableLiquidity();
        uint256 big = MAX_WAGER;
        uint256 n = avail / (big * 2);
        // Fill remaining liquidity with max-wager games (cap allows 3).
        for (uint256 i; i < n && i < 3; i++) {
            bet(big);
        }
        if (n < 3 && tbl.availableLiquidity() < big * 2) {
            vm.prank(player);
            vm.expectRevert();
            tbl.placeBet(big);
        }
    }
}
