// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title BlackjackLib
/// @notice Pure helpers for card derivation, packed hand storage and hand valuation.
/// @dev Cards are uint8 in [0,51]: rank = card % 13 (0 = Ace .. 12 = King), suit = card / 13.
///      A hand is packed into a single uint256, one byte per card (max 32 cards), plus a count.
///
///      Card sampling is WITH REPLACEMENT (an "infinite shoe"): each card is derived
///      independently from a committed seed, so card-removal effects of a real six-deck
///      shoe are not modeled. This is a documented MVP limitation (docs/KNOWN_LIMITATIONS.md);
///      a finite shoe can later replace `drawCard` without touching the state machine.
library BlackjackLib {
    uint8 internal constant MAX_CARDS = 32;
    uint8 internal constant BLACKJACK = 21;
    uint8 internal constant DEALER_STAND_MIN = 17;

    error HandFull();

    /// @notice Derive the `nonce`-th card of a phase from a committed 32-byte seed.
    /// @dev Modulo bias over 52 is < 2^-250 — cryptographically irrelevant, documented.
    function drawCard(bytes32 seed, uint256 nonce) internal pure returns (uint8) {
        return uint8(uint256(keccak256(abi.encodePacked(seed, nonce))) % 52);
    }

    /// @notice Rank of a card: 0 = Ace, 1 = Two, ..., 8 = Nine, 9 = Ten, 10 = Jack,
    ///         11 = Queen, 12 = King.
    function rank(uint8 card) internal pure returns (uint8) {
        return card % 13;
    }

    /// @notice Blackjack value of a single card, counting Ace as 1 (soft handling is
    ///         done at the hand level).
    function cardValue(uint8 card) internal pure returns (uint8) {
        uint8 r = rank(card);
        if (r == 0) return 1; // Ace
        if (r >= 9) return 10; // Ten, Jack, Queen, King
        return r + 1; // Two..Nine
    }

    /// @notice Append a card to a packed hand. Byte `i` of `packed` is card `i`.
    function pushCard(uint256 packed, uint8 count, uint8 card)
        internal
        pure
        returns (uint256 newPacked, uint8 newCount)
    {
        if (count >= MAX_CARDS) revert HandFull();
        newPacked = packed | (uint256(card) << (8 * count));
        newCount = count + 1;
    }

    /// @notice Read card `i` from a packed hand.
    function cardAt(uint256 packed, uint8 i) internal pure returns (uint8) {
        // Intentional truncation: extracts exactly the i-th byte.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(packed >> (8 * i));
    }

    /// @notice Best blackjack value of a hand and whether that value is soft
    ///         (i.e. an Ace is currently counted as 11).
    function handValue(uint256 packed, uint8 count)
        internal
        pure
        returns (uint8 total, bool isSoft)
    {
        uint256 sum;
        bool hasAce;
        for (uint8 i; i < count; ++i) {
            uint8 v = cardValue(cardAt(packed, i));
            if (v == 1) hasAce = true;
            sum += v;
        }
        if (hasAce && sum + 10 <= BLACKJACK) {
            // Safe: sum + 10 <= 21 here.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (uint8(sum + 10), true);
        }
        // A busted hand's sum can reach 32 * 10 = 320; cap for the cast (a total > 21
        // means bust regardless of magnitude, so clamping to 255 loses nothing).
        // forge-lint: disable-next-line(unsafe-typecast)
        return (sum > 255 ? 255 : uint8(sum), false);
    }

    /// @notice A natural blackjack: exactly two cards totalling 21.
    function isNatural(uint256 packed, uint8 count) internal pure returns (bool) {
        if (count != 2) return false;
        (uint8 total,) = handValue(packed, count);
        return total == BLACKJACK;
    }

    function isBust(uint256 packed, uint8 count) internal pure returns (bool) {
        (uint8 total,) = handValue(packed, count);
        return total > BLACKJACK;
    }

    /// @notice Dealer draw rule: hit strictly below 17; stand on ALL 17s (soft included).
    function dealerShouldDraw(uint256 packed, uint8 count) internal pure returns (bool) {
        (uint8 total,) = handValue(packed, count);
        return total < DEALER_STAND_MIN;
    }

    /// @notice Play out the dealer hand from a dedicated committed seed, drawing until
    ///         the dealer stands (>= 17) or busts. The dealer has no decisions, so a
    ///         single seed safely covers the whole sequence.
    function dealerPlay(uint256 packed, uint8 count, bytes32 seed)
        internal
        pure
        returns (uint256 newPacked, uint8 newCount)
    {
        newPacked = packed;
        newCount = count;
        uint256 nonce;
        while (dealerShouldDraw(newPacked, newCount)) {
            (newPacked, newCount) = pushCard(newPacked, newCount, drawCard(seed, nonce));
            unchecked {
                ++nonce;
            }
        }
    }
}
