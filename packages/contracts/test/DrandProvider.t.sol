// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TestChip} from "../src/TestChip.sol";
import {BlackjackTable} from "../src/BlackjackTable.sol";
import {DrandRandomnessProvider} from "../src/rand/DrandRandomnessProvider.sol";
import {IDrandOracleQuicknet} from "../src/interfaces/IDrandOracleQuicknet.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IRandomnessConsumer} from "../src/interfaces/IRandomnessConsumer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockDrandVerifier} from "./utils/MockDrandVerifier.sol";

contract RecordingConsumer is IRandomnessConsumer {
    uint256 public lastRequestId;
    bytes32 public lastSeed;
    uint256 public calls;

    function fulfillRandomness(uint256 requestId, bytes32 seed) external {
        lastRequestId = requestId;
        lastSeed = seed;
        calls++;
    }
}

/// @notice Drand adapter tests over a mock verifier with real quicknet timing.
contract DrandProviderTest is Test {
    MockDrandVerifier verifier;
    DrandRandomnessProvider provider;
    RecordingConsumer consumer;

    function setUp() public {
        // Realistic clock: some time well after quicknet genesis.
        vm.warp(1692803367 + 1_000_000 * 3);
        verifier = new MockDrandVerifier();
        provider = new DrandRandomnessProvider(IDrandOracleQuicknet(address(verifier)), 2);
        consumer = new RecordingConsumer();
    }

    function requestAsConsumer() internal returns (uint256 requestId, uint64 round) {
        vm.prank(address(consumer));
        requestId = provider.requestRandomness(1);
        (, round,,) = provider.requests(requestId);
    }

    function test_constructor_rejectsUnsafeConfig() public {
        vm.expectRevert(DrandRandomnessProvider.InvalidMinFutureRounds.selector);
        new DrandRandomnessProvider(IDrandOracleQuicknet(address(verifier)), 1);
        vm.expectRevert(DrandRandomnessProvider.ZeroAddress.selector);
        new DrandRandomnessProvider(IDrandOracleQuicknet(address(0)), 2);
    }

    function test_request_pinsFutureUnsignedRound() public {
        uint64 current = provider.currentRound();
        (uint256 requestId, uint64 round) = requestAsConsumer();
        assertEq(round, current + 2);
        // The pinned round must not be producible yet.
        assertGt(provider.publishTime(round), block.timestamp);
        (address boundConsumer,, bool fulfilled, uint256 gameId) = provider.requests(requestId);
        assertEq(boundConsumer, address(consumer));
        assertEq(gameId, 1);
        assertFalse(fulfilled);
    }

    function test_fulfill_beforePublishTime_reverts() public {
        (uint256 requestId, uint64 round) = requestAsConsumer();
        uint256 pt = provider.publishTime(round);
        bytes memory sig = verifier.sigFor(round);
        vm.expectRevert(
            abi.encodeWithSelector(
                DrandRandomnessProvider.RoundNotYetPublished.selector, requestId, pt
            )
        );
        provider.fulfill(requestId, sig);
    }

    function test_fulfill_wrongSignature_reverts() public {
        (uint256 requestId, uint64 round) = requestAsConsumer();
        vm.warp(provider.publishTime(round));
        // A valid beacon for a DIFFERENT round must not be accepted (exact-round pin).
        bytes memory wrongSig = verifier.sigFor(round + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DrandRandomnessProvider.InvalidSignature.selector, requestId, round
            )
        );
        provider.fulfill(requestId, wrongSig);
    }

    function test_fulfill_validBeacon_deliversChainScopedSeedOnce() public {
        (uint256 requestId, uint64 round) = requestAsConsumer();
        vm.warp(provider.publishTime(round) + 1);

        provider.fulfill(requestId, verifier.sigFor(round));
        assertEq(consumer.calls(), 1);
        assertEq(consumer.lastRequestId(), requestId);
        (,, bytes32 expectedSeed) = verifier.verifyNormalized(round, verifier.sigFor(round));
        assertEq(consumer.lastSeed(), expectedSeed);

        // Duplicate fulfillment is rejected by the adapter itself.
        bytes memory sig = verifier.sigFor(round);
        vm.expectRevert(
            abi.encodeWithSelector(DrandRandomnessProvider.AlreadyFulfilled.selector, requestId)
        );
        provider.fulfill(requestId, sig);
        assertEq(consumer.calls(), 1);
    }

    function test_fulfill_unknownRequest_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(DrandRandomnessProvider.UnknownRequest.selector, 999)
        );
        provider.fulfill(999, hex"00");
    }

    function test_requestsFromStrangersCannotTouchOtherConsumers() public {
        (uint256 requestId, uint64 round) = requestAsConsumer();
        // A stranger creates their own request; fulfilling it calls back the STRANGER
        // (msg.sender binding), never our consumer.
        address stranger = makeAddr("stranger");
        RecordingConsumer strangerConsumer = new RecordingConsumer();
        vm.prank(address(strangerConsumer));
        uint256 strangerRequest = provider.requestRandomness(42);
        (, uint64 strangerRound,,) = provider.requests(strangerRequest);

        vm.warp(provider.publishTime(strangerRound) + 1);
        provider.fulfill(strangerRequest, verifier.sigFor(strangerRound));
        assertEq(strangerConsumer.calls(), 1);
        assertEq(consumer.calls(), 0);

        // Our original request is untouched and still fulfillable.
        provider.fulfill(requestId, verifier.sigFor(round));
        assertEq(consumer.calls(), 1);
    }
}

/// @notice End-to-end: BlackjackTable playing through the drand adapter (mock verifier,
///         real quicknet timing), including the timeout path.
contract DrandTableIntegrationTest is Test {
    TestChip chip;
    MockDrandVerifier verifier;
    DrandRandomnessProvider provider;
    BlackjackTable table;
    address admin = makeAddr("admin");
    address player = makeAddr("player");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1692803367 + 2_000_000 * 3);
        chip = new TestChip(admin);
        verifier = new MockDrandVerifier();
        provider = new DrandRandomnessProvider(IDrandOracleQuicknet(address(verifier)), 2);
        table = new BlackjackTable(
            IERC20(address(chip)), IRandomnessProvider(address(provider)), 1e18, 1_000e18, admin
        );
        vm.startPrank(admin);
        chip.mint(admin, 100_000e18);
        chip.approve(address(table), type(uint256).max);
        table.fundHouse(100_000e18);
        chip.mint(player, 10_000e18);
        vm.stopPrank();
        vm.prank(player);
        chip.approve(address(table), type(uint256).max);
    }

    /// Advance chain time past the pending round's publish time and submit the beacon.
    function keeperFulfills(uint256 gameId) internal {
        uint256 requestId = table.getGame(gameId).pendingRequestId;
        (, uint64 round,,) = provider.requests(requestId);
        uint256 pt = provider.publishTime(round);
        if (block.timestamp < pt) vm.warp(pt + 1);
        vm.prank(keeper);
        provider.fulfill(requestId, verifier.sigFor(round));
    }

    function test_fullGame_overDrandAdapter() public {
        vm.prank(player);
        uint256 gameId = table.placeBet(100e18);
        assertEq(
            uint8(table.getGame(gameId).state),
            uint8(BlackjackTable.GameState.AWAITING_INITIAL_RANDOMNESS)
        );

        keeperFulfills(gameId); // initial deal ~2 rounds later
        BlackjackTable.Game memory g = table.getGame(gameId);

        if (g.state == BlackjackTable.GameState.PLAYER_TURN) {
            vm.prank(player);
            table.stand();
            keeperFulfills(gameId); // dealer plays
        } else if (g.state == BlackjackTable.GameState.AWAITING_DEALER_RANDOMNESS) {
            keeperFulfills(gameId); // player natural: dealer check
        }

        g = table.getGame(gameId);
        assertEq(uint8(g.state), uint8(BlackjackTable.GameState.SETTLED));
        assertEq(table.totalPlayerEscrow(), 0);
        assertEq(table.totalReservedLiability(), 0);
        // Conservation.
        assertEq(chip.balanceOf(address(table)), table.houseFunds());
        assertEq(chip.balanceOf(player), 10_000e18 - 100e18 + g.payout);
    }

    function test_timeout_overDrandAdapter_refundsAndBlocksLateBeacon() public {
        vm.prank(player);
        uint256 gameId = table.placeBet(100e18);
        uint256 requestId = table.getGame(gameId).pendingRequestId;
        (, uint64 round,,) = provider.requests(requestId);

        // Nobody submits the beacon; the player cancels after the timeout.
        vm.warp(block.timestamp + table.randomnessTimeout());
        vm.prank(player);
        table.cancelTimedOutGame(gameId);
        assertEq(chip.balanceOf(player), 10_000e18);

        // The late beacon can no longer act: the table rejects its own callback, which
        // reverts the adapter's fulfill atomically.
        bytes memory sig = verifier.sigFor(round);
        vm.expectRevert(abi.encodeWithSelector(BlackjackTable.UnknownRequest.selector, requestId));
        vm.prank(keeper);
        provider.fulfill(requestId, sig);
    }
}
