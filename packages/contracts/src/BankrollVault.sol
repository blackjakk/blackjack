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
///      Exit free-look defense: a committed drand beacon becomes publicly
///      computable before it is submitted onchain, so instant exits would let an
///      LP dodge a house loss they can already see coming. Withdrawals therefore
///      go through a DELAYED QUEUE: requestRedeem escrows the shares, and claim()
///      pays out at the share price AT CLAIM TIME, no earlier than withdrawDelay
///      later. With withdrawDelay >= the table's randomness timeout, every hand
///      that was computable at request time has settled (or become cancellable)
///      before the price is struck — advance knowledge is worthless. The 4626
///      withdraw/redeem entry points are disabled accordingly (maxWithdraw and
///      maxRedeem return 0); deposits remain standard.
contract BankrollVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    BlackjackTableV2 public immutable table;

    /// @notice Minimum time between requesting an exit and its price being struck.
    uint64 public immutable withdrawDelay;

    struct ExitRequest {
        uint192 shares; // escrowed in the vault until claimed
        uint64 claimableAt;
    }

    /// @notice One aggregate pending exit per address (new requests extend the clock).
    mapping(address => ExitRequest) public exitRequests;

    uint64 internal constant MIN_DELAY = 10 minutes;
    uint64 internal constant MAX_DELAY = 7 days;

    event ExitRequested(address indexed owner, uint256 shares, uint64 claimableAt);
    event ExitClaimed(address indexed owner, address indexed receiver, uint256 shares, uint256 assets);

    error AssetMismatch();
    error InvalidDelay();
    error UseExitQueue();
    error NothingRequested();
    error NotClaimableYet(uint64 claimableAt);

    constructor(
        BlackjackTableV2 table_,
        uint64 withdrawDelay_,
        string memory name_,
        string memory symbol_
    ) ERC4626(table_.chip()) ERC20(name_, symbol_) {
        table = table_;
        if (address(table_.chip()) != asset()) revert AssetMismatch();
        if (withdrawDelay_ < MIN_DELAY || withdrawDelay_ > MAX_DELAY) revert InvalidDelay();
        withdrawDelay = withdrawDelay_;
    }

    // ------------------------------------------------------------- exit queue

    /// @notice Start (or top up) a delayed exit: `shares` move into vault escrow
    ///         and become claimable after withdrawDelay. Requests are
    ///         NON-cancellable and topping up restarts the clock — otherwise a
    ///         standing request would be a free option on the share price.
    function requestRedeem(uint256 shares) external {
        if (shares == 0) revert NothingRequested();
        _transfer(msg.sender, address(this), shares); // reverts on insufficient balance
        ExitRequest storage r = exitRequests[msg.sender];
        r.shares += uint192(shares);
        r.claimableAt = uint64(block.timestamp) + withdrawDelay;
        emit ExitRequested(msg.sender, shares, r.claimableAt);
    }

    /// @notice Claim a matured exit at the CURRENT share price. Reverts if the
    ///         table cannot release enough unreserved liquidity right now (retry
    ///         once in-flight games settle).
    function claim(address receiver) external returns (uint256 assets) {
        ExitRequest memory r = exitRequests[msg.sender];
        if (r.shares == 0) revert NothingRequested();
        if (block.timestamp < r.claimableAt) revert NotClaimableYet(r.claimableAt);
        delete exitRequests[msg.sender];

        assets = previewRedeem(r.shares);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) {
            table.withdrawHouseFunds(address(this), assets - idle);
        }
        _burn(address(this), r.shares);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit ExitClaimed(msg.sender, receiver, r.shares, assets);
        emit Withdraw(msg.sender, receiver, address(this), assets, r.shares);
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

    /// @dev Instant exits are disabled — use requestRedeem/claim.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Instant exits are disabled — use requestRedeem/claim.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
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

    /// @dev Blocks the standard 4626 exit paths (withdraw/redeem) — the delayed
    ///      queue is the only way out.
    function _withdraw(address, address, address, uint256, uint256) internal pure override {
        revert UseExitQueue();
    }

    /// @dev Virtual-share offset: makes first-depositor share-price inflation
    ///      attacks economically useless (OZ standard defense).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
