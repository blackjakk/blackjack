// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBankrollTable} from "./interfaces/IBankrollTable.sol";

/// @title SharedBankrollVault
/// @notice ERC-4626 vault that is the bankroll for EVERY game of one asset: one MEGA
///         vault backs the MEGA classic table, the MEGA split table, the MEGA infinite
///         table, and any future MEGA game added to its member registry. LP deposits
///         sit idle in the vault until pushed into member tables; the share price
///         tracks wins/losses across the whole set. Play money only — NOT audited,
///         NOT for real funds.
/// @dev Trust wiring (all documented in docs/KNOWN_LIMITATIONS.md):
///      - The vault must hold each member table's TREASURY_ROLE, and should be the
///        ONLY holder so LP funds cannot be withdrawn around the vault.
///      - Membership is DEFAULT_ADMIN_ROLE-gated and is this design's central trust
///        point: a malicious or buggy member table poisons the WHOLE asset pool
///        (`totalAssets` sums member `houseFunds`). Members must be verified game
///        code only. This role is the natural first thing a future governance token
///        takes over.
///      - `fundTable` (idle -> member bankroll) is permissionless: it never changes
///        totalAssets, and pushing funds into a curated member is what deposits are
///        for. `defundTable` is REBALANCER_ROLE-gated.
///
///      Exit free-look defense is inherited from BankrollVault: delayed exit queue,
///      price struck at claim, instant 4626 exits disabled. claim() pays from idle
///      funds first, then pulls the shortfall out of member tables' UNRESERVED
///      liquidity.
contract SharedBankrollVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice May pull unreserved funds out of member tables back into the vault.
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    /// @notice Minimum time between requesting an exit and its price being struck.
    uint64 public immutable withdrawDelay;

    IBankrollTable[] internal _tables;
    mapping(address => bool) public isMember;

    struct ExitRequest {
        uint192 shares; // escrowed in the vault until claimed
        uint64 claimableAt;
    }

    /// @notice One aggregate pending exit per address (new requests extend the clock).
    mapping(address => ExitRequest) public exitRequests;

    uint64 internal constant MIN_DELAY = 10 minutes;
    uint64 internal constant MAX_DELAY = 7 days;
    uint256 internal constant MAX_TABLES = 16; // bounds the totalAssets/claim loops

    event TableAdded(address indexed table);
    event TableRemoved(address indexed table);
    event TableFunded(address indexed table, address indexed by, uint256 amount);
    event TableDefunded(address indexed table, address indexed by, uint256 amount);
    event ExitRequested(address indexed owner, uint256 shares, uint64 claimableAt);
    event ExitClaimed(
        address indexed owner, address indexed receiver, uint256 shares, uint256 assets
    );

    error InvalidDelay();
    error UseExitQueue();
    error NothingRequested();
    error NotClaimableYet(uint64 claimableAt);
    error AssetMismatch(address table);
    error NotAMember(address table);
    error AlreadyMember(address table);
    error TooManyTables();
    error VaultNotTreasury(address table);
    error TableNotEmpty(address table);
    error InsufficientLiquidAssets(uint256 needed, uint256 liquid);

    constructor(
        IERC20 asset_,
        uint64 withdrawDelay_,
        string memory name_,
        string memory symbol_,
        address admin_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        if (withdrawDelay_ < MIN_DELAY || withdrawDelay_ > MAX_DELAY) revert InvalidDelay();
        withdrawDelay = withdrawDelay_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(REBALANCER_ROLE, admin_);
    }

    // ------------------------------------------------------------- membership

    /// @notice Add a game table to the pool this vault's LPs are backing. THE trust
    ///         point of the design — see the contract-level dev note.
    function addTable(IBankrollTable table_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address t = address(table_);
        if (isMember[t]) revert AlreadyMember(t);
        if (_tables.length >= MAX_TABLES) revert TooManyTables();
        if (address(table_.chip()) != asset()) revert AssetMismatch(t);
        // Sanity: membership is useless (and claim() would brick) unless the vault
        // can actually pull funds back out of the table.
        if (!table_.hasRole(table_.TREASURY_ROLE(), address(this))) revert VaultNotTreasury(t);
        isMember[t] = true;
        _tables.push(table_);
        emit TableAdded(t);
    }

    /// @notice Remove a member table. Only allowed once the table holds no house
    ///         funds (defund it first) so no LP assets are stranded outside the sum.
    function removeTable(IBankrollTable table_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address t = address(table_);
        if (!isMember[t]) revert NotAMember(t);
        if (table_.houseFunds() != 0) revert TableNotEmpty(t);
        isMember[t] = false;
        uint256 len = _tables.length;
        for (uint256 i; i < len; ++i) {
            if (address(_tables[i]) == t) {
                _tables[i] = _tables[len - 1];
                _tables.pop();
                break;
            }
        }
        emit TableRemoved(t);
    }

    /// @notice Member tables currently backed by this vault.
    function tables() external view returns (address[] memory list) {
        uint256 len = _tables.length;
        list = new address[](len);
        for (uint256 i; i < len; ++i) {
            list[i] = address(_tables[i]);
        }
    }

    // ------------------------------------------------------------- rebalancing

    /// @notice Push idle vault funds into a member table's bankroll so it can accept
    ///         bets. PERMISSIONLESS: totalAssets is unchanged and members are curated,
    ///         so the worst anyone can do is fund a table (frontends call this right
    ///         after a deposit; the keeper tops tables up on a schedule).
    function fundTable(IBankrollTable table_, uint256 amount) external nonReentrant {
        if (!isMember[address(table_)]) revert NotAMember(address(table_));
        IERC20(asset()).forceApprove(address(table_), amount);
        table_.fundHouse(amount);
        emit TableFunded(address(table_), msg.sender, amount);
    }

    /// @notice Pull UNRESERVED funds from a member table back to idle (e.g. to
    ///         rebalance toward a busier table or build the claim buffer).
    function defundTable(IBankrollTable table_, uint256 amount)
        external
        nonReentrant
        onlyRole(REBALANCER_ROLE)
    {
        if (!isMember[address(table_)]) revert NotAMember(address(table_));
        table_.withdrawHouseFunds(address(this), amount);
        emit TableDefunded(address(table_), msg.sender, amount);
    }

    // ------------------------------------------------------------- exit queue

    /// @notice Start (or top up) a delayed exit: `shares` move into vault escrow and
    ///         become claimable after withdrawDelay. Requests are NON-cancellable and
    ///         topping up restarts the clock — otherwise a standing request would be
    ///         a free option on the share price.
    function requestRedeem(uint256 shares) external {
        if (shares == 0) revert NothingRequested();
        _transfer(msg.sender, address(this), shares); // reverts on insufficient balance
        ExitRequest storage r = exitRequests[msg.sender];
        r.shares += uint192(shares);
        r.claimableAt = uint64(block.timestamp) + withdrawDelay;
        emit ExitRequested(msg.sender, shares, r.claimableAt);
    }

    /// @notice Claim a matured exit at the CURRENT share price, paying from idle
    ///         funds first and then from member tables' unreserved liquidity.
    ///         Reverts if too much of the pool is reserved for in-flight games right
    ///         now (retry once games settle).
    function claim(address receiver) external nonReentrant returns (uint256 assets) {
        ExitRequest memory r = exitRequests[msg.sender];
        if (r.shares == 0) revert NothingRequested();
        if (block.timestamp < r.claimableAt) revert NotClaimableYet(r.claimableAt);
        delete exitRequests[msg.sender];

        assets = previewRedeem(r.shares);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) {
            uint256 shortfall = assets - idle;
            uint256 len = _tables.length;
            for (uint256 i; i < len && shortfall > 0; ++i) {
                uint256 pull = _tables[i].availableLiquidity();
                if (pull == 0) continue;
                if (pull > shortfall) pull = shortfall;
                _tables[i].withdrawHouseFunds(address(this), pull);
                shortfall -= pull;
            }
            if (shortfall > 0) revert InsufficientLiquidAssets(assets, liquidAssets());
        }
        _burn(address(this), r.shares);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit ExitClaimed(msg.sender, receiver, r.shares, assets);
        emit Withdraw(msg.sender, receiver, address(this), assets, r.shares);
    }

    // ------------------------------------------------------------- 4626 overrides

    /// @notice The pool's assets: idle funds plus every member table's bankroll
    ///         (reserved liabilities included — still house money until a game
    ///         settles against the house).
    function totalAssets() public view override returns (uint256) {
        uint256 sum = IERC20(asset()).balanceOf(address(this));
        uint256 len = _tables.length;
        for (uint256 i; i < len; ++i) {
            sum += _tables[i].houseFunds();
        }
        return sum;
    }

    /// @notice Assets an exit could actually pull right now (idle + unreserved).
    function liquidAssets() public view returns (uint256) {
        uint256 sum = IERC20(asset()).balanceOf(address(this));
        uint256 len = _tables.length;
        for (uint256 i; i < len; ++i) {
            sum += _tables[i].availableLiquidity();
        }
        return sum;
    }

    /// @dev Instant exits are disabled — use requestRedeem/claim.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Instant exits are disabled — use requestRedeem/claim.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Blocks the standard 4626 exit paths — the delayed queue is the only way
    ///      out. Deposits are standard and stay idle until pushed via fundTable.
    function _withdraw(address, address, address, uint256, uint256) internal pure override {
        revert UseExitQueue();
    }

    /// @dev Virtual-share offset: makes first-depositor share-price inflation
    ///      attacks economically useless (OZ standard defense).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
