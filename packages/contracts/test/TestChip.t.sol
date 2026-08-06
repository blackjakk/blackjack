// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TestChip} from "../src/TestChip.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TestChipTest is Test {
    TestChip chip;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        chip = new TestChip(owner);
    }

    function test_faucet_mintsFixedAmount() public {
        vm.prank(alice);
        chip.faucet();
        assertEq(chip.balanceOf(alice), chip.FAUCET_AMOUNT());
    }

    function test_faucet_cooldownBlocksSecondClaim() public {
        vm.startPrank(alice);
        chip.faucet();
        vm.expectRevert(
            abi.encodeWithSelector(
                TestChip.FaucetCooldownActive.selector, block.timestamp + chip.FAUCET_COOLDOWN()
            )
        );
        chip.faucet();
        vm.stopPrank();
    }

    function test_faucet_claimAgainAfterCooldown() public {
        vm.startPrank(alice);
        chip.faucet();
        vm.warp(block.timestamp + chip.FAUCET_COOLDOWN());
        chip.faucet();
        vm.stopPrank();
        assertEq(chip.balanceOf(alice), 2 * chip.FAUCET_AMOUNT());
    }

    function test_ownerMint() public {
        vm.prank(owner);
        chip.mint(alice, 123e18);
        assertEq(chip.balanceOf(alice), 123e18);
    }

    function test_mint_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        chip.mint(alice, 1e18);
    }
}
