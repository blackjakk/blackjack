// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BlackjackLib} from "../../src/lib/BlackjackLib.sol";

/// @notice Table-independent seed-search helpers: find mock seeds that force exact
///         hands through the real randomness path. Shared by v1 and v2 harnesses.
abstract contract SeedSearch is Test {
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

    /// @notice Rule-aware variant of findDealerSeed (S17/H17 playout).
    function findDealerSeedRule(uint8 upCardRank, uint8 wantTotal, bool hitsSoft17, uint256 salt)
        internal
        pure
        returns (bytes32)
    {
        (uint256 start, uint8 n) = BlackjackLib.pushCard(0, 0, upCardRank);
        for (uint256 i;; ++i) {
            bytes32 seed = keccak256(abi.encode("dealerrule", salt, i));
            (uint256 hand, uint8 count) = BlackjackLib.dealerPlayRule(start, n, seed, hitsSoft17);
            (uint8 total,) = BlackjackLib.handValue(hand, count);
            if (total == wantTotal) return seed;
        }
    }
}
