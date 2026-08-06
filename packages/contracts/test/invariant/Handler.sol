// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {TestChip} from "../../src/TestChip.sol";
import {BlackjackTable} from "../../src/BlackjackTable.sol";
import {MockRandomnessProvider} from "../../src/rand/MockRandomnessProvider.sol";

/// @notice Invariant-test handler: drives the table through random but well-formed
///         action sequences from multiple actors, including treasury ops and donations.
contract Handler is CommonBase, StdCheats, StdUtils {
    TestChip public immutable chip;
    BlackjackTable public immutable table;
    MockRandomnessProvider public immutable mock;
    address public immutable admin;

    address[] public actors;
    uint256 public seedCounter;

    // Ghost bookkeeping for cross-checks in the invariant contract.
    uint256 public ghostTotalDonated;

    constructor(
        TestChip chip_,
        BlackjackTable table_,
        MockRandomnessProvider mock_,
        address admin_
    ) {
        chip = chip_;
        table = table_;
        mock = mock_;
        admin = admin_;
        for (uint256 i; i < 4; ++i) {
            address a = vm.addr(0xACC0 + i);
            actors.push(a);
            vm.prank(a);
            chip.approve(address(table), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 idx) internal view returns (address) {
        return actors[idx % actors.length];
    }

    function _nextSeed() internal returns (bytes32) {
        return keccak256(abi.encode("handler-seed", seedCounter++));
    }

    // ------------------------------------------------------------ actions

    function placeBet(uint256 actorIdx, uint256 wager) external {
        address actor = _actor(actorIdx);
        if (table.activeGameOf(actor) != 0) return;
        wager = bound(wager, table.minWager(), table.maxWager());
        if (2 * wager > table.availableLiquidity()) return;
        if (chip.balanceOf(actor) < wager) {
            vm.prank(admin);
            chip.mint(actor, wager * 10);
        }
        vm.prank(actor);
        table.placeBet(wager);
    }

    function fulfillPending(uint256 actorIdx) external {
        address actor = _actor(actorIdx);
        uint256 gameId = table.activeGameOf(actor);
        if (gameId == 0) return;
        BlackjackTable.Game memory g = table.getGame(gameId);
        if (g.pendingRequestId == 0) return;
        mock.fulfill(g.pendingRequestId, _nextSeed());
    }

    function hitAction(uint256 actorIdx) external {
        address actor = _actor(actorIdx);
        uint256 gameId = table.activeGameOf(actor);
        if (gameId == 0) return;
        if (table.getGame(gameId).state != BlackjackTable.GameState.PLAYER_TURN) return;
        vm.prank(actor);
        table.hit();
    }

    function standAction(uint256 actorIdx) external {
        address actor = _actor(actorIdx);
        uint256 gameId = table.activeGameOf(actor);
        if (gameId == 0) return;
        if (table.getGame(gameId).state != BlackjackTable.GameState.PLAYER_TURN) return;
        vm.prank(actor);
        table.stand();
    }

    function fundHouse(uint256 amount) external {
        amount = bound(amount, 0, 1_000_000e18);
        if (amount == 0) return;
        vm.startPrank(admin);
        chip.mint(admin, amount);
        table.fundHouse(amount);
        vm.stopPrank();
    }

    function withdrawHouse(uint256 amount) external {
        uint256 available = table.availableLiquidity();
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(admin);
        table.withdrawHouseFunds(admin, amount);
    }

    /// Donations must never break accounting (they are simply unaccounted surplus).
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000e18);
        vm.startPrank(admin);
        chip.mint(admin, amount);
        chip.transfer(address(table), amount);
        vm.stopPrank();
        ghostTotalDonated += amount;
    }
}
