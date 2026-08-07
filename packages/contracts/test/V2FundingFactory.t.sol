// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {V2TableTestBase} from "./utils/V2TableTestBase.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {TableFactory} from "../src/TableFactory.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Permissionless funding + factory registry behavior.
contract V2FundingFactoryTest is V2TableTestBase {
    function test_anyoneCanFundHouse() public {
        address lp = makeAddr("lp");
        vm.prank(admin);
        chip.mint(lp, 500e18);
        vm.startPrank(lp);
        chip.approve(address(tbl), type(uint256).max);
        uint256 before = tbl.houseFunds();
        tbl.fundHouse(500e18);
        vm.stopPrank();
        assertEq(tbl.houseFunds(), before + 500e18);
    }

    function test_onlyTreasuryWithdraws() public {
        address lp = makeAddr("lp");
        // Hoisted: an external call inside expectRevert args would consume the prank.
        bytes32 role = tbl.TREASURY_ROLE();
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, lp, role
            )
        );
        tbl.withdrawHouseFunds(lp, 1e18);

        uint256 before = chip.balanceOf(admin);
        vm.prank(admin);
        tbl.withdrawHouseFunds(admin, 100e18);
        assertEq(chip.balanceOf(admin), before + 100e18);
    }

    function test_withdrawCannotTouchReserved() public {
        bet(MAX_WAGER); // reserves 2x
        uint256 avail = tbl.availableLiquidity();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlackjackTableV2.WithdrawExceedsAvailable.selector, avail + 1, avail
            )
        );
        tbl.withdrawHouseFunds(admin, avail + 1);
    }

    function test_factoryRegistry() public {
        uint256 countBefore = factory.tableCount();
        address created = factory.createTable(_rules(), 1e18, 10e18, 2, address(0));
        assertEq(factory.tableCount(), countBefore + 1);
        assertEq(factory.tableAt(countBefore), created);
        assertEq(factory.allTables().length, countBefore + 1);

        // admin == address(0) defaults to the caller.
        BlackjackTableV2 t = BlackjackTableV2(created);
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(t.hasRole(t.TREASURY_ROLE(), address(this)));
        assertEq(address(t.chip()), address(chip));
        assertEq(address(t.randomnessProvider()), address(mock));
    }

    function test_factoryRejectsZeroAddresses() public {
        vm.expectRevert(TableFactory.ZeroAddress.selector);
        new TableFactory(IERC20(address(0)), IRandomnessProvider(address(mock)));
        vm.expectRevert(TableFactory.ZeroAddress.selector);
        new TableFactory(IERC20(address(chip)), IRandomnessProvider(address(0)));
    }
}
