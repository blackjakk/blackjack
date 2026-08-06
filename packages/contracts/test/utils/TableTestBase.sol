// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TestChip} from "../../src/TestChip.sol";
import {BlackjackTable} from "../../src/BlackjackTable.sol";
import {MockRandomnessProvider} from "../../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlackjackLib} from "../../src/lib/BlackjackLib.sol";

/// @notice Shared harness: deploys chip + mock provider + table, funds the house and a
///         player, and provides seed-search helpers so tests can force exact hands
///         through the real randomness path.
abstract contract TableTestBase is Test {
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

    // ------------------------------------------------------------ seed search

    /// @dev Rank constants (suit 0). card % 13: 0 = Ace ... 12 = King.
    uint8 internal constant ACE = 0;
    uint8 internal constant FIVE = 4;
    uint8 internal constant SIX = 5;
    uint8 internal constant TEN = 9;
    uint8 internal constant KING = 12;

    function rankOf(uint8 card) internal pure returns (uint8) {
        return card % 13;
    }

    /// @notice Find a seed whose first three derived cards have the given ranks
    ///         (player card 1, player card 2, dealer up-card).
    function findInitialSeed(uint8 p1Rank, uint8 p2Rank, uint8 d1Rank, uint256 salt)
        internal
        pure
        returns (bytes32)
    {
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("initial", salt, i));
            if (
                rankOf(BlackjackLib.drawCard(seed, 0)) == p1Rank
                    && rankOf(BlackjackLib.drawCard(seed, 1)) == p2Rank
                    && rankOf(BlackjackLib.drawCard(seed, 2)) == d1Rank
            ) return seed;
        }
    }

    /// @notice Find a seed whose first derived card has the given rank (hit/double card).
    function findCardSeed(uint8 cardRank, uint256 salt) internal pure returns (bytes32) {
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("card", salt, i));
            if (rankOf(BlackjackLib.drawCard(seed, 0)) == cardRank) return seed;
        }
    }

    /// @notice Find a dealer seed such that playing out from `upCardRank` yields the
    ///         requested final total (17..255; totals > 21 mean bust).
    function findDealerSeed(uint8 upCardRank, uint8 wantTotal, uint256 salt)
        internal
        pure
        returns (bytes32)
    {
        (uint256 start, uint8 n) = BlackjackLib.pushCard(0, 0, upCardRank);
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("dealer", salt, i));
            (uint256 hand, uint8 count) = BlackjackLib.dealerPlay(start, n, seed);
            (uint8 total,) = BlackjackLib.handValue(hand, count);
            if (total == wantTotal) return seed;
        }
    }

    /// @notice Find a dealer seed that busts the dealer starting from `upCardRank`.
    function findDealerBustSeed(uint8 upCardRank, uint256 salt) internal pure returns (bytes32) {
        (uint256 start, uint8 n) = BlackjackLib.pushCard(0, 0, upCardRank);
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("dealerbust", salt, i));
            (uint256 hand, uint8 count) = BlackjackLib.dealerPlay(start, n, seed);
            (uint8 total,) = BlackjackLib.handValue(hand, count);
            if (total > 21) return seed;
        }
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
