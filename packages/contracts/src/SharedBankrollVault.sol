// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBankrollTable} from "./interfaces/IBankrollTable.sol";

/// @notice Minimal provenance surface a trusted factory exposes: did THIS factory
///         deploy that contract (i.e. is it byte-identical to reviewed game code)?
interface ITableProvenance {
    function isFromFactory(address table) external view returns (bool);
}

/// @title SharedBankrollVault
/// @notice ERC-4626 vault that is the bankroll for EVERY approved game of one
///         asset. LP deposits sit idle until pushed into member tables (subject to
///         per-game float caps); the share price tracks wins/losses across the
///         whole set. Play money only — NOT audited, NOT for real funds.
/// @dev Membership is a GOVERNANCE ACTION with economic skin in the game:
///      - proposeTable(table, maxFloat) pulls a bond in `bondToken` (MEGA) from
///        the proposer and starts a timelock; activateTable is permissionless
///        after it. FACTORY-PROVENANCED tables (byte-identical to reviewed game
///        code, proven via a trusted factory registry) are tier 1: smaller bond,
///        quarter delay. Novel-engine tables are tier 2: full bond + full delay.
///      - Delays are enforced far above the exit-queue delay, so every LP who
///        distrusts a proposal completes a fair-price exit before activation.
///        Zero-shares vaults add instantly and bond-free (nobody to protect;
///        depositors see the member list up front).
///      - EXPOSURE CAPS bound what a malicious member could ever cost the pool:
///        fundTable enforces net pushed funds <= maxFloat, and totalAssets counts
///        a member's houseFunds only up to 2x maxFloat — so a lying table cannot
///        inflate the pool's books beyond a known bound, and the bond is sized
///        against a KNOWN worst case instead of the whole pool.
///      - claimDefault() is the OBJECTIVE slash: any caller can make the pool
///        test a member's reported liquidity; a member that reports funds it
///        cannot deliver is ejected and its bond forfeits to `bondBeneficiary`
///        (governance, for LP compensation). Honest game code can never fail the
///        test — read and withdrawal happen in one transaction.
///      - DEFAULT_ADMIN_ROLE is meant to be a TimelockController, later governed
///        by a token — every privileged action is then public and delayed.
///        Unapproved games run on their own per-table BankrollVault.
///
///      Exit free-look defense is inherited from BankrollVault: delayed exit
///      queue, price struck at claim, instant 4626 exits disabled.
contract SharedBankrollVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice May pull unreserved funds out of member tables back into the vault.
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    /// @notice Minimum time between requesting an exit and its price being struck.
    uint64 public immutable withdrawDelay;
    /// @notice Membership timelock for tier-2 (novel-code) proposals. Tier-1
    ///         (factory-provenanced) proposals wait a quarter of this. Enforced
    ///         >= 8x withdrawDelay so even the tier-1 delay covers a full exit.
    uint64 public immutable membershipDelay;

    /// @notice Token bonds are posted in (MEGA), independent of the pool asset.
    IERC20 public immutable bondToken;
    /// @notice Where slashed bonds go (governance — compensates LPs off-band).
    address public immutable bondBeneficiary;
    /// @notice Required bond per tier (tier 1 = factory-provenanced, tier 2 = novel).
    uint256 public tier1Bond;
    uint256 public tier2Bond;

    struct Membership {
        bool isMember;
        uint96 maxFloat; // cap on net funds the pool will push into the table
        uint96 netPushed; // pushed minus pulled, floored at zero
        address proposer; // bond refund recipient
        uint96 bond; // posted at proposal, returned on clean exit, slashed on default
        uint64 activatableAt; // pending-proposal eta (0 = none pending)
    }

    mapping(address => Membership) public memberships;
    IBankrollTable[] internal _tables;
    address[] internal _proposals;
    /// @notice Factories whose deployments count as reviewed game code (tier 1).
    mapping(address => bool) public trustedFactories;

    struct ExitRequest {
        uint192 shares;
        uint64 claimableAt;
    }

    /// @notice One aggregate pending exit per address (new requests extend the clock).
    mapping(address => ExitRequest) public exitRequests;

    uint64 internal constant MIN_DELAY = 10 minutes;
    uint64 internal constant MAX_DELAY = 7 days;
    uint256 internal constant MAX_TABLES = 16;
    uint256 internal constant MAX_FLOAT_BOUND = type(uint96).max;

    event TableProposed(
        address indexed table, address indexed proposer, uint8 tier, uint256 bond, uint256 maxFloat, uint64 activatableAt
    );
    event TableAdded(address indexed table, uint256 maxFloat);
    event TableProposalCancelled(address indexed table);
    event TableRemoved(address indexed table);
    event TableDefaulted(address indexed table, uint256 slashedBond);
    event TableFunded(address indexed table, address indexed by, uint256 amount);
    event TableDefunded(address indexed table, address indexed by, uint256 amount);
    event TrustedFactoryUpdated(address indexed factory, bool trusted);
    event BondsUpdated(uint256 tier1Bond, uint256 tier2Bond);
    event MaxFloatUpdated(address indexed table, uint256 maxFloat);
    event ExitRequested(address indexed owner, uint256 shares, uint64 claimableAt);
    event ExitClaimed(
        address indexed owner, address indexed receiver, uint256 shares, uint256 assets
    );

    error InvalidDelay();
    error InvalidConfig();
    error UseExitQueue();
    error NothingRequested();
    error NotClaimableYet(uint64 claimableAt);
    error AssetMismatch(address table);
    error NotAMember(address table);
    error AlreadyMember(address table);
    error AlreadyProposed(address table);
    error NotProposed(address table);
    error ProposalNotMatured(address table, uint64 activatableAt);
    error TooManyTables();
    error VaultNotTreasury(address table);
    error TableNotEmpty(address table);
    error FloatCapExceeded(address table, uint256 requested, uint256 cap);
    error NotDefaulted(address table);
    error InsufficientLiquidAssets(uint256 needed, uint256 liquid);

    constructor(
        IERC20 asset_,
        uint64 withdrawDelay_,
        uint64 membershipDelay_,
        IERC20 bondToken_,
        address bondBeneficiary_,
        uint256 tier2Bond_,
        string memory name_,
        string memory symbol_,
        address admin_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        if (withdrawDelay_ < MIN_DELAY || withdrawDelay_ > MAX_DELAY) revert InvalidDelay();
        // >= 8x: even the tier-1 quarter-delay covers request + queue + claim.
        if (membershipDelay_ < 8 * withdrawDelay_ || membershipDelay_ > 30 days) {
            revert InvalidDelay();
        }
        if (
            address(bondToken_) == address(0) || bondBeneficiary_ == address(0)
                || tier2Bond_ > type(uint96).max
        ) {
            revert InvalidConfig();
        }
        withdrawDelay = withdrawDelay_;
        membershipDelay = membershipDelay_;
        bondToken = bondToken_;
        bondBeneficiary = bondBeneficiary_;
        tier2Bond = tier2Bond_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(REBALANCER_ROLE, admin_);
    }

    // ------------------------------------------------------------- membership

    /// @notice Propose adding a game to the pool, posting the tier's bond in
    ///         `bondToken` and committing to a float cap. Factory-provenanced
    ///         tables (tier 1) wait membershipDelay/4; novel code (tier 2) waits
    ///         the full delay. A vault with zero shares outstanding activates
    ///         immediately and bond-free.
    function proposeTable(IBankrollTable table_, uint256 maxFloat_)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        address t = address(table_);
        _validateCandidate(table_);
        Membership storage m = memberships[t];
        if (m.activatableAt != 0) revert AlreadyProposed(t);
        if (maxFloat_ == 0 || maxFloat_ > MAX_FLOAT_BOUND) revert InvalidConfig();
        // forge-lint: disable-next-line(unsafe-typecast)
        m.maxFloat = uint96(maxFloat_);
        m.proposer = msg.sender;

        if (totalSupply() == 0) {
            _addTable(table_);
            return;
        }
        bool tier1 = _isProvenanced(t);
        uint256 bond = tier1 ? tier1Bond : tier2Bond;
        uint64 eta =
            uint64(block.timestamp) + (tier1 ? membershipDelay / 4 : membershipDelay);
        // forge-lint: disable-next-line(unsafe-typecast)
        m.bond = uint96(bond);
        m.activatableAt = eta;
        _proposals.push(t);
        emit TableProposed(t, msg.sender, tier1 ? 1 : 2, bond, maxFloat_, eta);
        if (bond > 0) bondToken.safeTransferFrom(msg.sender, address(this), bond);
    }

    /// @notice Activate a matured membership proposal. Permissionless — the
    ///         governance action was the proposal; execution is mechanical.
    function activateTable(IBankrollTable table_) external nonReentrant {
        address t = address(table_);
        Membership storage m = memberships[t];
        if (m.activatableAt == 0) revert NotProposed(t);
        if (block.timestamp < m.activatableAt) revert ProposalNotMatured(t, m.activatableAt);
        _validateCandidate(table_); // re-check: conditions may have changed since
        _removeProposal(t);
        _addTable(table_);
    }

    /// @notice Withdraw a pending membership proposal; the bond goes back.
    function cancelTableProposal(IBankrollTable table_)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        address t = address(table_);
        Membership storage m = memberships[t];
        if (m.activatableAt == 0) revert NotProposed(t);
        uint256 bond = m.bond;
        address proposer = m.proposer;
        _removeProposal(t);
        delete memberships[t];
        emit TableProposalCancelled(t);
        if (bond > 0) bondToken.safeTransfer(proposer, bond);
    }

    /// @notice Remove a member that has been fully defunded; its bond goes back
    ///         to the proposer (the clean-exit path).
    function removeTable(IBankrollTable table_) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        address t = address(table_);
        Membership storage m = memberships[t];
        if (!m.isMember) revert NotAMember(t);
        if (table_.houseFunds() != 0) revert TableNotEmpty(t);
        uint256 bond = m.bond;
        address proposer = m.proposer;
        _dropMember(t);
        emit TableRemoved(t);
        if (bond > 0) bondToken.safeTransfer(proposer, bond);
    }

    /// @notice OBJECTIVE default test, callable by anyone: make the pool pull
    ///         `amount` a member REPORTS as available. Read and withdrawal happen
    ///         in one transaction, so honest game code can never fail it. A
    ///         member that cannot deliver what it reports is ejected and its
    ///         bond forfeits to governance for LP compensation.
    function claimDefault(IBankrollTable table_, uint256 amount) external nonReentrant {
        address t = address(table_);
        Membership storage m = memberships[t];
        if (!m.isMember) revert NotAMember(t);
        if (amount == 0 || amount > table_.availableLiquidity()) revert InvalidConfig();

        uint256 before = IERC20(asset()).balanceOf(address(this));
        bool delivered;
        try table_.withdrawHouseFunds(address(this), amount) {
            delivered = IERC20(asset()).balanceOf(address(this)) - before == amount;
        } catch {
            delivered = false;
        }
        if (delivered) {
            // Not a default — treat as an ordinary (permissionless) defund probe.
            m.netPushed = m.netPushed > amount ? m.netPushed - uint96(amount) : 0;
            emit TableDefunded(t, msg.sender, amount);
            return;
        }
        uint256 bond = m.bond;
        _dropMember(t);
        emit TableDefaulted(t, bond);
        if (bond > 0) bondToken.safeTransfer(bondBeneficiary, bond);
    }

    /// @notice Pending membership proposals and their activation times.
    function pendingProposals()
        external
        view
        returns (address[] memory tables_, uint64[] memory activatableAt)
    {
        uint256 len = _proposals.length;
        tables_ = new address[](len);
        activatableAt = new uint64[](len);
        for (uint256 i; i < len; ++i) {
            tables_[i] = _proposals[i];
            activatableAt[i] = memberships[_proposals[i]].activatableAt;
        }
    }

    /// @notice Member tables currently backed by this vault.
    function tables() external view returns (address[] memory list) {
        uint256 len = _tables.length;
        list = new address[](len);
        for (uint256 i; i < len; ++i) {
            list[i] = address(_tables[i]);
        }
    }

    function isMember(address table_) external view returns (bool) {
        return memberships[table_].isMember;
    }

    // ------------------------------------------------------------- admin config

    /// @notice Mark a factory's deployments as reviewed game code (tier 1).
    ///         Admin = timelock/governance, so this is itself public + delayed.
    function setTrustedFactory(address factory, bool trusted)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (trustedFactories[factory] == trusted) return;
        trustedFactories[factory] = trusted;
        if (trusted) {
            _factoryList.push(factory);
        } else {
            uint256 len = _factoryList.length;
            for (uint256 i; i < len; ++i) {
                if (_factoryList[i] == factory) {
                    _factoryList[i] = _factoryList[len - 1];
                    _factoryList.pop();
                    break;
                }
            }
        }
        emit TrustedFactoryUpdated(factory, trusted);
    }

    function setBonds(uint256 tier1Bond_, uint256 tier2Bond_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (tier1Bond_ > type(uint96).max || tier2Bond_ > type(uint96).max) {
            revert InvalidConfig();
        }
        tier1Bond = tier1Bond_;
        tier2Bond = tier2Bond_;
        emit BondsUpdated(tier1Bond_, tier2Bond_);
    }

    /// @notice Raise/lower a member's float cap (a governance judgment as track
    ///         record accumulates).
    function setMaxFloat(IBankrollTable table_, uint256 maxFloat_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        address t = address(table_);
        if (!memberships[t].isMember) revert NotAMember(t);
        if (maxFloat_ == 0 || maxFloat_ > MAX_FLOAT_BOUND) revert InvalidConfig();
        // forge-lint: disable-next-line(unsafe-typecast)
        memberships[t].maxFloat = uint96(maxFloat_);
        emit MaxFloatUpdated(t, maxFloat_);
    }

    // ------------------------------------------------------------- rebalancing

    /// @notice Push idle vault funds into a member's bankroll, bounded by its
    ///         float cap. PERMISSIONLESS: totalAssets is unchanged, members are
    ///         governance-approved, and the cap bounds pool exposure.
    function fundTable(IBankrollTable table_, uint256 amount) external nonReentrant {
        address t = address(table_);
        Membership storage m = memberships[t];
        if (!m.isMember) revert NotAMember(t);
        uint256 newNet = uint256(m.netPushed) + amount;
        if (newNet > m.maxFloat) revert FloatCapExceeded(t, newNet, m.maxFloat);
        // forge-lint: disable-next-line(unsafe-typecast)
        m.netPushed = uint96(newNet);
        IERC20(asset()).forceApprove(t, amount);
        table_.fundHouse(amount);
        emit TableFunded(t, msg.sender, amount);
    }

    /// @notice Pull UNRESERVED funds from a member back to idle (rebalance or
    ///         profit skim — skims keep reported bankrolls near the counted cap).
    function defundTable(IBankrollTable table_, uint256 amount)
        external
        nonReentrant
        onlyRole(REBALANCER_ROLE)
    {
        address t = address(table_);
        Membership storage m = memberships[t];
        if (!m.isMember) revert NotAMember(t);
        table_.withdrawHouseFunds(address(this), amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        m.netPushed = m.netPushed > amount ? m.netPushed - uint96(amount) : 0;
        emit TableDefunded(t, msg.sender, amount);
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

    /// @notice Claim a matured exit at the CURRENT share price, paying from idle
    ///         funds first and then from members' unreserved liquidity.
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
                IBankrollTable tbl = _tables[i];
                uint256 pull = tbl.availableLiquidity();
                if (pull == 0) continue;
                if (pull > shortfall) pull = shortfall;
                tbl.withdrawHouseFunds(address(this), pull);
                Membership storage m = memberships[address(tbl)];
                // forge-lint: disable-next-line(unsafe-typecast)
                m.netPushed = m.netPushed > pull ? m.netPushed - uint96(pull) : 0;
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

    /// @notice The pool's assets: idle funds plus every member's bankroll, with
    ///         each member's contribution CAPPED at 2x its float — so a lying
    ///         member can inflate the books only up to a known, bonded bound.
    ///         (Reserved liabilities are still house money until games settle.)
    function totalAssets() public view override returns (uint256) {
        uint256 sum = IERC20(asset()).balanceOf(address(this));
        uint256 len = _tables.length;
        for (uint256 i; i < len; ++i) {
            sum += _countedHouseFunds(_tables[i]);
        }
        return sum;
    }

    /// @notice Assets an exit could actually pull right now (idle + unreserved,
    ///         same per-member cap as totalAssets).
    function liquidAssets() public view returns (uint256) {
        uint256 sum = IERC20(asset()).balanceOf(address(this));
        uint256 len = _tables.length;
        for (uint256 i; i < len; ++i) {
            uint256 avail = _tables[i].availableLiquidity();
            uint256 cap = uint256(memberships[address(_tables[i])].maxFloat) * 2;
            sum += avail < cap ? avail : cap;
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

    /// @dev Blocks the standard 4626 exit paths — the delayed queue is the only
    ///      way out. Deposits are standard and stay idle until pushed via fundTable.
    function _withdraw(address, address, address, uint256, uint256) internal pure override {
        revert UseExitQueue();
    }

    /// @dev Virtual-share offset: makes first-depositor share-price inflation
    ///      attacks economically useless (OZ standard defense).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ------------------------------------------------------------- internals

    function _countedHouseFunds(IBankrollTable table_) internal view returns (uint256) {
        uint256 reported = table_.houseFunds();
        uint256 cap = uint256(memberships[address(table_)].maxFloat) * 2;
        return reported < cap ? reported : cap;
    }

    /// @dev A table is tier 1 when any trusted factory attests it deployed it —
    ///      byte-identity with reviewed game code, checkable onchain. The trusted
    ///      set is a short governance-curated array.
    function _isProvenanced(address t) internal view returns (bool) {
        uint256 len = _factoryList.length;
        for (uint256 i; i < len; ++i) {
            address f = _factoryList[i];
            if (trustedFactories[f] && ITableProvenance(f).isFromFactory(t)) return true;
        }
        return false;
    }

    address[] internal _factoryList;

    /// @notice Enumerable trusted-factory list (for UIs and provenance checks).
    function factoryList() external view returns (address[] memory) {
        return _factoryList;
    }

    function _validateCandidate(IBankrollTable table_) internal view {
        address t = address(table_);
        if (memberships[t].isMember) revert AlreadyMember(t);
        if (_tables.length >= MAX_TABLES) revert TooManyTables();
        if (address(table_.chip()) != asset()) revert AssetMismatch(t);
        // Sanity: membership is useless (and claim() would brick) unless the vault
        // can actually pull funds back out of the table.
        if (!table_.hasRole(table_.TREASURY_ROLE(), address(this))) revert VaultNotTreasury(t);
    }

    function _addTable(IBankrollTable table_) internal {
        Membership storage m = memberships[address(table_)];
        m.isMember = true;
        m.activatableAt = 0;
        _tables.push(table_);
        emit TableAdded(address(table_), m.maxFloat);
    }

    function _dropMember(address t) internal {
        delete memberships[t];
        uint256 len = _tables.length;
        for (uint256 i; i < len; ++i) {
            if (address(_tables[i]) == t) {
                _tables[i] = _tables[len - 1];
                _tables.pop();
                break;
            }
        }
    }

    function _removeProposal(address t) internal {
        memberships[t].activatableAt = 0;
        uint256 len = _proposals.length;
        for (uint256 i; i < len; ++i) {
            if (_proposals[i] == t) {
                _proposals[i] = _proposals[len - 1];
                _proposals.pop();
                break;
            }
        }
    }
}
