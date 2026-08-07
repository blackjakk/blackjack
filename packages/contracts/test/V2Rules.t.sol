// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {V2TableTestBase} from "./utils/V2TableTestBase.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {BlackjackLib} from "../src/lib/BlackjackLib.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Rule-set validation + rule-dependent behavior on v2 tables.
contract V2RulesValidationTest is V2TableTestBase {
    function _mk(uint16 num, uint16 den) internal returns (address) {
        return factory.createTable(
            BlackjackTableV2.Rules({
                dealerHitsSoft17: false,
                blackjackNum: num,
                blackjackDen: den,
                doubleRule: BlackjackTableV2.DoubleRule.ANY_TWO,
                lateSurrender: false
            }),
            MIN_WAGER,
            MAX_WAGER,
            5,
            admin
        );
    }

    function test_rulesGetterMatches() public view {
        BlackjackTableV2.Rules memory r = tbl.rules();
        assertFalse(r.dealerHitsSoft17);
        assertEq(r.blackjackNum, 3);
        assertEq(r.blackjackDen, 2);
        assertTrue(r.doubleRule == BlackjackTableV2.DoubleRule.ANY_TWO);
        assertFalse(r.lateSurrender);
    }

    function test_payoutBounds() public {
        // 1:1 and 2:1 are the inclusive bounds; 6:5 is inside.
        _mk(1, 1);
        _mk(2, 1);
        _mk(6, 5);
        vm.expectRevert(BlackjackTableV2.InvalidRules.selector);
        _mk(3, 0); // zero denominator
        vm.expectRevert(BlackjackTableV2.InvalidRules.selector);
        _mk(4, 5); // below 1:1
        vm.expectRevert(BlackjackTableV2.InvalidRules.selector);
        _mk(21, 10); // above 2:1
    }

    function test_maxConcurrentBounds() public {
        vm.expectRevert(BlackjackTableV2.InvalidConfig.selector);
        factory.createTable(_rules(), MIN_WAGER, MAX_WAGER, 0, admin);
        vm.expectRevert(BlackjackTableV2.InvalidConfig.selector);
        factory.createTable(_rules(), MIN_WAGER, MAX_WAGER, 33, admin);
    }

    function test_dealerSoft17LibRule() public pure {
        // A + 6 = soft 17: S17 stands, H17 draws.
        (uint256 soft17, uint8 n1) = BlackjackLib.pushCard(0, 0, 0); // Ace
        (soft17, n1) = BlackjackLib.pushCard(soft17, n1, 5); // Six
        assertFalse(BlackjackLib.dealerShouldDrawRule(soft17, n1, false));
        assertTrue(BlackjackLib.dealerShouldDrawRule(soft17, n1, true));
        // 10 + 7 = hard 17: both stand.
        (uint256 hard17, uint8 n2) = BlackjackLib.pushCard(0, 0, 9);
        (hard17, n2) = BlackjackLib.pushCard(hard17, n2, 6);
        assertFalse(BlackjackLib.dealerShouldDrawRule(hard17, n2, false));
        assertFalse(BlackjackLib.dealerShouldDrawRule(hard17, n2, true));
        // 16: both draw.
        (uint256 h16, uint8 n3) = BlackjackLib.pushCard(0, 0, 9);
        (h16, n3) = BlackjackLib.pushCard(h16, n3, 5);
        assertTrue(BlackjackLib.dealerShouldDrawRule(h16, n3, false));
        assertTrue(BlackjackLib.dealerShouldDrawRule(h16, n3, true));
    }
}

/// @notice H17 table: the onchain dealer playout must match the H17 lib playout.
contract V2H17Test is V2TableTestBase {
    function _rules() internal pure override returns (BlackjackTableV2.Rules memory) {
        return BlackjackTableV2.Rules({
            dealerHitsSoft17: true,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: BlackjackTableV2.DoubleRule.ANY_TWO,
            lateSurrender: false
        });
    }

    function test_dealerPlaysH17() public {
        // Player 10+9 (19) stands; dealer up-card Ace plays out under H17 to 18.
        uint256 gameId = dealHand(10e18, TEN, 8, ACE);
        bytes32 dSeed = findDealerSeedRule(ACE, 18, true, gameId);

        // The exact final hand must equal the offchain H17 playout of that seed,
        // starting from the ACTUAL dealt up-card (any suit of the searched rank).
        BlackjackTableV2.Game memory g0 = tbl.getGame(gameId);
        (uint256 wantHand, uint8 wantCount) =
            BlackjackLib.dealerPlayRule(g0.dealerCards, g0.dealerCount, dSeed, true);

        vm.prank(player);
        tbl.stand(gameId);
        fulfill(gameId, dSeed);

        BlackjackTableV2.Game memory g = tbl.getGame(gameId);
        assertEq(g.dealerCards, wantHand);
        assertEq(g.dealerCount, wantCount);
        assertTrue(g.state == BlackjackTableV2.GameState.SETTLED);
    }
}

/// @notice 6:5 blackjack payout table.
contract V2SixFiveTest is V2TableTestBase {
    function _rules() internal pure override returns (BlackjackTableV2.Rules memory) {
        return BlackjackTableV2.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 6,
            blackjackDen: 5,
            doubleRule: BlackjackTableV2.DoubleRule.ANY_TWO,
            lateSurrender: false
        });
    }

    function test_naturalPaysSixToFive() public {
        uint256 wager = 10e18;
        uint256 balBefore = chip.balanceOf(player);
        uint256 houseBefore = tbl.houseFunds();

        // Natural A+K; dealer up 6 plays to 18 (no dealer natural possible).
        uint256 gameId = dealHand(wager, ACE, KING, SIX);
        // Natural auto-stands into the dealer phase.
        fulfill(gameId, findDealerSeedRule(SIX, 18, false, gameId));

        BlackjackTableV2.Game memory g = tbl.getGame(gameId);
        assertTrue(g.outcome == BlackjackTableV2.Outcome.PLAYER_BLACKJACK);
        uint256 expectedPayout = wager + (wager * 6) / 5; // 22e18
        assertEq(g.payout, expectedPayout);
        assertEq(chip.balanceOf(player), balBefore - wager + expectedPayout);
        assertEq(tbl.houseFunds(), houseBefore - (expectedPayout - wager));
    }
}

/// @notice Double-window rules (hard 9-11 / 10-11 / none).
contract V2DoubleWindowTest is V2TableTestBase {
    function _rules() internal pure override returns (BlackjackTableV2.Rules memory) {
        return BlackjackTableV2.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: BlackjackTableV2.DoubleRule.NINE_TO_ELEVEN,
            lateSurrender: false
        });
    }

    function test_hardNineCanDouble() public {
        uint256 gameId = dealHand(10e18, FIVE, 3, TEN); // 5+4 = hard 9
        vm.prank(player);
        tbl.double(gameId);
        assertTrue(gameState(gameId) == BlackjackTableV2.GameState.AWAITING_HIT_RANDOMNESS);
    }

    function test_softTotalCannotDouble() public {
        uint256 gameId = dealHand(10e18, ACE, 8, TEN); // A+9 = soft 20 (within 9-11? no — soft)
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV2.CannotDouble.selector, gameId));
        tbl.double(gameId);
    }

    function test_hardEightCannotDouble() public {
        uint256 gameId = dealHand(10e18, FIVE, 2, TEN); // 5+3 = hard 8
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV2.CannotDouble.selector, gameId));
        tbl.double(gameId);
    }
}

contract V2NoDoubleTest is V2TableTestBase {
    function _rules() internal pure override returns (BlackjackTableV2.Rules memory) {
        return BlackjackTableV2.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: BlackjackTableV2.DoubleRule.NO_DOUBLE,
            lateSurrender: false
        });
    }

    function test_neverDouble() public {
        uint256 gameId = dealHand(10e18, FIVE, FIVE, TEN); // hard 10
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV2.CannotDouble.selector, gameId));
        tbl.double(gameId);
    }
}

/// @notice Late surrender.
contract V2SurrenderTest is V2TableTestBase {
    function _rules() internal pure override returns (BlackjackTableV2.Rules memory) {
        return BlackjackTableV2.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: BlackjackTableV2.DoubleRule.ANY_TWO,
            lateSurrender: true
        });
    }

    function test_surrenderReturnsHalf() public {
        uint256 wager = 10e18;
        uint256 balBefore = chip.balanceOf(player);
        uint256 houseBefore = tbl.houseFunds();

        uint256 gameId = dealHand(wager, TEN, SIX, KING); // 16 vs 10 — the surrender hand
        vm.prank(player);
        tbl.surrender(gameId);

        BlackjackTableV2.Game memory g = tbl.getGame(gameId);
        assertTrue(g.state == BlackjackTableV2.GameState.SETTLED);
        assertTrue(g.outcome == BlackjackTableV2.Outcome.SURRENDERED);
        assertEq(g.payout, wager / 2);
        assertEq(chip.balanceOf(player), balBefore - wager + wager / 2);
        assertEq(tbl.houseFunds(), houseBefore + wager / 2);
        assertEq(tbl.totalPlayerEscrow(), 0);
        assertEq(tbl.totalReservedLiability(), 0);
        assertEq(tbl.activeGameCountOf(player), 0);
    }

    function test_cannotSurrenderAfterHit() public {
        uint256 gameId = dealHand(10e18, FIVE, 3, TEN); // 9
        vm.prank(player);
        tbl.hit(gameId);
        fulfill(gameId, findCardSeed(2, gameId)); // +3 = 12, back to PLAYER_TURN
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV2.CannotSurrender.selector, gameId));
        tbl.surrender(gameId);
    }

    function test_surrenderAllowedWhilePaused() public {
        uint256 gameId = dealHand(10e18, TEN, SIX, KING);
        vm.prank(admin);
        tbl.pause();
        vm.prank(player);
        tbl.surrender(gameId);
        assertTrue(tbl.getGame(gameId).outcome == BlackjackTableV2.Outcome.SURRENDERED);
    }
}

/// @notice Surrender must revert on tables that do not allow it.
contract V2NoSurrenderTest is V2TableTestBase {
    function test_surrenderDisabled() public {
        uint256 gameId = dealHand(10e18, TEN, SIX, KING);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTableV2.CannotSurrender.selector, gameId));
        tbl.surrender(gameId);
    }
}
