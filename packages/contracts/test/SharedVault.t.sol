// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SeedSearch} from "./utils/SeedSearch.sol";
import {TestChip} from "../src/TestChip.sol";
import {BlackjackTableV2} from "../src/BlackjackTableV2.sol";
import {InfiniteBlackjack} from "../src/InfiniteBlackjack.sol";
import {SharedBankrollVault} from "../src/SharedBankrollVault.sol";
import {TableFactory} from "../src/TableFactory.sol";
import {IBankrollTable} from "../src/interfaces/IBankrollTable.sol";
import {MockRandomnessProvider} from "../src/rand/MockRandomnessProvider.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomnessProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A malicious "game": reports funds it does not hold and refuses to pay.
contract LyingTable {
    IERC20 public chip;
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    constructor(IERC20 chip_) {
        chip = chip_;
    }

    function houseFunds() external pure returns (uint256) {
        return 1_000_000_000e18; // pure fiction
    }

    function availableLiquidity() external pure returns (uint256) {
        return 1_000_000_000e18;
    }

    function fundHouse(uint256 amount) external {
        chip.transferFrom(msg.sender, address(this), amount);
    }

    function withdrawHouseFunds(address, uint256) external pure {
        revert("nope");
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return true; // claims anyone is treasury
    }
}

/// @notice One vault, one asset, many games — with governance-gated, bonded,
///         float-capped membership. Every unit of bankroll flows through the
///         vault in this suite so share-price assertions are exact.
contract SharedVaultTest is SeedSearch {
    TestChip internal chip;
    TestChip internal mega; // bond token stand-in
    MockRandomnessProvider internal mock;
    BlackjackTableV2 internal tblA;
    InfiniteBlackjack internal tblI;
    SharedBankrollVault internal vault;
    TableFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal gov = makeAddr("governance"); // bond beneficiary (slash sink)
    address internal lp = makeAddr("lp");
    address internal player = makeAddr("player");

    uint256 internal constant DEPOSIT = 1_000e18;
    uint256 internal constant W = 10e18;
    uint256 internal constant TIER2_BOND = 100e18;
    uint256 internal constant FLOAT = 100_000e18;

    function setUp() public {
        chip = new TestChip(admin);
        mega = new TestChip(admin);
        mock = new MockRandomnessProvider();
        factory = new TableFactory(IERC20(address(chip)), IRandomnessProvider(address(mock)));
        tblA = _newV2Table(chip);
        tblI = new InfiniteBlackjack(
            IERC20(address(chip)),
            IRandomnessProvider(address(mock)),
            InfiniteBlackjack.Rules({
                dealerHitsSoft17: false,
                blackjackNum: 3,
                blackjackDen: 2,
                doubleRule: InfiniteBlackjack.DoubleRule.ANY_TWO,
                lateSurrender: true
            }),
            1e18,
            1_000e18,
            60,
            60,
            100,
            admin
        );
        vault = new SharedBankrollVault(
            IERC20(address(chip)),
            1 hours,
            8 hours, // tier-2 delay; tier-1 waits a quarter (2h)
            IERC20(address(mega)),
            gov,
            TIER2_BOND,
            "Blackjack CHIP Pool",
            "bjCHIP",
            admin
        );

        vm.startPrank(admin);
        tblA.grantRole(tblA.TREASURY_ROLE(), address(vault));
        tblA.revokeRole(tblA.TREASURY_ROLE(), admin);
        tblI.grantRole(tblI.TREASURY_ROLE(), address(vault));
        tblI.revokeRole(tblI.TREASURY_ROLE(), admin);
        vault.setTrustedFactory(address(factory), true);
        // Zero shares outstanding -> proposals activate instantly and bond-free.
        vault.proposeTable(IBankrollTable(address(tblA)), FLOAT);
        vault.proposeTable(IBankrollTable(address(tblI)), FLOAT);
        chip.mint(lp, 10_000e18);
        chip.mint(player, 1_000e18);
        mega.mint(admin, 10_000e18);
        mega.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.prank(lp);
        chip.approve(address(vault), type(uint256).max);
        vm.startPrank(player);
        chip.approve(address(tblA), type(uint256).max);
        chip.approve(address(tblI), type(uint256).max);
        vm.stopPrank();
    }

    function deposit() internal returns (uint256 shares) {
        vm.prank(lp);
        shares = vault.deposit(DEPOSIT, lp);
    }

    // ------------------------------------------------------------ pool mechanics

    function test_depositStaysIdle_permissionlessFundPushes() public {
        deposit();
        assertEq(chip.balanceOf(address(vault)), DEPOSIT, "deposits idle");
        assertEq(vault.totalAssets(), DEPOSIT);

        vm.prank(makeAddr("anyone")); // fundTable is deliberately permissionless
        vault.fundTable(IBankrollTable(address(tblA)), 600e18);
        vault.fundTable(IBankrollTable(address(tblI)), 400e18);

        assertEq(tblA.houseFunds(), 600e18);
        assertEq(tblI.houseFunds(), 400e18);
        assertEq(chip.balanceOf(address(vault)), 0);
        assertEq(vault.totalAssets(), DEPOSIT, "totalAssets unchanged by rebalance");
    }

    function test_fundTableEnforcesFloatCap() public {
        deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 600e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedBankrollVault.FloatCapExceeded.selector,
                address(tblA),
                FLOAT + 1,
                FLOAT
            )
        );
        vault.fundTable(IBankrollTable(address(tblA)), FLOAT + 1 - 600e18);
    }

    function test_defundIsRoleGated() public {
        deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 600e18);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert();
        vault.defundTable(IBankrollTable(address(tblA)), 100e18);

        vm.prank(admin);
        vault.defundTable(IBankrollTable(address(tblA)), 100e18);
        assertEq(tblA.houseFunds(), 500e18);
        assertEq(chip.balanceOf(address(vault)), 500e18);
    }

    function test_proposeTableGuards() public {
        // Non-admin cannot propose.
        BlackjackTableV2 rogue = _newV2Table(chip);
        vm.prank(makeAddr("anyone"));
        vm.expectRevert();
        vault.proposeTable(IBankrollTable(address(rogue)), FLOAT);

        // Vault must already hold the table's treasury role.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.VaultNotTreasury.selector, address(rogue))
        );
        vault.proposeTable(IBankrollTable(address(rogue)), FLOAT);

        // Asset must match.
        TestChip other = new TestChip(admin);
        BlackjackTableV2 wrongAsset = _newV2Table(other);
        vm.startPrank(admin);
        wrongAsset.grantRole(wrongAsset.TREASURY_ROLE(), address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.AssetMismatch.selector, address(wrongAsset))
        );
        vault.proposeTable(IBankrollTable(address(wrongAsset)), FLOAT);

        // No duplicates.
        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.AlreadyMember.selector, address(tblA))
        );
        vault.proposeTable(IBankrollTable(address(tblA)), FLOAT);
        vm.stopPrank();

        assertEq(vault.tables().length, 2);
    }

    // ------------------------------------------------------------ tiers + bonds

    function _readyCandidate() internal returns (BlackjackTableV2 t) {
        t = _newV2Table(chip);
        bytes32 role = t.TREASURY_ROLE(); // hoisted: external call in args eats the prank
        vm.prank(admin);
        t.grantRole(role, address(vault));
    }

    /// @notice Tier 2 (novel code): full delay, bond pulled at proposal, LPs can
    ///         complete a full exit inside the window, activation permissionless.
    function test_tier2MembershipTimelockAndBond() public {
        deposit();
        BlackjackTableV2 t = _readyCandidate();

        uint256 megaBefore = mega.balanceOf(admin);
        vm.prank(admin);
        vault.proposeTable(IBankrollTable(address(t)), FLOAT);
        assertEq(mega.balanceOf(admin), megaBefore - TIER2_BOND, "tier-2 bond escrowed");
        assertFalse(vault.isMember(address(t)));
        (address[] memory pend, uint64[] memory etas) = vault.pendingProposals();
        assertEq(pend[0], address(t));
        assertEq(etas[0], uint64(block.timestamp) + 8 hours, "full tier-2 delay");

        vm.expectRevert(
            abi.encodeWithSelector(
                SharedBankrollVault.ProposalNotMatured.selector, address(t), etas[0]
            )
        );
        vault.activateTable(IBankrollTable(address(t)));

        // A dissenting LP fully exits inside the window.
        vm.startPrank(lp);
        vault.requestRedeem(vault.balanceOf(lp));
        vm.warp(block.timestamp + 1 hours);
        vault.claim(lp);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 hours);
        vm.prank(makeAddr("anyone"));
        vault.activateTable(IBankrollTable(address(t)));
        assertTrue(vault.isMember(address(t)));
    }

    /// @notice Tier 1 (factory-provenanced byte-identical code): quarter delay,
    ///         tier-1 bond (zero by default).
    function test_tier1FactoryTablesGetQuarterDelay() public {
        deposit();
        vm.prank(admin);
        BlackjackTableV2 t = BlackjackTableV2(
            factory.createTable(_classicRules(), 1e18, 1_000e18, 5, admin)
        );
        assertTrue(factory.isFromFactory(address(t)));
        bytes32 role = t.TREASURY_ROLE();
        vm.startPrank(admin);
        t.grantRole(role, address(vault));
        uint256 megaBefore = mega.balanceOf(admin);
        vault.proposeTable(IBankrollTable(address(t)), FLOAT);
        vm.stopPrank();
        assertEq(mega.balanceOf(admin), megaBefore, "tier-1 bond is zero by default");
        (, uint64[] memory etas) = vault.pendingProposals();
        assertEq(etas[0], uint64(block.timestamp) + 2 hours, "quarter delay");
    }

    function test_bondReturnedOnCancelAndCleanRemoval() public {
        deposit();
        BlackjackTableV2 t = _readyCandidate();
        uint256 megaBefore = mega.balanceOf(admin);

        // Cancel path.
        vm.startPrank(admin);
        vault.proposeTable(IBankrollTable(address(t)), FLOAT);
        vault.cancelTableProposal(IBankrollTable(address(t)));
        assertEq(mega.balanceOf(admin), megaBefore, "bond back on cancel");

        // Clean-removal path.
        vault.proposeTable(IBankrollTable(address(t)), FLOAT);
        vm.warp(block.timestamp + 8 hours);
        vault.activateTable(IBankrollTable(address(t)));
        assertEq(mega.balanceOf(admin), megaBefore - TIER2_BOND);
        vault.removeTable(IBankrollTable(address(t))); // houseFunds == 0
        assertEq(mega.balanceOf(admin), megaBefore, "bond back on clean exit");
        assertFalse(vault.isMember(address(t)));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ lying members

    /// @notice The accounting cap: a member's reported houseFunds counts toward
    ///         totalAssets only up to 2x its float cap — fiction is bounded.
    function test_totalAssetsCapsLyingMember() public {
        deposit();
        LyingTable liar = new LyingTable(IERC20(address(chip)));
        vm.startPrank(admin);
        vault.proposeTable(IBankrollTable(address(liar)), 50e18);
        vm.warp(block.timestamp + 8 hours);
        vm.stopPrank();
        vault.activateTable(IBankrollTable(address(liar)));

        // Reports a billion; counts as at most 2 * 50.
        assertEq(vault.totalAssets(), DEPOSIT + 100e18, "fiction capped at 2x float");
    }

    /// @notice The objective slash: a member that cannot deliver funds it reports
    ///         is ejected by anyone and its bond forfeits to governance.
    function test_claimDefaultSlashesLiar() public {
        deposit();
        LyingTable liar = new LyingTable(IERC20(address(chip)));
        vm.startPrank(admin);
        vault.proposeTable(IBankrollTable(address(liar)), 50e18);
        vm.warp(block.timestamp + 8 hours);
        vm.stopPrank();
        vault.activateTable(IBankrollTable(address(liar)));

        vm.prank(makeAddr("anyone"));
        vault.claimDefault(IBankrollTable(address(liar)), 10e18);
        assertFalse(vault.isMember(address(liar)), "liar ejected");
        assertEq(mega.balanceOf(gov), TIER2_BOND, "bond slashed to governance");
        assertEq(vault.totalAssets(), DEPOSIT, "books clean again");
    }

    /// @notice Honest members pass the default test — it just becomes a defund.
    function test_claimDefaultIsHarmlessToHonestTables() public {
        deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 500e18);
        vm.prank(makeAddr("anyone"));
        vault.claimDefault(IBankrollTable(address(tblA)), 200e18);
        assertTrue(vault.isMember(address(tblA)), "honest member stays");
        assertEq(tblA.houseFunds(), 300e18);
        assertEq(chip.balanceOf(address(vault)), DEPOSIT - 300e18);
        assertEq(vault.totalAssets(), DEPOSIT);
    }

    // ------------------------------------------------------------ misc governance

    function test_zeroSupplyBootstrapAddsInstantly() public view {
        assertEq(vault.tables().length, 2);
        assertTrue(vault.isMember(address(tblA)));
        assertTrue(vault.isMember(address(tblI)));
    }

    function test_activationRechecksConditions() public {
        deposit();
        BlackjackTableV2 t = _readyCandidate();
        vm.startPrank(admin);
        vault.proposeTable(IBankrollTable(address(t)), FLOAT);
        // Conditions change during the delay: the vault loses the treasury role.
        t.revokeRole(t.TREASURY_ROLE(), address(vault));
        vm.stopPrank();
        vm.warp(block.timestamp + 8 hours);
        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.VaultNotTreasury.selector, address(t))
        );
        vault.activateTable(IBankrollTable(address(t)));
    }

    function test_membershipDelayMustCoverFullExit() public {
        vm.expectRevert(SharedBankrollVault.InvalidDelay.selector);
        new SharedBankrollVault(
            IERC20(address(chip)),
            1 hours,
            479 minutes, // < 8x withdrawDelay
            IERC20(address(mega)),
            gov,
            TIER2_BOND,
            "x",
            "x",
            admin
        );
    }

    function test_removeTableOnlyWhenDefunded() public {
        deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 100e18);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.TableNotEmpty.selector, address(tblA))
        );
        vault.removeTable(IBankrollTable(address(tblA)));

        vm.startPrank(admin);
        vault.defundTable(IBankrollTable(address(tblA)), 100e18);
        vault.removeTable(IBankrollTable(address(tblA)));
        vm.stopPrank();
        assertFalse(vault.isMember(address(tblA)));
        assertEq(vault.tables().length, 1);
        assertEq(vault.totalAssets(), DEPOSIT);
    }

    // ------------------------------------------------------------ share price

    function test_sharePriceSharedAcrossGames() public {
        uint256 shares = deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 500e18);
        vault.fundTable(IBankrollTable(address(tblI)), 500e18);
        uint256 before = vault.previewRedeem(shares);

        // Player loses W at the classic table: stands on 14, dealer makes 18.
        vm.prank(player);
        uint256 gameId = tblA.placeBet(W);
        mock.fulfill(tblA.getGame(gameId).pendingRequestId, findInitialSeed(6, 6, 8, gameId));
        vm.prank(player);
        tblA.stand(gameId);
        mock.fulfill(tblA.getGame(gameId).pendingRequestId, findDealerSeedRule(8, 18, false, gameId));
        assertEq(uint8(tblA.getGame(gameId).outcome), uint8(BlackjackTableV2.Outcome.DEALER_WIN));

        assertEq(vault.totalAssets(), DEPOSIT + W);
        assertGt(vault.previewRedeem(shares), before);
    }

    // ------------------------------------------------------------ exit queue

    function test_claimPullsAcrossAllMemberTables() public {
        uint256 shares = deposit();
        vault.fundTable(IBankrollTable(address(tblA)), 600e18);
        vault.fundTable(IBankrollTable(address(tblI)), 400e18); // idle now 0

        vm.prank(lp);
        vault.requestRedeem(shares);
        vm.warp(block.timestamp + 1 hours);
        uint256 before = chip.balanceOf(lp);
        vm.prank(lp);
        uint256 assets = vault.claim(lp);

        assertApproxEqAbs(assets, DEPOSIT, 1e13, "full pool back");
        assertEq(chip.balanceOf(lp), before + assets);
        assertApproxEqAbs(tblA.houseFunds() + tblI.houseFunds(), 0, 1e13, "tables swept");
    }

    function test_claimBlockedWhileReserved_thenSucceeds() public {
        uint256 shares = deposit();
        vault.fundTable(IBankrollTable(address(tblA)), DEPOSIT);

        vm.prank(player);
        uint256 gameId = tblA.placeBet(500e18 - 1e18); // reserves ~998, leaves ~2 free

        vm.prank(lp);
        vault.requestRedeem(shares);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(lp);
        vm.expectRevert(); // InsufficientLiquidAssets — most of the pool is reserved
        vault.claim(lp);

        vm.prank(player);
        tblA.cancelTimedOutGame(gameId);
        vm.prank(lp);
        uint256 assets = vault.claim(lp);
        assertApproxEqAbs(assets, DEPOSIT, 1e13);
    }

    function test_exitQueueSemantics() public {
        uint256 shares = deposit();

        vm.startPrank(lp);
        vm.expectRevert(); // instant 4626 exits are disabled (maxRedeem = 0)
        vault.redeem(shares, lp, lp);
        vm.expectRevert();
        vault.withdraw(100e18, lp, lp);

        vault.requestRedeem(shares / 2);
        (, uint64 claimableAt) = vault.exitRequests(lp);
        assertEq(claimableAt, uint64(block.timestamp) + 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(SharedBankrollVault.NotClaimableYet.selector, claimableAt)
        );
        vault.claim(lp);

        // Top-up restarts the clock for the whole aggregate request.
        vm.warp(block.timestamp + 30 minutes);
        vault.requestRedeem(shares / 4);
        (uint192 pending, uint64 newClaimable) = vault.exitRequests(lp);
        assertEq(uint256(pending), shares / 2 + shares / 4);
        assertEq(newClaimable, uint64(block.timestamp) + 1 hours);

        vm.warp(block.timestamp + 1 hours);
        uint256 assets = vault.claim(lp);
        assertApproxEqAbs(assets, (DEPOSIT * 3) / 4, 1e13);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ helpers

    function _classicRules() internal pure returns (BlackjackTableV2.Rules memory) {
        return BlackjackTableV2.Rules({
            dealerHitsSoft17: false,
            blackjackNum: 3,
            blackjackDen: 2,
            doubleRule: BlackjackTableV2.DoubleRule.ANY_TWO,
            lateSurrender: false
        });
    }

    function _newV2Table(TestChip token) internal returns (BlackjackTableV2) {
        return new BlackjackTableV2(
            IERC20(address(token)),
            IRandomnessProvider(address(mock)),
            _classicRules(),
            1e18,
            1_000e18,
            5,
            admin
        );
    }
}
