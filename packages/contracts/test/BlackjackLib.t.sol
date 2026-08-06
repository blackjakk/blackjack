// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BlackjackLib} from "../src/lib/BlackjackLib.sol";

contract BlackjackLibTest is Test {
    // Rank constants (suit 0): card % 13 → 0 = Ace ... 12 = King.
    uint8 constant ACE = 0;
    uint8 constant TWO = 1;
    uint8 constant SIX = 5;
    uint8 constant NINE = 8;
    uint8 constant TEN = 9;
    uint8 constant JACK = 10;
    uint8 constant QUEEN = 11;
    uint8 constant KING = 12;

    function hand(uint8[] memory cards) internal pure returns (uint256 packed, uint8 count) {
        for (uint256 i; i < cards.length; ++i) {
            (packed, count) = BlackjackLib.pushCard(packed, count, cards[i]);
        }
    }

    function h2(uint8 a, uint8 b) internal pure returns (uint256, uint8) {
        uint8[] memory c = new uint8[](2);
        c[0] = a;
        c[1] = b;
        return hand(c);
    }

    function h3(uint8 a, uint8 b, uint8 x) internal pure returns (uint256, uint8) {
        uint8[] memory c = new uint8[](3);
        c[0] = a;
        c[1] = b;
        c[2] = x;
        return hand(c);
    }

    // ---------------------------------------------------------- card values

    function test_cardValues_allRanks() public pure {
        assertEq(BlackjackLib.cardValue(ACE), 1);
        for (uint8 r = 1; r <= 8; ++r) {
            assertEq(BlackjackLib.cardValue(r), r + 1); // Two..Nine
        }
        assertEq(BlackjackLib.cardValue(TEN), 10);
        assertEq(BlackjackLib.cardValue(JACK), 10);
        assertEq(BlackjackLib.cardValue(QUEEN), 10);
        assertEq(BlackjackLib.cardValue(KING), 10);
    }

    function testFuzz_cardValue_suitIrrelevant(uint8 rank, uint8 suit) public pure {
        rank = rank % 13;
        suit = suit % 4;
        assertEq(BlackjackLib.cardValue(rank + 13 * suit), BlackjackLib.cardValue(rank));
    }

    function testFuzz_drawCard_inRange(bytes32 seed, uint256 nonce) public pure {
        assertLt(BlackjackLib.drawCard(seed, nonce), 52);
    }

    // ---------------------------------------------------------- packing

    function testFuzz_pushCard_roundtrip(uint8[] memory cards) public pure {
        vm.assume(cards.length <= 32);
        uint256 packed;
        uint8 count;
        for (uint256 i; i < cards.length; ++i) {
            cards[i] = cards[i] % 52;
            (packed, count) = BlackjackLib.pushCard(packed, count, cards[i]);
        }
        assertEq(count, cards.length);
        for (uint8 i; i < count; ++i) {
            assertEq(BlackjackLib.cardAt(packed, i), cards[i]);
        }
    }

    /// @dev External wrapper so vm.expectRevert can observe the internal library revert.
    function pushCardExternal(uint256 packed, uint8 count, uint8 card)
        external
        pure
        returns (uint256, uint8)
    {
        return BlackjackLib.pushCard(packed, count, card);
    }

    function test_pushCard_revertsWhenFull() public {
        uint256 packed;
        uint8 count;
        for (uint256 i; i < 32; ++i) {
            (packed, count) = BlackjackLib.pushCard(packed, count, ACE);
        }
        vm.expectRevert(BlackjackLib.HandFull.selector);
        this.pushCardExternal(packed, count, ACE);
    }

    // ---------------------------------------------------------- hand values / aces

    function test_handValue_hardHands() public pure {
        (uint256 p, uint8 n) = h2(TEN, SIX);
        (uint8 total, bool soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 16);
        assertFalse(soft);

        (p, n) = h3(TEN, SIX, KING);
        (total, soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 26); // bust
        assertFalse(soft);
    }

    function test_handValue_singleAceSoft() public pure {
        (uint256 p, uint8 n) = h2(ACE, SIX);
        (uint8 total, bool soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 17); // soft 17
        assertTrue(soft);
    }

    function test_handValue_aceRevertsToHard() public pure {
        (uint256 p, uint8 n) = h3(ACE, SIX, TEN);
        (uint8 total, bool soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 17); // 1 + 6 + 10, ace forced hard
        assertFalse(soft);
    }

    function test_handValue_twoAces() public pure {
        (uint256 p, uint8 n) = h2(ACE, ACE);
        (uint8 total, bool soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 12); // one ace as 11, one as 1
        assertTrue(soft);
    }

    function test_handValue_manyAces() public pure {
        // 11 aces: sum = 11, +10 = 21 → soft 21.
        uint8[] memory eleven = new uint8[](11);
        (uint256 p, uint8 n) = hand(eleven); // all zeros = aces
        (uint8 total, bool soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 21);
        assertTrue(soft);

        // 12 aces: 12 + 10 = 22 > 21 → hard 12.
        uint8[] memory twelve = new uint8[](12);
        (p, n) = hand(twelve);
        (total, soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 12);
        assertFalse(soft);
    }

    function test_handValue_acesWithTens() public pure {
        (uint256 p, uint8 n) = h3(ACE, ACE, NINE);
        (uint8 total, bool soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 21); // 1 + 1 + 9 + 10 soft
        assertTrue(soft);

        (p, n) = h3(ACE, TEN, TEN);
        (total, soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 21); // 1 + 10 + 10 hard
        assertFalse(soft);
    }

    /// Exhaustive cross-check of two-card hands against a reference computation.
    function test_handValue_allTwoCardHands() public pure {
        for (uint8 a; a < 52; ++a) {
            for (uint8 b; b < 52; ++b) {
                (uint256 p, uint8 n) = h2(a, b);
                (uint8 total, bool soft) = BlackjackLib.handValue(p, n);
                uint8 va = BlackjackLib.cardValue(a);
                uint8 vb = BlackjackLib.cardValue(b);
                uint8 hard = va + vb;
                bool hasAce = va == 1 || vb == 1;
                if (hasAce && hard + 10 <= 21) {
                    assertEq(total, hard + 10);
                    assertTrue(soft);
                } else {
                    assertEq(total, hard);
                    assertFalse(soft);
                }
            }
        }
    }

    // ---------------------------------------------------------- naturals

    function test_isNatural() public pure {
        (uint256 p, uint8 n) = h2(ACE, KING);
        assertTrue(BlackjackLib.isNatural(p, n));
        (p, n) = h2(TEN, ACE);
        assertTrue(BlackjackLib.isNatural(p, n));
        (p, n) = h2(TEN, TEN);
        assertFalse(BlackjackLib.isNatural(p, n));
        // 21 in three cards is NOT a natural.
        (p, n) = h3(ACE, ACE, NINE);
        assertFalse(BlackjackLib.isNatural(p, n));
        (p, n) = h3(TEN, NINE, TWO);
        assertFalse(BlackjackLib.isNatural(p, n));
    }

    // ---------------------------------------------------------- dealer rule

    function test_dealer_hitsBelow17_standsOn17Plus() public pure {
        (uint256 p, uint8 n) = h2(TEN, SIX); // 16
        assertTrue(BlackjackLib.dealerShouldDraw(p, n));
        (p, n) = h2(TEN, KING); // 20
        assertFalse(BlackjackLib.dealerShouldDraw(p, n));
        (p, n) = h3(TEN, SIX, ACE); // hard 17
        assertFalse(BlackjackLib.dealerShouldDraw(p, n));
    }

    function test_dealer_standsOnSoft17() public pure {
        (uint256 p, uint8 n) = h2(ACE, SIX); // soft 17
        (uint8 total, bool soft) = BlackjackLib.handValue(p, n);
        assertEq(total, 17);
        assertTrue(soft);
        assertFalse(BlackjackLib.dealerShouldDraw(p, n)); // stands on ALL 17s
    }

    function testFuzz_dealerPlay_postconditions(bytes32 seed, uint8 upCard) public pure {
        upCard = upCard % 52;
        (uint256 start, uint8 n) = BlackjackLib.pushCard(0, 0, upCard);
        (uint256 hand_, uint8 count) = BlackjackLib.dealerPlay(start, n, seed);
        (uint8 total,) = BlackjackLib.handValue(hand_, count);

        // Dealer always ends at 17+ (busts are > 21 > 17).
        assertGe(total, 17);
        // Dealer never draws past reaching 17: hand minus last card was < 17
        // (unless the up-card alone already stands).
        if (count > n) {
            uint256 before = hand_ & ~(uint256(0xff) << (8 * (count - 1)));
            (uint8 beforeTotal,) = BlackjackLib.handValue(before, count - 1);
            assertLt(beforeTotal, 17);
        }
        // Determinism.
        (uint256 hand2, uint8 count2) = BlackjackLib.dealerPlay(start, n, seed);
        assertEq(hand_, hand2);
        assertEq(count, count2);
    }
}
