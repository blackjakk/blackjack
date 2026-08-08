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

/// @title BlackjackTableV3
/// @notice Parameterized European no-hole-card blackjack against a contract dealer,
///         played with a valueless test ERC-20. Play money only — NOT audited, NOT for
///         real funds. v2 extends the v1 engine with:
///         - a per-table immutable `Rules` set (soft-17 behavior, blackjack payout,
///           double window, late surrender);
///         - multiple concurrent games per player (actions take an explicit gameId);
///         - permissionless `fundHouse` (anyone may add bankroll; withdrawal of
///           UNRESERVED funds stays treasury-gated — the BankrollVault is that
///           treasury in practice);
///         - SPLIT: equal-value first two cards may be split into two hands for a
///           second equal wager. Hands play sequentially, each card from its own
///           committed seed. Split aces receive ONE card each; no re-splits, no
///           double-after-split, and a post-split 21 is NOT a natural — which
///           keeps the 2x-wager reservation the exact worst case (both split
///           hands winning 1:1 = 2x profit, same ceiling as a doubled win).
/// @dev Rules are validated so the v1 worst-case liability bound still holds: the
///      blackjack payout is capped at 2:1, so 2x wager reserved at bet time covers
///      every path (natural <= 2x profit; doubled 1:1 win = 2x profit). Surrender
///      returns half the wager from escrow and never touches house funds.
contract BlackjackTableV3 is IRandomnessConsumer, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using BlackjackLib for uint256;

    // ---------------------------------------------------------------- types

    enum GameState {
        NONE,
        AWAITING_INITIAL_RANDOMNESS,
        PLAYER_TURN,
        AWAITING_HIT_RANDOMNESS,
        AWAITING_DEALER_RANDOMNESS,
        SETTLED,
        CANCELLED
    }

    // Numeric values 0..7 match v1 so UIs/SDKs can share outcome tables.
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
        ANY_TWO, // double on any first two cards (v1 behavior)
        NINE_TO_ELEVEN, // hard 9-11 only
        TEN_TO_ELEVEN, // hard 10-11 only
        NO_DOUBLE
    }

    struct Rules {
        bool dealerHitsSoft17; // false = dealer stands on all 17s (S17)
        uint16 blackjackNum; // natural pays wager * num / den...
        uint16 blackjackDen; // ...e.g. 3/2 (classic) or 6/5; bounded [1:1, 2:1]
        DoubleRule doubleRule;
        bool lateSurrender; // forfeit half the wager on the first two cards
    }

    struct Game {
        address player;
        uint64 requestTimestamp; // when the pending randomness request was made
        GameState state;
        Outcome outcome;
        bool doubled;
        uint8 playerCount;
        uint8 dealerCount;
        uint96 wager; // base wager; stake = doubled ? 2*wager : wager
        uint96 reservedLiability; // house funds reserved for this game
        uint96 payout; // final amount paid to the player (incl. returned stake)
        uint256 playerCards; // packed, one byte per card (hand 1 when split)
        uint256 dealerCards; // packed
        uint256 pendingRequestId;
        address pendingProvider; // provider bound at request time
        bool split;
        bool splitAces;
        uint8 activeHand; // 0 = first (or only) hand, 1 = second split hand
        uint8 hand2Count;
        uint256 hand2Cards; // packed second hand (split only)
        Outcome outcome2; // second-hand outcome (split only; `outcome` = hand 1)
    }

    // ---------------------------------------------------------------- roles

    /// @notice May withdraw UNRESERVED house funds only. (Funding is permissionless.)
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // ---------------------------------------------------------------- config

    IERC20 public immutable chip;
    IRandomnessProvider public randomnessProvider;
    uint256 public minWager;
    uint256 public maxWager;
    /// @notice Cap on a single player's simultaneously open games.
    uint256 public maxConcurrentGames;

    bool internal immutable _dealerHitsSoft17;
    uint16 internal immutable _blackjackNum;
    uint16 internal immutable _blackjackDen;
    DoubleRule internal immutable _doubleRule;
    bool internal immutable _lateSurrender;

    /// @notice Window after which a game stuck waiting for randomness can be cancelled
    ///         for a full refund. Long by design — see docs/RANDOMNESS.md (free look).
    uint64 public randomnessTimeout = 1 hours;

    uint64 internal constant MIN_TIMEOUT = 10 minutes;
    uint64 internal constant MAX_TIMEOUT = 7 days;
    uint256 internal constant MAX_CONCURRENT_BOUND = 32;

    /// @dev Upper bound keeping all payout arithmetic comfortably inside uint96.
    uint256 internal constant ABSOLUTE_MAX_WAGER = type(uint96).max / 4;

    // ---------------------------------------------------------------- state

    uint256 public nextGameId = 1;
    mapping(uint256 => Game) internal _games;
    /// @dev Player's open game ids; index kept in _activeIndexPlus1 for O(1) removal.
    mapping(address => uint256[]) internal _activeGames;
    mapping(uint256 => uint256) internal _activeIndexPlus1;
    /// @dev provider => requestId => gameId. Consumed (deleted) on fulfillment.
    mapping(address => mapping(uint256 => uint256)) public requestGame;

    /// @notice Chips owned by the house (excludes player escrow).
    uint256 public houseFunds;
    /// @notice Sum of active stakes held for players.
    uint256 public totalPlayerEscrow;
    /// @notice Sum of reserved worst-case house liabilities for unsettled games.
    uint256 public totalReservedLiability;

    // ---------------------------------------------------------------- events

    event GameCreated(uint256 indexed gameId, address indexed player, uint256 wager);
    event RandomnessRequested(
        uint256 indexed gameId, address indexed provider, uint256 indexed requestId, GameState phase
    );
    event InitialCardsDealt(
        uint256 indexed gameId, uint8 playerCard1, uint8 playerCard2, uint8 dealerUpCard
    );
    event PlayerCardDealt(uint256 indexed gameId, uint8 card, uint8 newTotal);
    event PlayerStood(uint256 indexed gameId);
    event PlayerDoubled(uint256 indexed gameId, uint256 newStake);
    event PlayerSurrendered(uint256 indexed gameId, uint256 refund);
    event PlayerSplit(uint256 indexed gameId, uint256 newStake);
    event SplitSettled(uint256 indexed gameId, Outcome outcome1, Outcome outcome2, uint256 payout);
    event GameCancelled(uint256 indexed gameId, address indexed player, uint256 refund);
    event RandomnessTimeoutUpdated(uint64 timeout);
    event DealerPlayed(
        uint256 indexed gameId, uint256 dealerCards, uint8 dealerCount, uint8 dealerTotal
    );
    event GameSettled(
        uint256 indexed gameId, address indexed player, Outcome outcome, uint256 payout
    );
    event HouseFunded(address indexed from, uint256 amount);
    event HouseWithdrawn(address indexed to, uint256 amount);
    event WagerLimitsUpdated(uint256 minWager, uint256 maxWager);
    event MaxConcurrentGamesUpdated(uint256 maxConcurrentGames);
    event RandomnessProviderUpdated(address indexed provider);

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error InvalidConfig();
    error InvalidRules();
    error WagerOutOfBounds(uint256 wager, uint256 minWager, uint256 maxWager);
    error TooManyActiveGames(uint256 active, uint256 max);
    error InsufficientLiquidity(uint256 required, uint256 available);
    error NoSuchGame(uint256 gameId);
    error NotYourGame(uint256 gameId);
    error InvalidState(uint256 gameId, GameState state);
    error UnknownRequest(uint256 requestId);
    error RequestMismatch(uint256 gameId, uint256 requestId);
    error WithdrawExceedsAvailable(uint256 requested, uint256 available);
    error CannotDouble(uint256 gameId);
    error CannotSurrender(uint256 gameId);
    error CannotSplit(uint256 gameId);
    error TimeoutNotReached(uint256 gameId, uint256 cancellableAt);
    error NotAuthorizedToCancel(uint256 gameId);

    // ---------------------------------------------------------------- setup

    constructor(
        IERC20 chip_,
        IRandomnessProvider provider_,
        Rules memory rules_,
        uint256 minWager_,
        uint256 maxWager_,
        uint256 maxConcurrentGames_,
        address admin_
    ) {
        if (
            address(chip_) == address(0) || address(provider_) == address(0) || admin_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _validateLimits(minWager_, maxWager_);
        if (maxConcurrentGames_ == 0 || maxConcurrentGames_ > MAX_CONCURRENT_BOUND) {
            revert InvalidConfig();
        }
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
        maxConcurrentGames = maxConcurrentGames_;
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

    /// @notice Escrow `wager` chips, reserve the house's worst-case liability and request
    ///         the initial-deal seed. The wager is locked before any randomness for the
    ///         deal can exist.
    function placeBet(uint256 wager) external nonReentrant whenNotPaused returns (uint256 gameId) {
        if (wager < minWager || wager > maxWager) {
            revert WagerOutOfBounds(wager, minWager, maxWager);
        }
        uint256 open = _activeGames[msg.sender].length;
        if (open >= maxConcurrentGames) revert TooManyActiveGames(open, maxConcurrentGames);

        // Worst-case house payout across all future paths: 2x wager (see dev note).
        uint256 liability = wager * 2;
        uint256 available = availableLiquidity();
        if (liability > available) revert InsufficientLiquidity(liability, available);

        gameId = nextGameId++;
        Game storage g = _games[gameId];
        g.player = msg.sender;
        // Casts are safe: wager <= maxWager <= ABSOLUTE_MAX_WAGER = uint96.max / 4.
        // forge-lint: disable-next-line(unsafe-typecast)
        g.wager = uint96(wager);
        // forge-lint: disable-next-line(unsafe-typecast)
        g.reservedLiability = uint96(liability);
        g.state = GameState.AWAITING_INITIAL_RANDOMNESS;
        _trackGame(msg.sender, gameId);
        totalPlayerEscrow += wager;
        totalReservedLiability += liability;
        emit GameCreated(gameId, msg.sender, wager);

        chip.safeTransferFrom(msg.sender, address(this), wager);
        _requestRandomness(gameId, g);
    }

    /// @notice Take one more card on `gameId`. Locks the decision, then requests a
    ///         fresh seed.
    function hit(uint256 gameId) external nonReentrant whenNotPaused {
        Game storage g = _ownedGame(gameId);
        if (g.state != GameState.PLAYER_TURN) revert InvalidState(gameId, g.state);
        g.state = GameState.AWAITING_HIT_RANDOMNESS;
        _requestRandomness(gameId, g);
    }

    /// @notice Stop taking cards on `gameId`; the dealer plays out from a fresh seed.
    /// @dev Deliberately allowed while paused: standing adds no new risk and lets
    ///      in-flight games wind down.
    function stand(uint256 gameId) external nonReentrant {
        Game storage g = _ownedGame(gameId);
        if (g.state != GameState.PLAYER_TURN) revert InvalidState(gameId, g.state);
        emit PlayerStood(gameId);
        if (g.split) {
            _finishActiveHand(gameId, g);
        } else {
            _startDealerPhase(gameId, g);
        }
    }

    /// @notice Double the stake on the initial two cards (subject to this table's
    ///         double rule): one card is dealt, then the hand auto-stands. The 2x-wager
    ///         liability reserved at bet time already covers the doubled worst case.
    function double(uint256 gameId) external nonReentrant whenNotPaused {
        Game storage g = _ownedGame(gameId);
        if (g.state != GameState.PLAYER_TURN) revert InvalidState(gameId, g.state);
        if (g.playerCount != 2 || g.doubled || g.split || !_doubleAllowed(g)) {
            revert CannotDouble(gameId);
        }

        g.doubled = true;
        totalPlayerEscrow += g.wager;
        g.state = GameState.AWAITING_HIT_RANDOMNESS;
        emit PlayerDoubled(gameId, uint256(g.wager) * 2);

        chip.safeTransferFrom(msg.sender, address(this), g.wager);
        _requestRandomness(gameId, g);
    }

    /// @notice Late surrender (if this table allows it): give up the initial two-card
    ///         hand and take half the wager back. Settles immediately — the dealer
    ///         never draws, so this is slightly player-friendlier than live ENHC
    ///         surrender (documented in docs/RULES.md).
    /// @dev Allowed while paused: surrendering only reduces open risk.
    function surrender(uint256 gameId) external nonReentrant {
        Game storage g = _ownedGame(gameId);
        if (g.state != GameState.PLAYER_TURN) revert InvalidState(gameId, g.state);
        if (!_lateSurrender || g.playerCount != 2 || g.doubled || g.split) {
            revert CannotSurrender(gameId);
        }
        emit PlayerSurrendered(gameId, uint256(g.wager) / 2);
        _settle(gameId, g, Outcome.SURRENDERED);
    }

    /// @notice Split an equal-value pair into two hands for a second equal wager.
    ///         Hand 1 is played first; each hand's cards come from fresh seeds.
    function split(uint256 gameId) external nonReentrant whenNotPaused {
        Game storage g = _ownedGame(gameId);
        if (g.state != GameState.PLAYER_TURN) revert InvalidState(gameId, g.state);
        uint8 c0 = uint8(g.playerCards & 0xff);
        uint8 c1 = uint8((g.playerCards >> 8) & 0xff);
        if (g.playerCount != 2 || g.doubled || g.split || _cardVal(c0) != _cardVal(c1)) {
            revert CannotSplit(gameId);
        }

        g.split = true;
        g.splitAces = (c0 % 13 == 0); // equal value 1 implies both are aces
        g.playerCards = uint256(c0);
        g.playerCount = 1;
        g.hand2Cards = uint256(c1);
        g.hand2Count = 1;
        g.activeHand = 0;
        totalPlayerEscrow += g.wager;
        g.state = GameState.AWAITING_HIT_RANDOMNESS; // hand 1's second card
        emit PlayerSplit(gameId, uint256(g.wager) * 2);

        chip.safeTransferFrom(msg.sender, address(this), g.wager);
        _requestRandomness(gameId, g);
    }

    /// @notice Cancel a game stuck waiting for randomness past the timeout and refund
    ///         the full stake. Callable by the game's player or an admin only.
    /// @dev Free-look caveat documented in docs/RANDOMNESS.md. Allowed while paused so
    ///      a pause can never trap player funds.
    function cancelTimedOutGame(uint256 gameId) external nonReentrant {
        Game storage g = _games[gameId];
        if (g.player == address(0)) revert NoSuchGame(gameId);
        if (msg.sender != g.player && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotAuthorizedToCancel(gameId);
        }
        if (
            g.state != GameState.AWAITING_INITIAL_RANDOMNESS
                && g.state != GameState.AWAITING_HIT_RANDOMNESS
                && g.state != GameState.AWAITING_DEALER_RANDOMNESS
        ) {
            revert InvalidState(gameId, g.state);
        }
        uint256 cancellableAt = uint256(g.requestTimestamp) + randomnessTimeout;
        if (block.timestamp < cancellableAt) revert TimeoutNotReached(gameId, cancellableAt);

        // Consume the pending request so a late beacon can no longer act on this game.
        delete requestGame[g.pendingProvider][g.pendingRequestId];
        g.pendingRequestId = 0;
        g.pendingProvider = address(0);
        g.requestTimestamp = 0;

        uint256 stake = (g.doubled || g.split) ? uint256(g.wager) * 2 : g.wager;
        g.state = GameState.CANCELLED;
        g.outcome = Outcome.CANCELLED_REFUND;
        // Safe: stake <= 2 * ABSOLUTE_MAX_WAGER < uint96.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        g.payout = uint96(stake);
        _untrackGame(g.player, gameId);
        totalPlayerEscrow -= stake;
        totalReservedLiability -= g.reservedLiability;

        emit GameCancelled(gameId, g.player, stake);
        chip.safeTransfer(g.player, stake);
    }

    // ---------------------------------------------------------------- randomness callback

    /// @inheritdoc IRandomnessConsumer
    /// @dev Only the provider bound at request time can fulfill, exactly once: the
    ///      request mapping entry is deleted before any effect (CEI).
    function fulfillRandomness(uint256 requestId, bytes32 seed) external nonReentrant {
        uint256 gameId = requestGame[msg.sender][requestId];
        if (gameId == 0) revert UnknownRequest(requestId);
        delete requestGame[msg.sender][requestId];

        Game storage g = _games[gameId];
        // Defense in depth: the mapping is authoritative, but verify the game agrees.
        if (g.pendingRequestId != requestId || g.pendingProvider != msg.sender) {
            revert RequestMismatch(gameId, requestId);
        }
        g.pendingRequestId = 0;
        g.pendingProvider = address(0);
        g.requestTimestamp = 0;

        if (g.state == GameState.AWAITING_INITIAL_RANDOMNESS) {
            _handleInitialDeal(gameId, g, seed);
        } else if (g.state == GameState.AWAITING_HIT_RANDOMNESS) {
            _handleHitCard(gameId, g, seed);
        } else if (g.state == GameState.AWAITING_DEALER_RANDOMNESS) {
            _handleDealerPlay(gameId, g, seed);
        } else {
            revert InvalidState(gameId, g.state);
        }
    }

    // ---------------------------------------------------------------- treasury

    /// @notice Deposit chips into the house bankroll. PERMISSIONLESS: anyone may add
    ///         liquidity. There is no withdrawal right attached — deposits are
    ///         donations to the bankroll until an LP-share vault exists (roadmap);
    ///         only TREASURY_ROLE can withdraw unreserved funds.
    function fundHouse(uint256 amount) external nonReentrant {
        houseFunds += amount;
        emit HouseFunded(msg.sender, amount);
        chip.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw UNRESERVED house funds only. Escrowed wagers and reserved
    ///         liabilities for active games can never be withdrawn by anyone.
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

    function setMaxConcurrentGames(uint256 maxConcurrentGames_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (maxConcurrentGames_ == 0 || maxConcurrentGames_ > MAX_CONCURRENT_BOUND) {
            revert InvalidConfig();
        }
        maxConcurrentGames = maxConcurrentGames_;
        emit MaxConcurrentGamesUpdated(maxConcurrentGames_);
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

    /// @notice Emergency stop for NEW risk only: blocks placeBet, hit and double.
    ///         Fulfillment, stand, surrender, settlement and timeout cancellation stay
    ///         open so in-flight games always wind down.
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

    function getGame(uint256 gameId) external view returns (Game memory) {
        Game memory g = _games[gameId];
        if (g.player == address(0)) revert NoSuchGame(gameId);
        return g;
    }

    /// @notice All of `player`'s currently open game ids (unordered).
    function activeGamesOf(address player) external view returns (uint256[] memory) {
        return _activeGames[player];
    }

    function activeGameCountOf(address player) external view returns (uint256) {
        return _activeGames[player].length;
    }

    /// @notice Convenience view for UIs/SDKs: current hand values of a game.
    function handValues(uint256 gameId)
        external
        view
        returns (uint8 playerTotal, bool playerSoft, uint8 dealerTotal, bool dealerSoft)
    {
        Game storage g = _games[gameId];
        if (g.player == address(0)) revert NoSuchGame(gameId);
        (playerTotal, playerSoft) = BlackjackLib.handValue(g.playerCards, g.playerCount);
        (dealerTotal, dealerSoft) = BlackjackLib.handValue(g.dealerCards, g.dealerCount);
    }

    // ---------------------------------------------------------------- internals

    function _ownedGame(uint256 gameId) internal view returns (Game storage g) {
        g = _games[gameId];
        if (g.player == address(0)) revert NoSuchGame(gameId);
        if (g.player != msg.sender) revert NotYourGame(gameId);
    }

    function _trackGame(address player, uint256 gameId) internal {
        _activeGames[player].push(gameId);
        _activeIndexPlus1[gameId] = _activeGames[player].length;
    }

    /// @dev Swap-and-pop removal keeping _activeIndexPlus1 consistent.
    function _untrackGame(address player, uint256 gameId) internal {
        uint256[] storage list = _activeGames[player];
        uint256 idxPlus1 = _activeIndexPlus1[gameId];
        // Invariant: every live game was tracked at creation.
        uint256 lastIdx = list.length - 1;
        uint256 idx = idxPlus1 - 1;
        if (idx != lastIdx) {
            uint256 moved = list[lastIdx];
            list[idx] = moved;
            _activeIndexPlus1[moved] = idxPlus1;
        }
        list.pop();
        delete _activeIndexPlus1[gameId];
    }

    function _doubleAllowed(Game storage g) internal view returns (bool) {
        if (_doubleRule == DoubleRule.ANY_TWO) return true;
        if (_doubleRule == DoubleRule.NO_DOUBLE) return false;
        (uint8 total, bool soft) = BlackjackLib.handValue(g.playerCards, g.playerCount);
        if (soft) return false; // 9-11/10-11 windows are hard-total rules
        if (_doubleRule == DoubleRule.NINE_TO_ELEVEN) return total >= 9 && total <= 11;
        return total >= 10 && total <= 11; // TEN_TO_ELEVEN
    }

    function _validateLimits(uint256 minWager_, uint256 maxWager_) internal pure {
        if (minWager_ == 0 || minWager_ > maxWager_ || maxWager_ > ABSOLUTE_MAX_WAGER) {
            revert InvalidConfig();
        }
    }

    /// @dev Requests a seed from the current provider and binds (provider, requestId)
    ///      to the game. Reentrancy from the provider is blocked by nonReentrant on
    ///      all entry points.
    function _requestRandomness(uint256 gameId, Game storage g) internal {
        IRandomnessProvider provider = randomnessProvider;
        uint256 requestId = provider.requestRandomness(gameId);
        if (requestGame[address(provider)][requestId] != 0) {
            revert RequestMismatch(gameId, requestId);
        }
        requestGame[address(provider)][requestId] = gameId;
        g.pendingRequestId = requestId;
        g.pendingProvider = address(provider);
        g.requestTimestamp = uint64(block.timestamp);
        emit RandomnessRequested(gameId, address(provider), requestId, g.state);
    }

    function _startDealerPhase(uint256 gameId, Game storage g) internal {
        g.state = GameState.AWAITING_DEALER_RANDOMNESS;
        _requestRandomness(gameId, g);
    }

    function _handleInitialDeal(uint256 gameId, Game storage g, bytes32 seed) internal {
        uint8 p1 = BlackjackLib.drawCard(seed, 0);
        uint8 p2 = BlackjackLib.drawCard(seed, 1);
        uint8 d1 = BlackjackLib.drawCard(seed, 2);
        (uint256 pc, uint8 pn) = BlackjackLib.pushCard(0, 0, p1);
        (pc, pn) = BlackjackLib.pushCard(pc, pn, p2);
        g.playerCards = pc;
        g.playerCount = pn;
        (uint256 dc, uint8 dn) = BlackjackLib.pushCard(0, 0, d1);
        g.dealerCards = dc;
        g.dealerCount = dn;
        emit InitialCardsDealt(gameId, p1, p2, d1);

        if (BlackjackLib.isNatural(pc, pn)) {
            // Natural auto-stands: the dealer still draws (ENHC) to check for a push.
            _startDealerPhase(gameId, g);
        } else {
            g.state = GameState.PLAYER_TURN;
        }
    }

    function _handleHitCard(uint256 gameId, Game storage g, bytes32 seed) internal {
        uint8 card = BlackjackLib.drawCard(seed, 0);
        uint8 total;
        uint8 count;
        if (!g.split || g.activeHand == 0) {
            (uint256 pc, uint8 pn) = BlackjackLib.pushCard(g.playerCards, g.playerCount, card);
            g.playerCards = pc;
            g.playerCount = pn;
            (total,) = BlackjackLib.handValue(pc, pn);
            count = pn;
        } else {
            (uint256 hc, uint8 hn) = BlackjackLib.pushCard(g.hand2Cards, g.hand2Count, card);
            g.hand2Cards = hc;
            g.hand2Count = hn;
            (total,) = BlackjackLib.handValue(hc, hn);
            count = hn;
        }
        emit PlayerCardDealt(gameId, card, total);

        if (g.split) {
            // Split aces take exactly one card; bust or 21 also end the hand.
            if (g.splitAces || total >= BlackjackLib.BLACKJACK) {
                _finishActiveHand(gameId, g);
            } else {
                g.state = GameState.PLAYER_TURN;
            }
            return;
        }

        if (total > BlackjackLib.BLACKJACK) {
            // ENHC: a busted player loses immediately; the dealer never draws.
            _settle(gameId, g, Outcome.PLAYER_BUST);
        } else if (g.doubled || total == BlackjackLib.BLACKJACK) {
            // Double-down takes exactly one card; 21 auto-stands.
            _startDealerPhase(gameId, g);
        } else {
            g.state = GameState.PLAYER_TURN;
        }
    }

    /// @dev Sequential split play: hand 1 done -> deal hand 2's second card;
    ///      hand 2 done -> dealer plays (unless both hands busted — ENHC).
    function _finishActiveHand(uint256 gameId, Game storage g) internal {
        if (g.activeHand == 0) {
            g.activeHand = 1;
            g.state = GameState.AWAITING_HIT_RANDOMNESS;
            _requestRandomness(gameId, g);
            return;
        }
        if (
            BlackjackLib.isBust(g.playerCards, g.playerCount)
                && BlackjackLib.isBust(g.hand2Cards, g.hand2Count)
        ) {
            _settleSplit(gameId, g, 0);
            return;
        }
        _startDealerPhase(gameId, g);
    }

    function _cardVal(uint8 card) internal pure returns (uint8) {
        uint8 rank = card % 13;
        if (rank == 0) return 1;
        if (rank >= 9) return 10;
        return rank + 1;
    }

    function _handleDealerPlay(uint256 gameId, Game storage g, bytes32 seed) internal {
        (uint256 dc, uint8 dn) =
            BlackjackLib.dealerPlayRule(g.dealerCards, g.dealerCount, seed, _dealerHitsSoft17);
        g.dealerCards = dc;
        g.dealerCount = dn;
        (uint8 dTotal,) = BlackjackLib.handValue(dc, dn);
        emit DealerPlayed(gameId, dc, dn, dTotal);
        if (g.split) {
            _settleSplit(gameId, g, dTotal);
        } else {
            _settle(gameId, g, _compareHands(g, dTotal));
        }
    }

    /// @dev Post-split hands are never naturals; ENHC dealer natural takes both.
    function _compareSplitHand(uint256 cards, uint8 count, uint8 dealerTotal, bool dNatural)
        internal
        pure
        returns (Outcome)
    {
        (uint8 total,) = BlackjackLib.handValue(cards, count);
        if (total > BlackjackLib.BLACKJACK) return Outcome.PLAYER_BUST;
        if (dNatural) return Outcome.DEALER_BLACKJACK;
        if (dealerTotal > BlackjackLib.BLACKJACK) return Outcome.PLAYER_WIN;
        if (total > dealerTotal) return Outcome.PLAYER_WIN;
        if (total == dealerTotal) return Outcome.PUSH;
        return Outcome.DEALER_WIN;
    }

    /// @dev Split settlement: each hand carries `wager`; win pays 1:1, push
    ///      returns the stake. dealerTotal == 0 means both hands busted (the
    ///      dealer never drew).
    function _settleSplit(uint256 gameId, Game storage g, uint8 dealerTotal) internal {
        bool dNatural = BlackjackLib.isNatural(g.dealerCards, g.dealerCount);
        Outcome o1 = _compareSplitHand(g.playerCards, g.playerCount, dealerTotal, dNatural);
        Outcome o2 = _compareSplitHand(g.hand2Cards, g.hand2Count, dealerTotal, dNatural);

        uint256 w = g.wager;
        uint256 payout = _splitHandPayout(o1, w) + _splitHandPayout(o2, w);
        uint256 stake = w * 2;

        g.state = GameState.SETTLED;
        g.outcome = o1;
        g.outcome2 = o2;
        // Safe: payout <= 4 * wager <= 4 * ABSOLUTE_MAX_WAGER = uint96.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        g.payout = uint96(payout);
        _untrackGame(g.player, gameId);

        totalPlayerEscrow -= stake;
        totalReservedLiability -= g.reservedLiability;
        if (payout >= stake) {
            houseFunds -= payout - stake;
        } else {
            houseFunds += stake - payout;
        }

        emit SplitSettled(gameId, o1, o2, payout);
        emit GameSettled(gameId, g.player, o1, payout);
        if (payout > 0) chip.safeTransfer(g.player, payout);
    }

    function _splitHandPayout(Outcome o, uint256 wager) internal pure returns (uint256) {
        if (o == Outcome.PLAYER_WIN) return wager * 2;
        if (o == Outcome.PUSH) return wager;
        return 0;
    }

    function _compareHands(Game storage g, uint8 dealerTotal) internal view returns (Outcome) {
        (uint8 pTotal,) = BlackjackLib.handValue(g.playerCards, g.playerCount);
        bool pNatural = BlackjackLib.isNatural(g.playerCards, g.playerCount);
        bool dNatural = BlackjackLib.isNatural(g.dealerCards, g.dealerCount);

        if (pNatural && dNatural) return Outcome.PUSH;
        if (pNatural) return Outcome.PLAYER_BLACKJACK;
        if (dNatural) return Outcome.DEALER_BLACKJACK; // ENHC: takes the whole stake
        if (dealerTotal > BlackjackLib.BLACKJACK) return Outcome.PLAYER_WIN;
        if (pTotal > dealerTotal) return Outcome.PLAYER_WIN;
        if (pTotal == dealerTotal) return Outcome.PUSH;
        return Outcome.DEALER_WIN;
    }

    /// @dev Single settlement sink: releases escrow + reservation, updates house funds,
    ///      records the outcome and pays the player last (CEI). Reachable exactly once
    ///      per game.
    function _settle(uint256 gameId, Game storage g, Outcome outcome) internal {
        uint256 stake = g.doubled ? uint256(g.wager) * 2 : g.wager;
        uint256 payout;
        if (outcome == Outcome.PLAYER_BLACKJACK) {
            // Table-configured payout on the base wager, rounded down (a doubled hand
            // can never be a natural).
            payout = uint256(g.wager) + (uint256(g.wager) * uint256(_blackjackNum))
                / uint256(_blackjackDen);
        } else if (outcome == Outcome.PLAYER_WIN) {
            payout = stake * 2;
        } else if (outcome == Outcome.PUSH) {
            payout = stake;
        } else if (outcome == Outcome.SURRENDERED) {
            // Half the wager back, rounded down; the house keeps the rest of the
            // escrowed stake. Surrender is only reachable undoubled.
            payout = stake / 2;
        } // losing outcomes: payout = 0

        g.state = GameState.SETTLED;
        g.outcome = outcome;
        // Safe: payout <= 4 * wager <= 4 * ABSOLUTE_MAX_WAGER = uint96.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        g.payout = uint96(payout);
        _untrackGame(g.player, gameId);

        totalPlayerEscrow -= stake;
        totalReservedLiability -= g.reservedLiability;
        if (payout >= stake) {
            houseFunds -= payout - stake;
        } else {
            houseFunds += stake - payout;
        }

        emit GameSettled(gameId, g.player, outcome, payout);
        if (payout > 0) chip.safeTransfer(g.player, payout);
    }
}
