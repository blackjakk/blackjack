// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestChip} from "../../src/TestChip.sol";
import {InfiniteBlackjack} from "../../src/InfiniteBlackjack.sol";
import {MockRandomnessProvider} from "../../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlackjackLib} from "../../src/lib/BlackjackLib.sol";
import {SeedSearch} from "./SeedSearch.sol";

/// @notice Infinite-table harness: chip + mock provider + one shared table with
///         S17/3:2/double-any-two/surrender rules, three funded players. Variable
///         named `tbl` — forge treats a public `table()` getter as a table test.
abstract contract InfiniteTestBase is SeedSearch {
    TestChip internal chip;
    MockRandomnessProvider internal mock;
    InfiniteBlackjack internal tbl;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant MIN_WAGER = 1e18;
    uint256 internal constant MAX_WAGER = 1_000e18;
    uint256 internal constant HOUSE_BANKROLL = 100_000e18;
    uint256 internal constant PLAYER_STACK = 10_000e18;
    uint64 internal constant BET_WINDOW = 60;
    uint64 internal constant ACT_WINDOW = 60;
    uint256 internal constant W = 10e18;

    function _rules() internal pure virtual returns (InfiniteBlackjack.Rules memory) {
        return InfiniteBlackjack.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: InfiniteBlackjack.DoubleRule.ANY_TWO,
            lateSurrender: true
        });
    }

    function setUp() public virtual {
        chip = new TestChip(admin);
        mock = new MockRandomnessProvider();
        tbl = new InfiniteBlackjack(
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
        chip.mint(admin, HOUSE_BANKROLL);
        chip.approve(address(tbl), type(uint256).max);
        tbl.fundHouse(HOUSE_BANKROLL);
        vm.stopPrank();

        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < players.length; ++i) {
            vm.prank(admin);
            chip.mint(players[i], PLAYER_STACK);
            vm.prank(players[i]);
            chip.approve(address(tbl), type(uint256).max);
        }
    }

    // ------------------------------------------------------------ flow helpers

    function betAs(address player, uint256 wager) internal returns (uint256 roundId) {
        vm.prank(player);
        roundId = tbl.placeBet(wager);
    }

    function round() internal view returns (InfiniteBlackjack.Round memory) {
        return tbl.getRound(tbl.currentRoundId());
    }

    function fulfillPending(bytes32 seed) internal {
        mock.fulfill(round().pendingRequestId, seed);
    }

    /// @notice Close betting (warping past the window) and deal the given shared hand.
    function lockAndDeal(uint8 p1Rank, uint8 p2Rank, uint8 d1Rank) internal {
        vm.warp(round().betDeadline);
        tbl.lockDeal();
        fulfillPending(findInitialSeed(p1Rank, p2Rank, d1Rank, tbl.currentRoundId()));
    }

    function actAs(address player, InfiniteBlackjack.Action action, uint8 target) internal {
        vm.prank(player);
        tbl.act(action, target);
    }

    /// @notice Lock actions (warping past the window if needed) and fulfill beacon #2.
    function lockAndDraw(bytes32 drawSeed) internal {
        InfiniteBlackjack.Round memory r = round();
        if (r.actedCount < r.playerCount && block.timestamp < r.actDeadline) {
            vm.warp(r.actDeadline);
        }
        tbl.lockActions();
        fulfillPending(drawSeed);
    }

    function betOf(address player) internal view returns (InfiniteBlackjack.Bet memory) {
        return tbl.betOf(tbl.currentRoundId(), player);
    }

    // ------------------------------------------------------------ draw-seed search

    /// @dev Dealer hand a given beacon-#2 seed produces from `upRank`.
    function dealerFromDraw(bytes32 drawSeed, uint8 upRank)
        internal
        pure
        returns (uint256 hand, uint8 count, uint8 total)
    {
        (uint256 start, uint8 n) = BlackjackLib.pushCard(0, 0, upRank);
        bytes32 dealerSeed = keccak256(abi.encodePacked(drawSeed));
        (hand, count) = BlackjackLib.dealerPlayRule(start, n, dealerSeed, false);
        (total,) = BlackjackLib.handValue(hand, count);
    }

    /// @notice Find a beacon-#2 seed giving the dealer exactly `wantTotal` (S17).
    function findDrawSeedDealer(uint8 upRank, uint8 wantTotal, uint256 salt)
        internal
        pure
        returns (bytes32)
    {
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("draw", salt, i));
            (,, uint8 total) = dealerFromDraw(seed, upRank);
            if (total == wantTotal) return seed;
        }
    }

    /// @notice Find a beacon-#2 seed where the dealer makes a 2-card natural from an
    ///         ace/ten up-card.
    function findDrawSeedDealerNatural(uint8 upRank, uint256 salt) internal pure returns (bytes32) {
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("drawnat", salt, i));
            (uint256 hand, uint8 count,) = dealerFromDraw(seed, upRank);
            if (BlackjackLib.isNatural(hand, count)) return seed;
        }
    }

    /// @notice Find a beacon-#2 seed where the dealer makes a natural AND `player`'s
    ///         first draw card keeps a hand of `handTotal` at or under 21.
    function findDrawSeedDealerNaturalNoBust(
        uint8 upRank,
        address player,
        uint8 handTotal,
        uint256 salt
    ) internal pure returns (bytes32) {
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("drawnatnb", salt, i));
            (uint256 hand, uint8 count,) = dealerFromDraw(seed, upRank);
            if (!BlackjackLib.isNatural(hand, count)) continue;
            bytes32 pSeed = keccak256(abi.encodePacked(seed, player));
            if (handTotal + BlackjackLib.cardValue(BlackjackLib.drawCard(pSeed, 0)) <= 21) {
                return seed;
            }
        }
    }

    /// @notice Find a beacon-#2 seed with a given dealer total AND a given rank for
    ///         `player`'s first draw card.
    function findDrawSeedDealerAndCard(
        uint8 upRank,
        uint8 wantTotal,
        address player,
        uint8 cardRank,
        uint256 salt
    ) internal pure returns (bytes32) {
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("drawcard", salt, i));
            (,, uint8 total) = dealerFromDraw(seed, upRank);
            if (total != wantTotal) continue;
            bytes32 pSeed = keccak256(abi.encodePacked(seed, player));
            if (rankOf(BlackjackLib.drawCard(pSeed, 0)) == cardRank) return seed;
        }
    }

    /// @notice Recompute the hand a HIT-to-target player should end with.
    function expectedHitHand(bytes32 drawSeed, address player, uint256 sharedCards, uint8 target)
        internal
        pure
        returns (uint256 cards, uint8 count, uint8 total)
    {
        cards = sharedCards;
        count = 2;
        bytes32 pSeed = keccak256(abi.encodePacked(drawSeed, player));
        (total,) = BlackjackLib.handValue(cards, count);
        uint256 nonce;
        while (total <= 21 && total < target) {
            (cards, count) = BlackjackLib.pushCard(cards, count, BlackjackLib.drawCard(pSeed, nonce));
            (total,) = BlackjackLib.handValue(cards, count);
            ++nonce;
        }
    }

    // ------------------------------------------------------------ invariant checks

    /// @notice Solvency: the table's token balance always covers house funds, player
    ///         escrow and deferred payouts; reserves never exceed the bankroll.
    function assertSolvent() internal view {
        assertGe(
            chip.balanceOf(address(tbl)),
            tbl.houseFunds() + tbl.totalPlayerEscrow() + tbl.totalDeferredPayouts(),
            "insolvent"
        );
        assertLe(tbl.totalReservedLiability(), tbl.houseFunds(), "over-reserved");
    }
}
