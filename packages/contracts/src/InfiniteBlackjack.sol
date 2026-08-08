// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IRandomnessProvider} from "./interfaces/IRandomnessProvider.sol";
import {IRandomnessConsumer} from "./interfaces/IRandomnessConsumer.sol";
import {BlackjackLib} from "./lib/BlackjackLib.sol";

/// @title InfiniteBlackjack
/// @notice Shared-table European no-hole-card blackjack: unlimited players bet into
///         one common round, everyone shares the SAME two-card starting hand and
///         dealer up-card, and each player then plays their own way from there
///         ("Infinite Blackjack" — which the infinite-shoe card model here matches
///         exactly). Play money only — NOT audited, NOT for real funds.
///
///         Round lifecycle (one drand beacon pair serves every player in the round):
///           1. BETTING      — open window, starts at the first bet;
///           2. DEAL_PENDING — beacon #1 requested only AFTER betting closed;
///           3. ACTING       — shared deal revealed; each player commits ONE action:
///                             stand / hit-to-target / double / surrender. No action
///                             by the deadline = auto-stand, so nobody can stall the
///                             table;
///           4. DRAW_PENDING — beacon #2 requested only AFTER actions locked, so no
///                             player could know their draw cards while deciding;
///           5. SETTLING     — every hit/double card and the dealer hand derive from
///                             beacon #2 (per-player derivation streams); a paginated
///                             permissionless sweep settles everyone.
///
///         "Hit to target" commits the standard strategy form of hitting: draw until
///         the hand's best total reaches the chosen target (12–21) or busts. It is
///         committed before beacon #2 exists, which is what makes a single shared
///         draw beacon fair.
/// @dev Accounting mirrors BlackjackTableV2: 2x wager reserved per bet covers every
///      payout path (natural capped at 2:1 profit; doubled 1:1 win = 2x profit with
///      the extra stake escrowed at act time). Exposes the same treasury surface
///      (fundHouse/withdrawHouseFunds/houseFunds/availableLiquidity/chip) so a
///      SharedBankrollVault can be its treasury.
contract InfiniteBlackjack is IRandomnessConsumer, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    enum RoundState {
        NONE,
        BETTING,
        DEAL_PENDING,
        ACTING,
        DRAW_PENDING,
        SETTLING,
        DONE,
        CANCELLED
    }

    /// @dev PENDING (0) doubles as "no action yet" and settles as an auto-stand.
    enum Action {
        PENDING,
        STAND,
        HIT,
        DOUBLE,
        SURRENDER
    }

    // Numeric values match v1/v2 so UIs/SDKs share outcome tables.
    enum Outcome {
        NONE,
        PLAYER_BLACKJACK,
        PLAYER_WIN,
        PUSH,
        DEALER_WIN,
        PLAYER_BUST,
        DEALER_BLACKJACK,
        CANCELLED_REFUND,
        SURRENDERED
    }

    enum DoubleRule {
        ANY_TWO,
        NINE_TO_ELEVEN,
        TEN_TO_ELEVEN,
        NO_DOUBLE
    }

    struct Rules {
        bool dealerHitsSoft17;
        uint16 blackjackNum; // natural pays wager * num / den, bounded [1:1, 2:1]
        uint16 blackjackDen;
        DoubleRule doubleRule;
        bool lateSurrender;
    }

    struct Round {
        RoundState state;
        uint64 betDeadline;
        uint64 actDeadline;
        uint64 requestTimestamp; // when the pending beacon was requested
        uint32 playerCount;
        uint32 actedCount;
        uint32 cursor; // settle/refund sweep progress
        uint256 pendingRequestId;
        address pendingProvider;
        bytes32 drawSeed; // beacon #2 — all hit/double/dealer cards derive from it
        uint256 playerCards; // shared two-card starting hand (packed)
        uint256 dealerCards; // up-card after the deal; full hand after beacon #2
        uint8 dealerCardCount;
    }

    struct Bet {
        uint96 wager;
        Action action;
        uint8 hitTarget; // HIT only: draw until best total >= target
        bool settled; // settle/refund sweep idempotency
        Outcome outcome;
        uint96 payout; // amount paid (incl. returned stake)
        uint256 cards; // final player hand, stored at settlement (packed)
        uint8 cardCount;
    }

    // ---------------------------------------------------------------- roles

    /// @notice May withdraw UNRESERVED house funds only. (Funding is permissionless.)
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // ---------------------------------------------------------------- config

    IERC20 public immutable chip; // named for IBankrollTable compat; = the table asset
    IRandomnessProvider public randomnessProvider;
    uint256 public minWager;
    uint256 public maxWager;
    /// @notice Betting window, measured from the round's first bet.
    uint64 public betWindow;
    /// @notice Decision window, measured from the shared deal reveal.
    uint64 public actWindow;
    /// @notice Cap on players per round (bounds refund/settle sweep work).
    uint256 public maxPlayers;

    bool internal immutable _dealerHitsSoft17;
    uint16 internal immutable _blackjackNum;
    uint16 internal immutable _blackjackDen;
    DoubleRule internal immutable _doubleRule;
    bool internal immutable _lateSurrender;

    /// @notice Window after which a stuck round can be cancelled for full refunds.
    uint64 public randomnessTimeout = 1 hours;

    uint64 internal constant MIN_TIMEOUT = 10 minutes;
    uint64 internal constant MAX_TIMEOUT = 7 days;
    uint64 internal constant MIN_WINDOW = 15 seconds;
    uint64 internal constant MAX_WINDOW = 1 hours;
    uint256 internal constant MAX_PLAYERS_BOUND = 512;

    /// @dev Upper bound keeping all payout arithmetic comfortably inside uint96.
    uint256 internal constant ABSOLUTE_MAX_WAGER = type(uint96).max / 4;

    // ---------------------------------------------------------------- state

    /// @notice Id of the newest round (0 = no round ever opened).
    uint256 public currentRoundId;
    mapping(uint256 => Round) internal _rounds;
    mapping(uint256 => address[]) internal _roundPlayers;
    mapping(uint256 => mapping(address => Bet)) internal _bets;
    /// @dev provider => requestId => roundId. Consumed (deleted) on fulfillment.
    mapping(address => mapping(uint256 => uint256)) public requestRound;

    /// @notice Chips owned by the house (excludes player escrow).
    uint256 public houseFunds;
    /// @notice Sum of active stakes held for players.
    uint256 public totalPlayerEscrow;
    /// @notice Sum of reserved worst-case house liabilities for unsettled bets.
    uint256 public totalReservedLiability;
    /// @notice Payouts whose token transfer failed, claimable via withdrawDeferred.
    mapping(address => uint256) public deferredPayouts;
    uint256 public totalDeferredPayouts;

    // ---------------------------------------------------------------- events

    event RoundOpened(uint256 indexed roundId, uint64 betDeadline);
    event BetPlaced(uint256 indexed roundId, address indexed player, uint256 wager);
    event RandomnessRequested(
        uint256 indexed roundId, address indexed provider, uint256 indexed requestId, RoundState phase
    );
    event RoundDealt(
        uint256 indexed roundId, uint8 playerCard1, uint8 playerCard2, uint8 dealerUpCard, uint64 actDeadline
    );
    event PlayerActed(
        uint256 indexed roundId, address indexed player, Action action, uint8 hitTarget
    );
    event ActionsLocked(uint256 indexed roundId);
    event DealerPlayed(
        uint256 indexed roundId, uint256 dealerCards, uint8 dealerCount, uint8 dealerTotal
    );
    event PlayerSettled(
        uint256 indexed roundId,
        address indexed player,
        Outcome outcome,
        uint256 payout,
        uint256 cards,
        uint8 cardCount
    );
    event RoundSettled(uint256 indexed roundId);
    event RoundCancelled(uint256 indexed roundId);
    event PlayerRefunded(uint256 indexed roundId, address indexed player, uint256 amount);
    event PayoutDeferred(address indexed player, uint256 amount);
    event DeferredWithdrawn(address indexed player, uint256 amount);
    event HouseFunded(address indexed from, uint256 amount);
    event HouseWithdrawn(address indexed to, uint256 amount);
    event WagerLimitsUpdated(uint256 minWager, uint256 maxWager);
    event WindowsUpdated(uint64 betWindow, uint64 actWindow);
    event MaxPlayersUpdated(uint256 maxPlayers);
    event RandomnessTimeoutUpdated(uint64 timeout);
    event RandomnessProviderUpdated(address indexed provider);

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error InvalidConfig();
    error InvalidRules();
    error WagerOutOfBounds(uint256 wager, uint256 minWager, uint256 maxWager);
    error BettingClosed(uint256 roundId);
    error RoundFull(uint256 roundId);
    error AlreadyBet(uint256 roundId);
    error InsufficientLiquidity(uint256 required, uint256 available);
    error NoSuchRound(uint256 roundId);
    error InvalidRoundState(uint256 roundId, RoundState state);
    error NoBet(uint256 roundId);
    error AlreadyActed(uint256 roundId);
    error ActingClosed(uint256 roundId);
    error ActionsStillOpen(uint256 roundId);
    error InvalidAction();
    error CannotDouble(uint256 roundId);
    error CannotSurrender(uint256 roundId);
    error BettingStillOpen(uint256 roundId);
    error NoPlayers(uint256 roundId);
    error UnknownRequest(uint256 requestId);
    error RequestMismatch(uint256 roundId, uint256 requestId);
    error TimeoutNotReached(uint256 roundId, uint256 cancellableAt);
    error NothingDeferred();
    error WithdrawExceedsAvailable(uint256 requested, uint256 available);

    // ---------------------------------------------------------------- setup

    constructor(
        IERC20 chip_,
        IRandomnessProvider provider_,
        Rules memory rules_,
        uint256 minWager_,
        uint256 maxWager_,
        uint64 betWindow_,
        uint64 actWindow_,
        uint256 maxPlayers_,
        address admin_
    ) {
        if (
            address(chip_) == address(0) || address(provider_) == address(0) || admin_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _validateLimits(minWager_, maxWager_);
        _validateWindows(betWindow_, actWindow_);
        if (maxPlayers_ == 0 || maxPlayers_ > MAX_PLAYERS_BOUND) revert InvalidConfig();
        // Payout in [1:1, 2:1] keeps the 2x-wager reservation an upper bound on
        // every possible house loss (see contract-level dev note).
        if (
            rules_.blackjackDen == 0 || rules_.blackjackNum < rules_.blackjackDen
                || uint256(rules_.blackjackNum) > 2 * uint256(rules_.blackjackDen)
        ) {
            revert InvalidRules();
        }
        chip = chip_;
        randomnessProvider = provider_;
        minWager = minWager_;
        maxWager = maxWager_;
        betWindow = betWindow_;
        actWindow = actWindow_;
        maxPlayers = maxPlayers_;
        _dealerHitsSoft17 = rules_.dealerHitsSoft17;
        _blackjackNum = rules_.blackjackNum;
        _blackjackDen = rules_.blackjackDen;
        _doubleRule = rules_.doubleRule;
        _lateSurrender = rules_.lateSurrender;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(TREASURY_ROLE, admin_);
    }

    /// @notice This table's immutable rule set.
    function rules() external view returns (Rules memory) {
        return Rules({
            dealerHitsSoft17: _dealerHitsSoft17,
            blackjackNum: _blackjackNum,
            blackjackDen: _blackjackDen,
            doubleRule: _doubleRule,
            lateSurrender: _lateSurrender
        });
    }

    // ---------------------------------------------------------------- player actions

    /// @notice Join the current round (opening a fresh one if none is accepting
    ///         bets): escrow the wager and reserve the house's worst-case liability.
    ///         The wager is locked before the deal beacon is even requested.
    function placeBet(uint256 wager) external nonReentrant whenNotPaused returns (uint256 roundId) {
        if (wager < minWager || wager > maxWager) {
            revert WagerOutOfBounds(wager, minWager, maxWager);
        }

        roundId = currentRoundId;
        Round storage r = _rounds[roundId];
        if (
            roundId == 0 || r.state == RoundState.DONE || r.state == RoundState.CANCELLED
        ) {
            // Open a fresh round; its betting window starts now.
            roundId = ++currentRoundId;
            r = _rounds[roundId];
            r.state = RoundState.BETTING;
            r.betDeadline = uint64(block.timestamp) + betWindow;
            emit RoundOpened(roundId, r.betDeadline);
        }
        // A BETTING round always has >= 1 player (its first bet opened it), so an
        // expired window simply closes the round to new joiners until lockDeal.
        if (r.state != RoundState.BETTING || block.timestamp >= r.betDeadline) {
            revert BettingClosed(roundId);
        }
        if (r.playerCount >= maxPlayers) revert RoundFull(roundId);
        Bet storage b = _bets[roundId][msg.sender];
        if (b.wager != 0) revert AlreadyBet(roundId);

        // Worst-case house payout across all future paths: 2x wager (see dev note).
        uint256 liability = wager * 2;
        uint256 available = availableLiquidity();
        if (liability > available) revert InsufficientLiquidity(liability, available);

        // Casts are safe: wager <= maxWager <= ABSOLUTE_MAX_WAGER = uint96.max / 4.
        // forge-lint: disable-next-line(unsafe-typecast)
        b.wager = uint96(wager);
        _roundPlayers[roundId].push(msg.sender);
        r.playerCount += 1;
        totalPlayerEscrow += wager;
        totalReservedLiability += liability;
        emit BetPlaced(roundId, msg.sender, wager);

        chip.safeTransferFrom(msg.sender, address(this), wager);
    }

    /// @notice Close betting and request the shared-deal beacon. Permissionless:
    ///         callable by anyone once the window has elapsed (the keeper and the
    ///         frontends race to call it).
    function lockDeal() external nonReentrant whenNotPaused {
        uint256 roundId = currentRoundId;
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.BETTING) revert InvalidRoundState(roundId, r.state);
        if (block.timestamp < r.betDeadline) revert BettingStillOpen(roundId);
        if (r.playerCount == 0) revert NoPlayers(roundId);
        r.state = RoundState.DEAL_PENDING;
        _requestRandomness(roundId, r);
    }

    /// @notice Commit your play for the round: STAND, HIT (to `hitTarget`), DOUBLE
    ///         (escrows a second wager, one card only) or SURRENDER (half back).
    ///         One commitment per player; no commitment by the deadline = stand.
    /// @dev Deliberately allowed while paused EXCEPT double (which adds escrow):
    ///      committing an action only winds the in-flight round down.
    function act(Action action, uint8 hitTarget) external nonReentrant {
        uint256 roundId = currentRoundId;
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.ACTING) revert InvalidRoundState(roundId, r.state);
        if (block.timestamp >= r.actDeadline) revert ActingClosed(roundId);
        Bet storage b = _bets[roundId][msg.sender];
        if (b.wager == 0) revert NoBet(roundId);
        if (b.action != Action.PENDING) revert AlreadyActed(roundId);

        if (action == Action.STAND) {
            // nothing extra
        } else if (action == Action.HIT) {
            (uint8 total,) = BlackjackLib.handValue(r.playerCards, 2);
            if (hitTarget <= total || hitTarget > BlackjackLib.BLACKJACK) revert InvalidAction();
            b.hitTarget = hitTarget;
        } else if (action == Action.DOUBLE) {
            if (paused() || !_doubleAllowed(r)) revert CannotDouble(roundId);
            totalPlayerEscrow += b.wager;
        } else if (action == Action.SURRENDER) {
            if (!_lateSurrender) revert CannotSurrender(roundId);
        } else {
            revert InvalidAction();
        }
        b.action = action;
        r.actedCount += 1;
        emit PlayerActed(roundId, msg.sender, action, hitTarget);
        if (action == Action.DOUBLE) {
            chip.safeTransferFrom(msg.sender, address(this), b.wager);
        }
    }

    /// @notice Close the decision window and request the draw beacon (beacon #2).
    ///         Callable early once EVERY player has committed, or by anyone after
    ///         the deadline. Beacon #2 is pinned only after this point, so no draw
    ///         card was knowable while anyone was still deciding.
    /// @dev Allowed while paused so in-flight rounds always wind down.
    function lockActions() external nonReentrant {
        uint256 roundId = currentRoundId;
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.ACTING) revert InvalidRoundState(roundId, r.state);
        if (block.timestamp < r.actDeadline && r.actedCount < r.playerCount) {
            revert ActionsStillOpen(roundId);
        }
        r.state = RoundState.DRAW_PENDING;
        emit ActionsLocked(roundId);
        _requestRandomness(roundId, r);
    }

    /// @notice Settle up to `max` players of the current round (permissionless,
    ///         paginated). The round is DONE once every player is settled.
    /// @dev Allowed while paused: settlement only winds risk down.
    function settle(uint256 max) external nonReentrant {
        uint256 roundId = currentRoundId;
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.SETTLING) revert InvalidRoundState(roundId, r.state);
        address[] storage players = _roundPlayers[roundId];
        uint256 end = r.cursor + max;
        if (end > players.length) end = players.length;
        for (uint256 i = r.cursor; i < end; ++i) {
            _settlePlayer(roundId, r, players[i]);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        r.cursor = uint32(end);
        if (end == players.length) {
            r.state = RoundState.DONE;
            emit RoundSettled(roundId);
        }
    }

    /// @notice Cancel a round stuck waiting on a beacon (or stuck unlocked) past the
    ///         timeout. Permissionless — refunds then flow via {refund}.
    function cancelRound(uint256 roundId) external nonReentrant {
        Round storage r = _rounds[roundId];
        uint256 cancellableAt;
        if (r.state == RoundState.DEAL_PENDING || r.state == RoundState.DRAW_PENDING) {
            cancellableAt = uint256(r.requestTimestamp) + randomnessTimeout;
        } else if (r.state == RoundState.BETTING && r.playerCount > 0) {
            // Nobody locked the deal for a whole timeout — free the escrows.
            cancellableAt = uint256(r.betDeadline) + randomnessTimeout;
        } else if (r.state == RoundState.ACTING) {
            // Nobody locked actions for a whole timeout past the deadline.
            cancellableAt = uint256(r.actDeadline) + randomnessTimeout;
        } else {
            revert InvalidRoundState(roundId, r.state);
        }
        if (block.timestamp < cancellableAt) revert TimeoutNotReached(roundId, cancellableAt);

        // Consume the pending request so a late beacon can no longer act on it.
        delete requestRound[r.pendingProvider][r.pendingRequestId];
        r.pendingRequestId = 0;
        r.pendingProvider = address(0);
        r.requestTimestamp = 0;
        r.cursor = 0;
        r.state = RoundState.CANCELLED;
        emit RoundCancelled(roundId);
    }

    /// @notice Refund up to `max` players of a cancelled round (permissionless,
    ///         paginated): full stake back, reservation released.
    function refund(uint256 roundId, uint256 max) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.CANCELLED) revert InvalidRoundState(roundId, r.state);
        address[] storage players = _roundPlayers[roundId];
        uint256 end = r.cursor + max;
        if (end > players.length) end = players.length;
        for (uint256 i = r.cursor; i < end; ++i) {
            address player = players[i];
            Bet storage b = _bets[roundId][player];
            if (b.settled) continue;
            b.settled = true;
            b.outcome = Outcome.CANCELLED_REFUND;
            uint256 stake =
                b.action == Action.DOUBLE ? uint256(b.wager) * 2 : uint256(b.wager);
            // forge-lint: disable-next-line(unsafe-typecast)
            b.payout = uint96(stake);
            totalPlayerEscrow -= stake;
            totalReservedLiability -= uint256(b.wager) * 2;
            emit PlayerRefunded(roundId, player, stake);
            _pay(player, stake);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        r.cursor = uint32(end);
    }

    /// @notice Withdraw payouts whose direct transfer failed at settlement time.
    function withdrawDeferred() external nonReentrant {
        uint256 amount = deferredPayouts[msg.sender];
        if (amount == 0) revert NothingDeferred();
        deferredPayouts[msg.sender] = 0;
        totalDeferredPayouts -= amount;
        emit DeferredWithdrawn(msg.sender, amount);
        chip.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------- randomness callback

    /// @inheritdoc IRandomnessConsumer
    /// @dev Only the provider bound at request time can fulfill, exactly once (CEI:
    ///      the request mapping entry is deleted before any effect).
    function fulfillRandomness(uint256 requestId, bytes32 seed) external nonReentrant {
        uint256 roundId = requestRound[msg.sender][requestId];
        if (roundId == 0) revert UnknownRequest(requestId);
        delete requestRound[msg.sender][requestId];

        Round storage r = _rounds[roundId];
        if (r.pendingRequestId != requestId || r.pendingProvider != msg.sender) {
            revert RequestMismatch(roundId, requestId);
        }
        r.pendingRequestId = 0;
        r.pendingProvider = address(0);
        r.requestTimestamp = 0;

        if (r.state == RoundState.DEAL_PENDING) {
            _handleDeal(roundId, r, seed);
        } else if (r.state == RoundState.DRAW_PENDING) {
            _handleDraw(roundId, r, seed);
        } else {
            revert InvalidRoundState(roundId, r.state);
        }
    }

    // ---------------------------------------------------------------- treasury

    /// @notice Deposit into the house bankroll. PERMISSIONLESS — normally called by
    ///         this table's vault; direct deposits are donations to the bankroll.
    function fundHouse(uint256 amount) external nonReentrant {
        houseFunds += amount;
        emit HouseFunded(msg.sender, amount);
        chip.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw UNRESERVED house funds only. Escrowed wagers, reserved
    ///         liabilities and deferred payouts can never be withdrawn by anyone.
    function withdrawHouseFunds(address to, uint256 amount)
        external
        nonReentrant
        onlyRole(TREASURY_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 available = availableLiquidity();
        if (amount > available) revert WithdrawExceedsAvailable(amount, available);
        houseFunds -= amount;
        emit HouseWithdrawn(to, amount);
        chip.safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------- admin

    function setWagerLimits(uint256 minWager_, uint256 maxWager_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validateLimits(minWager_, maxWager_);
        minWager = minWager_;
        maxWager = maxWager_;
        emit WagerLimitsUpdated(minWager_, maxWager_);
    }

    /// @notice Adjust the betting/decision windows for FUTURE rounds.
    function setWindows(uint64 betWindow_, uint64 actWindow_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validateWindows(betWindow_, actWindow_);
        betWindow = betWindow_;
        actWindow = actWindow_;
        emit WindowsUpdated(betWindow_, actWindow_);
    }

    function setMaxPlayers(uint256 maxPlayers_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxPlayers_ == 0 || maxPlayers_ > MAX_PLAYERS_BOUND) revert InvalidConfig();
        maxPlayers = maxPlayers_;
        emit MaxPlayersUpdated(maxPlayers_);
    }

    /// @notice Swap the randomness provider for FUTURE requests. In-flight requests
    ///         still fulfill through the provider bound at their request time.
    function setRandomnessProvider(IRandomnessProvider provider_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(provider_) == address(0)) revert ZeroAddress();
        randomnessProvider = provider_;
        emit RandomnessProviderUpdated(address(provider_));
    }

    function setRandomnessTimeout(uint64 timeout_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (timeout_ < MIN_TIMEOUT || timeout_ > MAX_TIMEOUT) revert InvalidConfig();
        randomnessTimeout = timeout_;
        emit RandomnessTimeoutUpdated(timeout_);
    }

    /// @notice Emergency stop for NEW risk only: blocks placeBet, lockDeal and
    ///         double. Acting, fulfillment, settlement, cancellation and refunds
    ///         stay open so in-flight rounds always wind down.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------- views

    /// @notice Total bankroll, reserved liabilities and available liquidity.
    function liquidity()
        external
        view
        returns (uint256 bankroll, uint256 reserved, uint256 available)
    {
        return (houseFunds, totalReservedLiability, availableLiquidity());
    }

    function availableLiquidity() public view returns (uint256) {
        return houseFunds - totalReservedLiability;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        Round memory r = _rounds[roundId];
        if (r.state == RoundState.NONE) revert NoSuchRound(roundId);
        return r;
    }

    function playersOf(uint256 roundId) external view returns (address[] memory) {
        return _roundPlayers[roundId];
    }

    function betOf(uint256 roundId, address player) external view returns (Bet memory) {
        return _bets[roundId][player];
    }

    /// @notice Convenience for UIs: shared player hand + dealer hand values.
    function roundHandValues(uint256 roundId)
        external
        view
        returns (uint8 playerTotal, bool playerSoft, uint8 dealerTotal, bool dealerSoft)
    {
        Round storage r = _rounds[roundId];
        if (r.state == RoundState.NONE) revert NoSuchRound(roundId);
        (playerTotal, playerSoft) = BlackjackLib.handValue(r.playerCards, 2);
        (dealerTotal, dealerSoft) = BlackjackLib.handValue(r.dealerCards, r.dealerCardCount);
    }

    // ---------------------------------------------------------------- internals

    function _validateLimits(uint256 minWager_, uint256 maxWager_) internal pure {
        if (minWager_ == 0 || minWager_ > maxWager_ || maxWager_ > ABSOLUTE_MAX_WAGER) {
            revert InvalidConfig();
        }
    }

    function _validateWindows(uint64 betWindow_, uint64 actWindow_) internal pure {
        if (
            betWindow_ < MIN_WINDOW || betWindow_ > MAX_WINDOW || actWindow_ < MIN_WINDOW
                || actWindow_ > MAX_WINDOW
        ) {
            revert InvalidConfig();
        }
    }

    function _doubleAllowed(Round storage r) internal view returns (bool) {
        if (_doubleRule == DoubleRule.ANY_TWO) return true;
        if (_doubleRule == DoubleRule.NO_DOUBLE) return false;
        (uint8 total, bool soft) = BlackjackLib.handValue(r.playerCards, 2);
        if (soft) return false; // 9-11/10-11 windows are hard-total rules
        if (_doubleRule == DoubleRule.NINE_TO_ELEVEN) return total >= 9 && total <= 11;
        return total >= 10 && total <= 11; // TEN_TO_ELEVEN
    }

    /// @dev Requests a seed from the current provider and binds (provider, requestId)
    ///      to the round. Reentrancy from the provider is blocked by nonReentrant on
    ///      all entry points.
    function _requestRandomness(uint256 roundId, Round storage r) internal {
        IRandomnessProvider provider = randomnessProvider;
        uint256 requestId = provider.requestRandomness(roundId);
        if (requestRound[address(provider)][requestId] != 0) {
            revert RequestMismatch(roundId, requestId);
        }
        requestRound[address(provider)][requestId] = roundId;
        r.pendingRequestId = requestId;
        r.pendingProvider = address(provider);
        r.requestTimestamp = uint64(block.timestamp);
        emit RandomnessRequested(roundId, address(provider), requestId, r.state);
    }

    /// @dev Beacon #1: reveal the shared two-card hand + dealer up-card. A shared
    ///      natural skips the decision phase entirely (nothing to decide) and goes
    ///      straight for the dealer's ENHC push-check draw.
    function _handleDeal(uint256 roundId, Round storage r, bytes32 seed) internal {
        uint8 p1 = BlackjackLib.drawCard(seed, 0);
        uint8 p2 = BlackjackLib.drawCard(seed, 1);
        uint8 d1 = BlackjackLib.drawCard(seed, 2);
        (uint256 pc, uint8 pn) = BlackjackLib.pushCard(0, 0, p1);
        (pc, pn) = BlackjackLib.pushCard(pc, pn, p2);
        r.playerCards = pc;
        (uint256 dc, uint8 dn) = BlackjackLib.pushCard(0, 0, d1);
        r.dealerCards = dc;
        r.dealerCardCount = dn;

        if (BlackjackLib.isNatural(pc, pn)) {
            r.state = RoundState.DRAW_PENDING;
            emit RoundDealt(roundId, p1, p2, d1, uint64(block.timestamp));
            emit ActionsLocked(roundId);
            _requestRandomness(roundId, r);
        } else {
            r.state = RoundState.ACTING;
            r.actDeadline = uint64(block.timestamp) + actWindow;
            emit RoundDealt(roundId, p1, p2, d1, r.actDeadline);
        }
    }

    /// @dev Beacon #2: store the draw seed and play the dealer's shared hand out of
    ///      its own derivation stream. Player hands derive lazily in the settle sweep.
    function _handleDraw(uint256 roundId, Round storage r, bytes32 seed) internal {
        r.drawSeed = seed;
        bytes32 dealerSeed = keccak256(abi.encodePacked(seed));
        (uint256 dc, uint8 dn) = BlackjackLib.dealerPlayRule(
            r.dealerCards, r.dealerCardCount, dealerSeed, _dealerHitsSoft17
        );
        r.dealerCards = dc;
        r.dealerCardCount = dn;
        (uint8 dTotal,) = BlackjackLib.handValue(dc, dn);
        emit DealerPlayed(roundId, dc, dn, dTotal);
        r.state = RoundState.SETTLING;
        r.cursor = 0;
    }

    /// @notice The derivation stream for one player's hit/double cards in a round.
    ///         Public so UIs can pre-compute hands the moment beacon #2 lands.
    function playerDrawSeed(bytes32 drawSeed, address player) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(drawSeed, player));
    }

    /// @dev Derive the player's final hand from their committed action, decide the
    ///      outcome against the shared dealer hand, release escrow + reservation and
    ///      pay (mirrors BlackjackTableV2._settle accounting exactly).
    function _settlePlayer(uint256 roundId, Round storage r, address player) internal {
        Bet storage b = _bets[roundId][player];
        if (b.settled) return;
        b.settled = true;

        uint256 cards = r.playerCards;
        uint8 count = 2;
        Action action = b.action;
        uint256 stake = b.wager;
        bytes32 pSeed = playerDrawSeed(r.drawSeed, player);

        if (action == Action.DOUBLE) {
            stake = uint256(b.wager) * 2;
            (cards, count) = BlackjackLib.pushCard(cards, count, BlackjackLib.drawCard(pSeed, 0));
        } else if (action == Action.HIT) {
            uint256 nonce;
            (uint8 total,) = BlackjackLib.handValue(cards, count);
            while (total <= BlackjackLib.BLACKJACK && total < b.hitTarget) {
                (cards, count) =
                    BlackjackLib.pushCard(cards, count, BlackjackLib.drawCard(pSeed, nonce));
                (total,) = BlackjackLib.handValue(cards, count);
                unchecked {
                    ++nonce;
                }
            }
        }
        b.cards = cards;
        b.cardCount = count;

        Outcome outcome = _decideOutcome(r, cards, count, action);

        uint256 payout;
        if (outcome == Outcome.PLAYER_BLACKJACK) {
            // Configured payout on the base wager (a doubled hand is never natural —
            // a shared natural skips the acting phase, so action is always PENDING).
            payout = uint256(b.wager)
                + (uint256(b.wager) * uint256(_blackjackNum)) / uint256(_blackjackDen);
        } else if (outcome == Outcome.PLAYER_WIN) {
            payout = stake * 2;
        } else if (outcome == Outcome.PUSH) {
            payout = stake;
        } else if (outcome == Outcome.SURRENDERED) {
            // Half the base wager back (surrender and double are mutually exclusive).
            payout = stake / 2;
        } // losing outcomes: payout = 0

        b.outcome = outcome;
        // Safe: payout <= 4 * wager <= 4 * ABSOLUTE_MAX_WAGER = uint96.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        b.payout = uint96(payout);

        totalPlayerEscrow -= stake;
        totalReservedLiability -= uint256(b.wager) * 2;
        if (payout >= stake) {
            houseFunds -= payout - stake;
        } else {
            houseFunds += stake - payout;
        }

        emit PlayerSettled(roundId, player, outcome, payout, cards, count);
        _pay(player, payout);
    }

    /// @dev ENHC outcome table, matching BlackjackTableV2 semantics:
    ///      - shared natural: pays blackjack unless the dealer also has one (push);
    ///      - surrender: half back regardless of the dealer hand — same
    ///        player-friendly surrender the v2 tables settle immediately;
    ///      - bust loses outright (label kept even when the dealer also has 21);
    ///      - dealer natural takes the whole (even doubled) stake.
    function _decideOutcome(Round storage r, uint256 cards, uint8 count, Action action)
        internal
        view
        returns (Outcome)
    {
        bool pNatural = BlackjackLib.isNatural(r.playerCards, 2);
        bool dNatural = BlackjackLib.isNatural(r.dealerCards, r.dealerCardCount);
        if (pNatural) return dNatural ? Outcome.PUSH : Outcome.PLAYER_BLACKJACK;
        if (action == Action.SURRENDER) return Outcome.SURRENDERED;

        (uint8 pTotal,) = BlackjackLib.handValue(cards, count);
        if (pTotal > BlackjackLib.BLACKJACK) return Outcome.PLAYER_BUST;
        if (dNatural) return Outcome.DEALER_BLACKJACK;
        (uint8 dTotal,) = BlackjackLib.handValue(r.dealerCards, r.dealerCardCount);
        if (dTotal > BlackjackLib.BLACKJACK) return Outcome.PLAYER_WIN;
        if (pTotal > dTotal) return Outcome.PLAYER_WIN;
        if (pTotal == dTotal) return Outcome.PUSH;
        return Outcome.DEALER_WIN;
    }

    /// @dev Pay a player without letting one failing transfer (e.g. a token-level
    ///      blacklist) brick the shared settle/refund sweep for everyone behind
    ///      them: on failure the amount becomes a deferred payout instead.
    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) =
            address(chip).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        deferredPayouts[to] += amount;
        totalDeferredPayouts += amount;
        emit PayoutDeferred(to, amount);
    }
}
