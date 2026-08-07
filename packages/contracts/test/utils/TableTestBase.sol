// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TestChip} from "../../src/TestChip.sol";
import {BlackjackTable} from "../../src/BlackjackTable.sol";
import {MockRandomnessProvider} from "../../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlackjackLib} from "../../src/lib/BlackjackLib.sol";
import {SeedSearch} from "./SeedSearch.sol";

/// @notice Shared harness: deploys chip + mock provider + table, funds the house and a
///         player, and provides seed-search helpers so tests can force exact hands
///         through the real randomness path.
abstract contract TableTestBase is SeedSearch {
    TestChip internal chip;
    MockRandomnessProvider internal mock;
    BlackjackTable internal table;

    address internal admin = makeAddr("admin");
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant MIN_WAGER = 1e18;
    uint256 internal constant MAX_WAGER = 1_000e18;
    uint256 internal constant HOUSE_BANKROLL = 100_000e18;
    uint256 internal constant PLAYER_STACK = 10_000e18;

    function setUp() public virtual {
        chip = new TestChip(admin);
        mock = new MockRandomnessProvider();
        table = new BlackjackTable(
            IERC20(address(chip)), IRandomnessProvider(address(mock)), MIN_WAGER, MAX_WAGER, admin
        );

        vm.startPrank(admin);
        chip.mint(admin, HOUSE_BANKROLL);
        chip.approve(address(table), type(uint256).max);
        table.fundHouse(HOUSE_BANKROLL);
        chip.mint(player, PLAYER_STACK);
        vm.stopPrank();

        vm.prank(player);
        chip.approve(address(table), type(uint256).max);
    }

    // ------------------------------------------------------------ flow helpers

    /// @notice Place a bet as `player` and return the gameId (game awaits initial seed).
    function bet(uint256 wager) internal returns (uint256 gameId) {
        vm.prank(player);
        gameId = table.placeBet(wager);
    }

    /// @notice Fulfill the game's pending request through the mock (as `keeper`).
    function fulfill(uint256 gameId, bytes32 seed) internal {
        BlackjackTable.Game memory g = table.getGame(gameId);
        vm.prank(keeper);
        mock.fulfill(g.pendingRequestId, seed);
    }

    /// @notice Bet and deal an initial hand with exact ranks.
    function dealHand(uint256 wager, uint8 p1Rank, uint8 p2Rank, uint8 d1Rank)
        internal
        returns (uint256 gameId)
    {
        gameId = bet(wager);
        fulfill(gameId, findInitialSeed(p1Rank, p2Rank, d1Rank, gameId));
    }

    function gameState(uint256 gameId) internal view returns (BlackjackTable.GameState) {
        return table.getGame(gameId).state;
    }
}
