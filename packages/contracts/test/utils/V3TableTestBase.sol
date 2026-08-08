// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestChip} from "../../src/TestChip.sol";
import {BlackjackTableV3} from "../../src/BlackjackTableV3.sol";
import {TableFactoryV3} from "../../src/TableFactoryV3.sol";
import {MockRandomnessProvider} from "../../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SeedSearch} from "./SeedSearch.sol";

/// @notice v2 harness: deploys chip + mock provider + factory, creates a table with
///         the subclass's rules, funds the house and a player. Variable named `tbl`
///         (not `table`) — forge treats a public `table()` getter as a table test.
abstract contract V3TableTestBase is SeedSearch {
    TestChip internal chip;
    MockRandomnessProvider internal mock;
    TableFactoryV3 internal factory;
    BlackjackTableV3 internal tbl;

    address internal admin = makeAddr("admin");
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant MIN_WAGER = 1e18;
    uint256 internal constant MAX_WAGER = 1_000e18;
    uint256 internal constant HOUSE_BANKROLL = 100_000e18;
    uint256 internal constant PLAYER_STACK = 10_000e18;

    /// @dev Classic rules: S17, 3:2 blackjack, double any two, no surrender.
    function _rules() internal pure virtual returns (BlackjackTableV3.Rules memory) {
        return BlackjackTableV3.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: BlackjackTableV3.DoubleRule.ANY_TWO,
            lateSurrender: false
        });
    }

    function _maxConcurrent() internal pure virtual returns (uint256) {
        return 5;
    }

    function setUp() public virtual {
        chip = new TestChip(admin);
        mock = new MockRandomnessProvider();
        factory = new TableFactoryV3(IERC20(address(chip)), IRandomnessProvider(address(mock)));
        tbl = BlackjackTableV3(
            factory.createTable(_rules(), MIN_WAGER, MAX_WAGER, _maxConcurrent(), admin)
        );

        vm.startPrank(admin);
        chip.mint(admin, HOUSE_BANKROLL);
        chip.approve(address(tbl), type(uint256).max);
        tbl.fundHouse(HOUSE_BANKROLL);
        chip.mint(player, PLAYER_STACK);
        vm.stopPrank();

        vm.prank(player);
        chip.approve(address(tbl), type(uint256).max);
    }

    // ------------------------------------------------------------ flow helpers

    function bet(uint256 wager) internal returns (uint256 gameId) {
        vm.prank(player);
        gameId = tbl.placeBet(wager);
    }

    function fulfill(uint256 gameId, bytes32 seed) internal {
        BlackjackTableV3.Game memory g = tbl.getGame(gameId);
        vm.prank(keeper);
        mock.fulfill(g.pendingRequestId, seed);
    }

    function dealHand(uint256 wager, uint8 p1Rank, uint8 p2Rank, uint8 d1Rank)
        internal
        returns (uint256 gameId)
    {
        gameId = bet(wager);
        fulfill(gameId, findInitialSeed(p1Rank, p2Rank, d1Rank, gameId));
    }

    function gameState(uint256 gameId) internal view returns (BlackjackTableV3.GameState) {
        return tbl.getGame(gameId).state;
    }

    /// @notice Stand and play the dealer out to `dealerTotal` (rule-aware search).
    function standAndDealer(uint256 gameId, uint8 upCardRank, uint8 dealerTotal) internal {
        vm.prank(player);
        tbl.stand(gameId);
        fulfill(
            gameId, findDealerSeedRule(upCardRank, dealerTotal, _rules().dealerHitsSoft17, gameId)
        );
    }
}
