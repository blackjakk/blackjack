// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TableTestBase} from "./utils/TableTestBase.sol";
import {BlackjackTable} from "../src/BlackjackTable.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Pause semantics and role-separation tests (Phase 3).
contract PauseAccessTest is TableTestBase {
    uint256 constant W = 100e18;
    address treasurer = makeAddr("treasurer");
    address rando = makeAddr("rando");

    function expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, account, role
            )
        );
    }

    // ---------------------------------------------------------- pause

    function test_pause_blocksNewRiskOnly() public {
        // An in-flight game in PLAYER_TURN...
        uint256 gameId = dealHand(W, TEN, FIVE, SIX);

        vm.prank(admin);
        table.pause();

        // New bets, hits and doubles are blocked.
        vm.startPrank(player);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        table.hit();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        table.double();

        // But stand still works, and fulfillment settles the game while paused.
        table.stand();
        vm.stopPrank();
        fulfill(gameId, findDealerSeed(SIX, 18, gameId));
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.SETTLED));

        // New games remain blocked until unpause.
        vm.prank(player);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        table.placeBet(W);

        vm.prank(admin);
        table.unpause();
        bet(W); // works again
    }

    function test_pause_fulfillDuringAwaitingStateWorks() public {
        uint256 gameId = bet(W);
        vm.prank(admin);
        table.pause();
        // The initial deal can still arrive while paused: games wind down, never freeze.
        fulfill(gameId, findInitialSeed(TEN, SIX, FIVE, gameId));
        assertEq(uint8(gameState(gameId)), uint8(BlackjackTable.GameState.PLAYER_TURN));
    }

    function test_pause_onlyAdmin() public {
        expectUnauthorized(rando, table.DEFAULT_ADMIN_ROLE());
        vm.prank(rando);
        table.pause();

        vm.prank(admin);
        table.pause();
        expectUnauthorized(rando, table.DEFAULT_ADMIN_ROLE());
        vm.prank(rando);
        table.unpause();
    }

    // ---------------------------------------------------------- roles

    function test_adminConfigSetters_rejectNonAdmin() public {
        vm.startPrank(rando);
        expectUnauthorized(rando, table.DEFAULT_ADMIN_ROLE());
        table.setWagerLimits(1e18, 10e18);
        expectUnauthorized(rando, table.DEFAULT_ADMIN_ROLE());
        table.setRandomnessProvider(IRandomnessProvider(address(mock)));
        expectUnauthorized(rando, table.DEFAULT_ADMIN_ROLE());
        table.setRandomnessTimeout(1 hours);
        vm.stopPrank();
    }

    function test_treasuryOps_rejectNonTreasury() public {
        vm.startPrank(rando);
        expectUnauthorized(rando, table.TREASURY_ROLE());
        table.fundHouse(1e18);
        expectUnauthorized(rando, table.TREASURY_ROLE());
        table.withdrawHouseFunds(rando, 1e18);
        vm.stopPrank();
    }

    function test_roleSeparation_treasuryWithoutAdmin() public {
        vm.startPrank(admin);
        table.grantRole(table.TREASURY_ROLE(), treasurer);
        table.revokeRole(table.TREASURY_ROLE(), admin);
        vm.stopPrank();

        // Treasurer can withdraw available funds but cannot pause or reconfigure.
        vm.prank(treasurer);
        table.withdrawHouseFunds(treasurer, 1e18);
        assertEq(chip.balanceOf(treasurer), 1e18);

        expectUnauthorized(treasurer, table.DEFAULT_ADMIN_ROLE());
        vm.prank(treasurer);
        table.pause();

        // And the admin, now without TREASURY_ROLE, cannot withdraw.
        expectUnauthorized(admin, table.TREASURY_ROLE());
        vm.prank(admin);
        table.withdrawHouseFunds(admin, 1e18);
    }

    // ---------------------------------------------------------- config validation

    function test_setWagerLimits_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(BlackjackTable.InvalidConfig.selector);
        table.setWagerLimits(0, 10e18); // zero min
        vm.expectRevert(BlackjackTable.InvalidConfig.selector);
        table.setWagerLimits(10e18, 1e18); // min > max
        vm.expectRevert(BlackjackTable.InvalidConfig.selector);
        table.setWagerLimits(1e18, type(uint96).max); // beyond absolute cap
        table.setWagerLimits(2e18, 500e18); // valid
        vm.stopPrank();
        assertEq(table.minWager(), 2e18);
        assertEq(table.maxWager(), 500e18);
    }

    function test_setRandomnessTimeout_bounds() public {
        vm.startPrank(admin);
        vm.expectRevert(BlackjackTable.InvalidConfig.selector);
        table.setRandomnessTimeout(9 minutes);
        vm.expectRevert(BlackjackTable.InvalidConfig.selector);
        table.setRandomnessTimeout(8 days);
        table.setRandomnessTimeout(30 minutes);
        vm.stopPrank();
        assertEq(table.randomnessTimeout(), 30 minutes);
    }

    // ---------------------------------------------------------- withdrawal cap

    function test_withdraw_cannotTouchReservedOrEscrow() public {
        bet(W); // escrow W, reserve 2W
        uint256 available = table.availableLiquidity();
        assertEq(available, HOUSE_BANKROLL - 2 * W);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTable.WithdrawExceedsAvailable.selector, available + 1, available
            )
        );
        table.withdrawHouseFunds(admin, available + 1);

        // Exactly the available amount is fine; escrow + reservation stay put.
        vm.prank(admin);
        table.withdrawHouseFunds(admin, available);
        assertEq(table.houseFunds(), 2 * W);
        assertEq(table.totalReservedLiability(), 2 * W);
        assertEq(chip.balanceOf(address(table)), 2 * W + W); // reserved + escrow
    }
}
