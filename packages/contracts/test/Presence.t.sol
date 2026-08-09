// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Presence} from "../src/Presence.sol";

contract PresenceTest is Test {
    Presence internal presence;
    address internal burner = makeAddr("burner");
    address internal main = makeAddr("main");
    address internal tbl = makeAddr("table");

    event Ping(address indexed sender, address indexed account, address indexed table);

    function setUp() public {
        presence = new Presence();
        // Foundry's clock starts near zero; real chains are far past COOLDOWN,
        // which is what makes a first-ever ping always admissible.
        vm.warp(1_700_000_000);
    }

    function test_pingEmitsAndStampsClock() public {
        vm.prank(burner);
        vm.expectEmit(true, true, true, true);
        emit Ping(burner, main, tbl);
        presence.ping(main, tbl);
        assertEq(presence.lastPing(burner), uint64(block.timestamp));
    }

    function test_cooldownPerSender() public {
        vm.prank(burner);
        presence.ping(main, tbl);
        vm.prank(burner);
        vm.expectRevert(Presence.TooFast.selector);
        presence.ping(main, tbl);

        // Another sender is unaffected; the same sender recovers after COOLDOWN.
        vm.prank(makeAddr("other"));
        presence.ping(address(0), address(0));
        vm.warp(block.timestamp + presence.COOLDOWN());
        vm.prank(burner);
        presence.ping(main, address(0));
    }

    function test_zeroFieldsAllowed() public {
        vm.prank(burner);
        presence.ping(address(0), address(0)); // browsing, wallet not connected
    }
}
