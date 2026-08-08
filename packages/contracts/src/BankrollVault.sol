// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BlackjackTableV2} from "./BlackjackTableV2.sol";

/// @title BankrollVault
/// @notice ERC-4626 vault that IS a BlackjackTableV2's bankroll: deposits become
///         house funds, the share price tracks the house's wins and losses, and
///         withdrawals are limited to funds not reserved for in-flight games.
///         Play money only — NOT audited, NOT for real funds.
/// @dev Trust wiring: the vault must hold the table's TREASURY_ROLE, and for LPs
///      to be safe from admin rug-pulls it should be the ONLY holder (the deploy
///      script grants the vault and renounces the deployer; UIs should verify).
///      Deposits are forwarded into the table immediately; withdrawals pull the
///      shortfall back via withdrawHouseFunds, which the table caps at its
///      UNRESERVED liquidity — escrowed wagers and reserved liabilities for live
///      games can never be drained by LPs.
///
///      Known limitation (documented in docs/KNOWN_LIMITATIONS.md): a committed
///      drand beacon becomes publicly computable seconds before it is submitted
///      onchain, so an LP watching big pending hands could time an exit around a
///      house loss ("LP free look"). The permissionless keeper's fast fulfillment
///      keeps that window to seconds; acceptable for play money.
contract BankrollVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    BlackjackTableV2 public immutable table;

    error AssetMismatch();

    constructor(BlackjackTableV2 table_, string memory name_, string memory symbol_)
        ERC4626(table_.chip())
        ERC20(name_, symbol_)
    {
        table = table_;
        if (address(table_.chip()) != asset()) revert AssetMismatch();
    }

    /// @notice The vault's assets: anything idle here plus the table's bankroll
    ///         (which includes reserved liabilities — those are still house money
    ///         until a game settles against the house).
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + table.houseFunds();
    }

    /// @dev Assets an exit can actually pull right now.
    function _liquidAssets() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + table.availableLiquidity();
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), _liquidAssets());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return
            Math.min(super.maxRedeem(owner), _convertToShares(_liquidAssets(), Math.Rounding.Floor));
    }

    /// @dev Standard 4626 pull, then forward everything into the table bankroll so
    ///      deposits immediately back games.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
    {
        super._deposit(caller, receiver, assets, shares);
        IERC20(asset()).forceApprove(address(table), assets);
        table.fundHouse(assets);
    }

    /// @dev Pull the shortfall back from the table (bounded by its unreserved
    ///      liquidity) before the standard 4626 payout.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) {
            table.withdrawHouseFunds(address(this), assets - idle);
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Virtual-share offset: makes first-depositor share-price inflation
    ///      attacks economically useless (OZ standard defense).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
