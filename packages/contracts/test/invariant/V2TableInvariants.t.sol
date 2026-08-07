// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TestChip} from "../../src/TestChip.sol";
import {BlackjackTableV2} from "../../src/BlackjackTableV2.sol";
import {TableFactory} from "../../src/TableFactory.sol";
import {MockRandomnessProvider} from "../../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V2Handler} from "./V2Handler.sol";

/// @notice v2 invariants under random multi-game interleavings:
///         solvency, reservation coverage, active-game enumeration consistency.
contract V2TableInvariantsTest is Test {
    TestChip internal chip;
    MockRandomnessProvider internal mock;
    TableFactory internal factory;
    BlackjackTableV2 internal tbl;
    V2Handler internal handler;

    address internal admin = makeAddr("admin");

    function setUp() public {
        chip = new TestChip(admin);
        mock = new MockRandomnessProvider();
        factory = new TableFactory(IERC20(address(chip)), IRandomnessProvider(address(mock)));
        tbl = BlackjackTableV2(
            factory.createTable(
                BlackjackTableV2.Rules({
                    dealerHitsSoft17: true, // exercise the H17 dealer path
                    blackjackNum: 3,
                    blackjackDen: 2,
                    doubleRule: BlackjackTableV2.DoubleRule.ANY_TWO,
                    lateSurrender: true // exercise the surrender path
                }),
                1e18,
                1_000e18,
                3,
                admin
            )
        );

        vm.startPrank(admin);
        chip.mint(admin, 1_000_000e18);
        chip.approve(address(tbl), type(uint256).max);
        tbl.fundHouse(1_000_000e18);
        vm.stopPrank();

        handler = new V2Handler(chip, mock, tbl, admin);
        for (uint256 i; i < 3; i++) {
            // Hoisted: an external call in the mint args would consume the prank.
            address actor = handler.actorAt(i);
            vm.prank(admin);
            chip.mint(actor, 100_000e18);
        }
        targetContract(address(handler));
    }

    /// @dev The table's chip balance always exactly backs house funds + escrow.
    function invariant_solvency() public view {
        assertEq(chip.balanceOf(address(tbl)), tbl.houseFunds() + tbl.totalPlayerEscrow());
    }

    /// @dev Reserved liabilities never exceed the bankroll backing them.
    function invariant_reservedCovered() public view {
        assertLe(tbl.totalReservedLiability(), tbl.houseFunds());
    }

    /// @dev Every enumerated active game belongs to its owner and is in a live state.
    function invariant_enumerationConsistent() public view {
        for (uint256 i; i < 3; i++) {
            address who = handler.actorAt(i);
            uint256[] memory list = tbl.activeGamesOf(who);
            assertEq(list.length, tbl.activeGameCountOf(who));
            for (uint256 j; j < list.length; j++) {
                BlackjackTableV2.Game memory g = tbl.getGame(list[j]);
                assertEq(g.player, who);
                assertTrue(
                    g.state == BlackjackTableV2.GameState.AWAITING_INITIAL_RANDOMNESS
                        || g.state == BlackjackTableV2.GameState.PLAYER_TURN
                        || g.state == BlackjackTableV2.GameState.AWAITING_HIT_RANDOMNESS
                        || g.state == BlackjackTableV2.GameState.AWAITING_DEALER_RANDOMNESS
                );
            }
        }
    }

    /// @dev Escrow equals the sum of live stakes; reservation equals 2x live wagers.
    function invariant_escrowMatchesLiveStakes() public view {
        uint256 escrow;
        uint256 reserved;
        for (uint256 i; i < 3; i++) {
            uint256[] memory list = tbl.activeGamesOf(handler.actorAt(i));
            for (uint256 j; j < list.length; j++) {
                BlackjackTableV2.Game memory g = tbl.getGame(list[j]);
                escrow += g.doubled ? uint256(g.wager) * 2 : g.wager;
                reserved += g.reservedLiability;
            }
        }
        assertEq(tbl.totalPlayerEscrow(), escrow);
        assertEq(tbl.totalReservedLiability(), reserved);
    }
}
