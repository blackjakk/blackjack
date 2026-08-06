// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TableTestBase} from "./utils/TableTestBase.sol";
import {BlackjackTable} from "../src/BlackjackTable.sol";
import {TestChip} from "../src/TestChip.sol";
import {MockRandomnessProvider} from "../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReentrantProvider, PreFulfillProvider, BlockableToken} from "./utils/Attackers.sol";

/// @notice Adversarial tests: reentrancy, malicious providers, token failures (Phase 3).
contract AdversarialTest is TableTestBase {
    uint256 constant W = 100e18;

    // ---------------------------------------------------------- reentrancy

    function test_reentrantProvider_cannotReenterPlaceBet() public {
        ReentrantProvider evil = new ReentrantProvider();
        evil.setTable(table);
        vm.prank(admin);
        table.setRandomnessProvider(IRandomnessProvider(address(evil)));

        evil.setAttack(ReentrantProvider.Attack.PLACE_BET);
        vm.prank(player);
        // The provider's reentrant placeBet hits the guard; the revert bubbles up
        // through requestRandomness and the whole bet reverts — no partial state.
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        table.placeBet(W);

        assertEq(table.activeGameOf(player), 0);
        assertEq(table.totalPlayerEscrow(), 0);
        assertEq(table.totalReservedLiability(), 0);
    }

    function test_reentrantProvider_cannotReenterHit() public {
        // Start a clean game via the honest mock, then swap in the evil provider.
        uint256 gameId = dealHand(W, TEN, FIVE, SIX);
        ReentrantProvider evil = new ReentrantProvider();
        evil.setTable(table);
        evil.setAttack(ReentrantProvider.Attack.HIT);
        vm.prank(admin);
        table.setRandomnessProvider(IRandomnessProvider(address(evil)));

        vm.prank(player);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        table.hit();
        // Hit rolled back entirely; the game is still the player's turn.
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.PLAYER_TURN));
    }

    function test_reentrantProvider_cannotReenterFulfill() public {
        ReentrantProvider evil = new ReentrantProvider();
        evil.setTable(table);
        evil.setAttack(ReentrantProvider.Attack.FULFILL);
        vm.prank(admin);
        table.setRandomnessProvider(IRandomnessProvider(address(evil)));

        vm.prank(player);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        table.placeBet(W);
    }

    function test_preFulfillProvider_cannotFrontRunItsOwnBinding() public {
        PreFulfillProvider sneaky = new PreFulfillProvider();
        sneaky.setTable(table);
        vm.prank(admin);
        table.setRandomnessProvider(IRandomnessProvider(address(sneaky)));

        vm.prank(player);
        uint256 gameId = table.placeBet(W);

        // The provider tried to fulfill before returning the requestId and was
        // rejected (the table had not bound the request yet).
        assertTrue(sneaky.innerCallReverted());
        assertEq(
            uint8(gameState(gameId)), uint8(BlackjackTable.GameState.AWAITING_INITIAL_RANDOMNESS)
        );

        // The legitimate, later fulfillment still works exactly once.
        sneaky.fulfill(table.getGame(gameId).pendingRequestId, keccak256("later"));
        BlackjackTable.Game memory g = table.getGame(gameId);
        assertTrue(
            g.state == BlackjackTable.GameState.PLAYER_TURN
                || g.state == BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS
        );
    }

    // ---------------------------------------------------------- provider swap safety

    function test_providerSwap_inFlightGameStillFulfillsThroughOldProvider() public {
        uint256 gameId = bet(W);
        uint256 requestId = table.getGame(gameId).pendingRequestId;

        MockRandomnessProvider newMock = new MockRandomnessProvider();
        vm.prank(admin);
        table.setRandomnessProvider(IRandomnessProvider(address(newMock)));

        // Old provider still resolves its own in-flight request...
        mock.fulfill(requestId, findInitialSeed(TEN, FIVE, SIX, gameId));
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.PLAYER_TURN));

        // ...and the game's NEXT request goes to the new provider.
        vm.prank(player);
        table.hit();
        assertEq(table.getGame(gameId).pendingProvider, address(newMock));
    }

    function test_oldProvider_cannotFulfillNewProvidersRequest() public {
        uint256 gameId = bet(W);
        uint256 requestId = table.getGame(gameId).pendingRequestId;
        mock.fulfill(requestId, findInitialSeed(TEN, FIVE, SIX, gameId));

        MockRandomnessProvider newMock = new MockRandomnessProvider();
        vm.prank(admin);
        table.setRandomnessProvider(IRandomnessProvider(address(newMock)));
        vm.prank(player);
        table.hit(); // bound to newMock, requestId 1 on newMock

        uint256 newRequestId = table.getGame(gameId).pendingRequestId;
        // The OLD provider calling with the same numeric id must be rejected: bindings
        // are keyed by (provider, requestId), not by id alone.
        vm.prank(address(mock));
        vm.expectRevert(
            abi.encodeWithSelector(BlackjackTable.UnknownRequest.selector, newRequestId)
        );
        table.fulfillRandomness(newRequestId, keccak256("stolen"));
    }

    // ---------------------------------------------------------- token failures

    function _tableWithBlockableToken()
        internal
        returns (BlockableToken token, BlackjackTable t, MockRandomnessProvider m)
    {
        token = new BlockableToken();
        m = new MockRandomnessProvider();
        t = new BlackjackTable(
            IERC20(address(token)), IRandomnessProvider(address(m)), MIN_WAGER, MAX_WAGER, admin
        );
        token.mint(admin, HOUSE_BANKROLL);
        vm.startPrank(admin);
        token.approve(address(t), type(uint256).max);
        t.fundHouse(HOUSE_BANKROLL);
        vm.stopPrank();
        token.mint(player, PLAYER_STACK);
        vm.prank(player);
        token.approve(address(t), type(uint256).max);
    }

    function test_failedEscrowTransfer_revertsBetCleanly() public {
        (BlockableToken token, BlackjackTable t,) = _tableWithBlockableToken();
        token.setBlocked(address(t), true); // deposits to the table now fail

        vm.prank(player);
        vm.expectRevert(bytes("BLK: transfer blocked"));
        t.placeBet(W);

        assertEq(t.activeGameOf(player), 0);
        assertEq(t.totalPlayerEscrow(), 0);
        assertEq(t.totalReservedLiability(), 0);
    }

    function test_failedPayoutTransfer_revertsAtomically_andIsRetryable() public {
        (BlockableToken token, BlackjackTable t, MockRandomnessProvider m) =
            _tableWithBlockableToken();

        vm.prank(player);
        uint256 gameId = t.placeBet(W);
        m.fulfill(t.getGame(gameId).pendingRequestId, findInitialSeed(TEN, TEN, SIX, gameId));
        vm.prank(player);
        t.stand();
        uint256 requestId = t.getGame(gameId).pendingRequestId;

        // Payouts to the player now fail: settlement must revert as a whole...
        token.setBlocked(player, true);
        bytes32 dealerSeed = findDealerSeed(SIX, 18, gameId); // player 20 wins
        vm.expectRevert(bytes("BLK: transfer blocked"));
        m.fulfill(requestId, dealerSeed);

        // ...leaving the game live and the request binding intact (atomic rollback).
        BlackjackTable.Game memory g = t.getGame(gameId);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS));
        assertEq(g.pendingRequestId, requestId);

        // Once the token unblocks, the same fulfillment succeeds exactly once.
        token.setBlocked(player, false);
        m.fulfill(requestId, dealerSeed);
        assertEq(uint8(t.getGame(gameId).state), uint8(BlackjackTable.GameState.SETTLED));
        assertEq(token.balanceOf(player), PLAYER_STACK + W);
    }

    // ---------------------------------------------------------- multi-player isolation

    function test_twoPlayers_independentGames() public {
        address player2 = makeAddr("player2");
        vm.prank(admin);
        chip.mint(player2, PLAYER_STACK);
        vm.prank(player2);
        chip.approve(address(table), type(uint256).max);

        uint256 g1 = dealHand(W, TEN, TEN, SIX); // player1: 20
        vm.prank(player2);
        uint256 g2 = table.placeBet(W);
        fulfill(g2, findInitialSeed(TEN, SIX, FIVE, g2)); // player2: 16

        // Player2 cannot act on player1's game (their own state gates them), and
        // settling one game leaves the other untouched.
        vm.prank(player);
        table.stand();
        fulfill(g1, findDealerSeed(SIX, 19, g1));
        assertEq(uint8(gameState(g1)), uint8(BlackjackTable.GameState.SETTLED));
        assertEq(uint8(gameState(g2)), uint8(BlackjackTable.GameState.PLAYER_TURN));
        assertEq(table.totalPlayerEscrow(), W); // only player2's escrow remains
        assertEq(table.totalReservedLiability(), 2 * W);
    }
}
