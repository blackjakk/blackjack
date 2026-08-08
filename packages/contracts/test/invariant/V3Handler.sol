// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TestChip} from "../../src/TestChip.sol";
import {BlackjackTableV3} from "../../src/BlackjackTableV3.sol";
import {MockRandomnessProvider} from "../../src/rand/MockRandomnessProvider.sol";

/// @notice Bounded-action handler driving a v2 table (surrender-enabled classic rules,
///         multi-game) through random interleavings: bets across actors, fulfillments,
///         all player actions, timeout cancels, permissionless funding and treasury
///         withdrawals. Preconditions are guarded so every call path is meaningful.
contract V3Handler is Test {
    TestChip public chip;
    MockRandomnessProvider public mock;
    BlackjackTableV3 public tbl;
    address public admin;

    address[3] public actors;
    uint256 public ghostSettled;
    uint256 public ghostCancelled;

    constructor(
        TestChip chip_,
        MockRandomnessProvider mock_,
        BlackjackTableV3 tbl_,
        address admin_
    ) {
        chip = chip_;
        mock = mock_;
        tbl = tbl_;
        admin = admin_;
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
        for (uint256 i; i < 3; i++) {
            vm.startPrank(actors[i]);
            chip.approve(address(tbl), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    /// @dev A live game of `who` chosen by seed, or 0 when none.
    function _liveGame(address who, uint256 seed) internal view returns (uint256) {
        uint256[] memory list = tbl.activeGamesOf(who);
        if (list.length == 0) return 0;
        return list[seed % list.length];
    }

    function placeBet(uint256 actorSeed, uint256 wagerSeed) external {
        address who = _actor(actorSeed);
        uint256 wager = bound(wagerSeed, tbl.minWager(), tbl.maxWager());
        if (tbl.activeGameCountOf(who) >= tbl.maxConcurrentGames()) return;
        if (tbl.availableLiquidity() < wager * 2) return;
        if (chip.balanceOf(who) < wager) return;
        vm.prank(who);
        tbl.placeBet(wager);
    }

    function fulfillPending(uint256 actorSeed, uint256 gameSeed, bytes32 seed) external {
        uint256 gameId = _liveGame(_actor(actorSeed), gameSeed);
        if (gameId == 0) return;
        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        if (g.pendingRequestId == 0) return;
        mock.fulfill(g.pendingRequestId, seed);
    }

    function act(uint256 actorSeed, uint256 gameSeed, uint256 actionSeed) external {
        address who = _actor(actorSeed);
        uint256 gameId = _liveGame(who, gameSeed);
        if (gameId == 0) return;
        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        if (g.state != BlackjackTableV3.GameState.PLAYER_TURN) return;

        uint256 action = actionSeed % 5;
        if (action == 0) {
            vm.prank(who);
            tbl.hit(gameId);
        } else if (action == 1) {
            vm.prank(who);
            tbl.stand(gameId);
        } else if (action == 2) {
            if (g.playerCount != 2 || g.doubled) return;
            if (chip.balanceOf(who) < g.wager) return;
            vm.prank(who);
            tbl.double(gameId);
        } else if (action == 3) {
            if (g.playerCount != 2 || g.doubled || g.split) return;
            vm.prank(who);
            tbl.surrender(gameId);
            ghostSettled++;
        } else {
            // split when the pair qualifies
            if (g.playerCount != 2 || g.doubled || g.split) return;
            uint8 c0 = uint8(g.playerCards & 0xff);
            uint8 c1 = uint8((g.playerCards >> 8) & 0xff);
            if (_val(c0) != _val(c1)) return;
            if (chip.balanceOf(who) < g.wager) return;
            vm.prank(who);
            tbl.split(gameId);
        }
    }

    function _val(uint8 card) internal pure returns (uint8) {
        uint8 rank = card % 13;
        if (rank == 0) return 1;
        if (rank >= 9) return 10;
        return rank + 1;
    }

    function cancelTimedOut(uint256 actorSeed, uint256 gameSeed) external {
        address who = _actor(actorSeed);
        uint256 gameId = _liveGame(who, gameSeed);
        if (gameId == 0) return;
        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        if (g.pendingRequestId == 0) return; // only awaiting states carry a request
        vm.warp(block.timestamp + tbl.randomnessTimeout() + 1);
        vm.prank(who);
        tbl.cancelTimedOutGame(gameId);
        ghostCancelled++;
    }

    function fundHouse(uint256 amountSeed) external {
        address lp = makeAddr("lp");
        uint256 amount = bound(amountSeed, 1, 10_000e18);
        vm.prank(admin);
        chip.mint(lp, amount);
        vm.startPrank(lp);
        chip.approve(address(tbl), amount);
        tbl.fundHouse(amount);
        vm.stopPrank();
    }

    function withdraw(uint256 amountSeed) external {
        uint256 avail = tbl.availableLiquidity();
        if (avail == 0) return;
        uint256 amount = bound(amountSeed, 1, avail);
        vm.prank(admin);
        tbl.withdrawHouseFunds(admin, amount);
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}
