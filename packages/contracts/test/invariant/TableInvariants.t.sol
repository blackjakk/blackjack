// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TestChip} from "../../src/TestChip.sol";
import {BlackjackTable} from "../../src/BlackjackTable.sol";
import {MockRandomnessProvider} from "../../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.sol";

/// @notice System invariants driven by the randomized Handler.
contract TableInvariants is Test {
    TestChip chip;
    MockRandomnessProvider mock;
    BlackjackTable table;
    Handler handler;
    address admin = makeAddr("admin");

    // Ghost: first-observed terminal data per game, to prove terminal immutability
    // (a game can settle or cancel at most once, and never change afterwards).
    mapping(uint256 => bool) seenTerminal;
    mapping(uint256 => BlackjackTable.GameState) terminalState;
    mapping(uint256 => uint256) terminalPayout;
    mapping(uint256 => BlackjackTable.Outcome) terminalOutcome;

    function setUp() public {
        chip = new TestChip(admin);
        mock = new MockRandomnessProvider();
        table = new BlackjackTable(
            IERC20(address(chip)), IRandomnessProvider(address(mock)), 1e18, 1_000e18, admin
        );
        vm.startPrank(admin);
        chip.mint(admin, 1_000_000e18);
        chip.approve(address(table), type(uint256).max);
        table.fundHouse(1_000_000e18);
        vm.stopPrank();

        handler = new Handler(chip, table, mock, admin);
        targetContract(address(handler));
    }

    /// Invariant: the contract's token balance always covers player escrow + house funds.
    function invariant_solvency() public view {
        assertGe(
            chip.balanceOf(address(table)),
            table.totalPlayerEscrow() + table.houseFunds(),
            "balance < escrow + houseFunds"
        );
        // With donations tracked, the relation is exact.
        assertEq(
            chip.balanceOf(address(table)),
            table.totalPlayerEscrow() + table.houseFunds() + handler.ghostTotalDonated(),
            "balance != escrow + houseFunds + donations"
        );
    }

    /// Invariant: reserved liabilities never exceed the house bankroll, so every live
    /// game's worst-case payout is always covered (and withdrawals can't touch it).
    function invariant_reservedNeverExceedsHouseFunds() public view {
        assertLe(table.totalReservedLiability(), table.houseFunds());
        assertEq(table.availableLiquidity(), table.houseFunds() - table.totalReservedLiability());
    }

    /// Invariant: terminal games (settled or cancelled) are immutable — a game settles
    /// at most once — and each payout is bounded by the player's own stake plus the
    /// reservation made for that game.
    function invariant_settleOnceAndPayoutBounded() public {
        uint256 next = table.nextGameId();
        for (uint256 id = 1; id < next; ++id) {
            BlackjackTable.Game memory g = table.getGame(id);
            bool terminal = g.state == BlackjackTable.GameState.SETTLED
                || g.state == BlackjackTable.GameState.CANCELLED;
            if (terminal) {
                uint256 stake = g.doubled ? uint256(g.wager) * 2 : g.wager;
                assertLe(g.payout, stake + g.reservedLiability, "payout exceeds max reserved");
                if (g.state == BlackjackTable.GameState.CANCELLED) {
                    assertEq(g.payout, stake, "cancel must refund exactly the stake");
                }
                if (!seenTerminal[id]) {
                    seenTerminal[id] = true;
                    terminalState[id] = g.state;
                    terminalPayout[id] = g.payout;
                    terminalOutcome[id] = g.outcome;
                } else {
                    assertEq(uint8(terminalState[id]), uint8(g.state), "terminal state changed");
                    assertEq(terminalPayout[id], g.payout, "terminal payout changed");
                    assertEq(uint8(terminalOutcome[id]), uint8(g.outcome), "outcome changed");
                }
            } else {
                assertFalse(seenTerminal[id], "game left terminal state");
            }
        }
    }

    /// Invariant: per-actor active-game bookkeeping is consistent, and every pending
    /// randomness request belongs to a live awaiting game.
    function invariant_activeGameConsistency() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            uint256 id = table.activeGameOf(actor);
            if (id == 0) continue;
            BlackjackTable.Game memory g = table.getGame(id);
            assertEq(g.player, actor, "active game owned by someone else");
            assertTrue(
                g.state == BlackjackTable.GameState.AWAITING_INITIAL_RANDOMNESS
                    || g.state == BlackjackTable.GameState.PLAYER_TURN
                    || g.state == BlackjackTable.GameState.AWAITING_HIT_RANDOMNESS
                    || g.state == BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS,
                "active game in terminal state"
            );
            if (
                g.state == BlackjackTable.GameState.AWAITING_INITIAL_RANDOMNESS
                    || g.state == BlackjackTable.GameState.AWAITING_HIT_RANDOMNESS
                    || g.state == BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS
            ) {
                assertGt(g.pendingRequestId, 0, "awaiting state without pending request");
                assertEq(g.pendingProvider, address(mock));
            } else {
                assertEq(g.pendingRequestId, 0, "player turn with pending request");
            }
        }
    }

    /// Invariant: total reserved equals the sum of reservations of live games.
    function invariant_reservedMatchesLiveGames() public view {
        uint256 next = table.nextGameId();
        uint256 sumReserved;
        uint256 sumEscrow;
        for (uint256 id = 1; id < next; ++id) {
            BlackjackTable.Game memory g = table.getGame(id);
            if (
                g.state != BlackjackTable.GameState.SETTLED
                    && g.state != BlackjackTable.GameState.CANCELLED
            ) {
                sumReserved += g.reservedLiability;
                sumEscrow += g.doubled ? uint256(g.wager) * 2 : g.wager;
            }
        }
        assertEq(table.totalReservedLiability(), sumReserved, "reserved sum mismatch");
        assertEq(table.totalPlayerEscrow(), sumEscrow, "escrow sum mismatch");
    }
}
