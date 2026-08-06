// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRandomnessProvider} from "./interfaces/IRandomnessProvider.sol";
import {IRandomnessConsumer} from "./interfaces/IRandomnessConsumer.sol";
import {BlackjackLib} from "./lib/BlackjackLib.sol";

/// @title BlackjackTable
/// @notice Single-player European no-hole-card blackjack against a contract-controlled
///         dealer, played with a valueless test ERC-20. Play money only — NOT audited,
///         NOT for real funds. Rules: docs/RULES.md. State machine: docs/STATE_MACHINE.md.
/// @dev Every card-revealing phase consumes a fresh seed committed after the player's
///      latest irreversible action (see docs/RANDOMNESS.md). House worst-case liability
///      (2x wager: covers both a 3:2 natural and a doubled win) is reserved at bet time
///      so settlement can never exceed available funds.
contract BlackjackTable is IRandomnessConsumer, AccessControl, ReentrancyGuard {
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

    enum Outcome {
        NONE,
        PLAYER_BLACKJACK,
        PLAYER_WIN,
        PUSH,
        DEALER_WIN,
        PLAYER_BUST,
        DEALER_BLACKJACK,
        CANCELLED_REFUND
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
        uint256 playerCards; // packed, one byte per card
        uint256 dealerCards; // packed
        uint256 pendingRequestId;
        address pendingProvider; // provider bound at request time
    }

    // ---------------------------------------------------------------- roles

    /// @notice May fund the house and withdraw UNRESERVED house funds only.
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // ---------------------------------------------------------------- config

    IERC20 public immutable chip;
    IRandomnessProvider public randomnessProvider;
    uint256 public minWager;
    uint256 public maxWager;

    /// @dev Upper bound keeping all payout arithmetic comfortably inside uint96.
    uint256 internal constant ABSOLUTE_MAX_WAGER = type(uint96).max / 4;

    // ---------------------------------------------------------------- state

    uint256 public nextGameId = 1;
    mapping(uint256 => Game) internal _games;
    /// @notice gameId of the caller's active game (0 = none). One active game per player.
    mapping(address => uint256) public activeGameOf;
    /// @dev provider => requestId => gameId. Consumed (deleted) on fulfillment.
    mapping(address => mapping(uint256 => uint256)) public requestGame;

    /// @notice Chips owned by the house (excludes player escrow).
    uint256 public houseFunds;
    /// @notice Sum of active wagers held for players.
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
    event DealerPlayed(
        uint256 indexed gameId, uint256 dealerCards, uint8 dealerCount, uint8 dealerTotal
    );
    event GameSettled(
        uint256 indexed gameId, address indexed player, Outcome outcome, uint256 payout
    );
    event HouseFunded(address indexed from, uint256 amount);
    event HouseWithdrawn(address indexed to, uint256 amount);
    event WagerLimitsUpdated(uint256 minWager, uint256 maxWager);
    event RandomnessProviderUpdated(address indexed provider);

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    error InvalidConfig();
    error WagerOutOfBounds(uint256 wager, uint256 minWager, uint256 maxWager);
    error ActiveGameExists(uint256 gameId);
    error InsufficientLiquidity(uint256 required, uint256 available);
    error NoSuchGame(uint256 gameId);
    error NotYourGame(uint256 gameId);
    error InvalidState(uint256 gameId, GameState state);
    error UnknownRequest(uint256 requestId);
    error RequestMismatch(uint256 gameId, uint256 requestId);
    error WithdrawExceedsAvailable(uint256 requested, uint256 available);

    // ---------------------------------------------------------------- setup

    constructor(
        IERC20 chip_,
        IRandomnessProvider provider_,
        uint256 minWager_,
        uint256 maxWager_,
        address admin_
    ) {
        if (
            address(chip_) == address(0) || address(provider_) == address(0) || admin_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _validateLimits(minWager_, maxWager_);
        chip = chip_;
        randomnessProvider = provider_;
        minWager = minWager_;
        maxWager = maxWager_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(TREASURY_ROLE, admin_);
    }

    // ---------------------------------------------------------------- player actions

    /// @notice Escrow `wager` chips, reserve the house's worst-case liability and request
    ///         the initial-deal seed. The wager is locked before any randomness for the
    ///         deal can exist.
    function placeBet(uint256 wager) external nonReentrant returns (uint256 gameId) {
        if (wager < minWager || wager > maxWager) {
            revert WagerOutOfBounds(wager, minWager, maxWager);
        }
        uint256 existing = activeGameOf[msg.sender];
        if (existing != 0) revert ActiveGameExists(existing);

        // Worst-case house payout across all future paths: 2x wager
        // (3:2 natural = 1.5x; doubled 1:1 win = 2x). Reserved up front so a
        // double-down can never fail for liquidity reasons.
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
        activeGameOf[msg.sender] = gameId;
        totalPlayerEscrow += wager;
        totalReservedLiability += liability;
        emit GameCreated(gameId, msg.sender, wager);

        chip.safeTransferFrom(msg.sender, address(this), wager);
        _requestRandomness(gameId, g);
    }

    /// @notice Take one more card. Locks the decision, then requests a fresh seed.
    function hit() external nonReentrant {
        (uint256 gameId, Game storage g) = _activeGame(msg.sender);
        if (g.state != GameState.PLAYER_TURN) revert InvalidState(gameId, g.state);
        g.state = GameState.AWAITING_HIT_RANDOMNESS;
        _requestRandomness(gameId, g);
    }

    /// @notice Stop taking cards; the dealer plays out from a fresh seed.
    function stand() external nonReentrant {
        (uint256 gameId, Game storage g) = _activeGame(msg.sender);
        if (g.state != GameState.PLAYER_TURN) revert InvalidState(gameId, g.state);
        emit PlayerStood(gameId);
        _startDealerPhase(gameId, g);
    }

    // ---------------------------------------------------------------- randomness callback

    /// @inheritdoc IRandomnessConsumer
    /// @dev Only the provider bound at request time can fulfill, exactly once: the
    ///      request mapping entry is deleted before any effect (CEI), so duplicate or
    ///      stale callbacks revert with UnknownRequest.
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

    /// @notice Deposit chips into the house bankroll.
    function fundHouse(uint256 amount) external nonReentrant onlyRole(TREASURY_ROLE) {
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

    function _activeGame(address player) internal view returns (uint256 gameId, Game storage g) {
        gameId = activeGameOf[player];
        if (gameId == 0) revert NoSuchGame(0);
        g = _games[gameId];
        if (g.player != player) revert NotYourGame(gameId);
    }

    function _validateLimits(uint256 minWager_, uint256 maxWager_) internal pure {
        if (minWager_ == 0 || minWager_ > maxWager_ || maxWager_ > ABSOLUTE_MAX_WAGER) {
            revert InvalidConfig();
        }
    }

    /// @dev Requests a seed from the current provider and binds (provider, requestId)
    ///      to the game. The provider is an admin-configured, semi-trusted contract;
    ///      reentrancy from it is blocked by nonReentrant on all entry points.
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
        (uint256 pc, uint8 pn) = BlackjackLib.pushCard(g.playerCards, g.playerCount, card);
        g.playerCards = pc;
        g.playerCount = pn;
        (uint8 total,) = BlackjackLib.handValue(pc, pn);
        emit PlayerCardDealt(gameId, card, total);

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

    function _handleDealerPlay(uint256 gameId, Game storage g, bytes32 seed) internal {
        (uint256 dc, uint8 dn) = BlackjackLib.dealerPlay(g.dealerCards, g.dealerCount, seed);
        g.dealerCards = dc;
        g.dealerCount = dn;
        (uint8 dTotal,) = BlackjackLib.handValue(dc, dn);
        emit DealerPlayed(gameId, dc, dn, dTotal);
        _settle(gameId, g, _compareHands(g, dTotal));
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
    ///      per game — every path into it starts from a live, non-terminal state.
    function _settle(uint256 gameId, Game storage g, Outcome outcome) internal {
        uint256 stake = g.doubled ? uint256(g.wager) * 2 : g.wager;
        uint256 payout;
        if (outcome == Outcome.PLAYER_BLACKJACK) {
            // 3:2 on the base wager (a doubled hand can never be a natural).
            payout = uint256(g.wager) + (uint256(g.wager) * 3) / 2;
        } else if (outcome == Outcome.PLAYER_WIN) {
            payout = stake * 2;
        } else if (outcome == Outcome.PUSH) {
            payout = stake;
        } // losing outcomes: payout = 0

        g.state = GameState.SETTLED;
        g.outcome = outcome;
        // Safe: payout <= 4 * wager <= 4 * ABSOLUTE_MAX_WAGER = uint96.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        g.payout = uint96(payout);
        activeGameOf[g.player] = 0;

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
