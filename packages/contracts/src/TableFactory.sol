// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRandomnessProvider} from "./interfaces/IRandomnessProvider.sol";
import {BlackjackTableV2} from "./BlackjackTableV2.sol";

/// @title TableFactory
/// @notice Permissionless factory for BlackjackTableV2 variants sharing one chip token
///         and one default randomness provider. Anyone may create a table with any
///         (validated) rule set; each table's bankroll is funded separately via the
///         table's permissionless `fundHouse`, so a table is only as trustworthy as
///         its funding and admin — UIs should present a curated list alongside the
///         open registry. Play money only.
contract TableFactory {
    IERC20 public immutable chip;
    IRandomnessProvider public immutable provider;

    address[] internal _tables;
    /// @notice Bytecode provenance: true iff THIS factory deployed `table`, i.e.
    ///         the table is byte-identical to the reviewed engine (only its
    ///         constructor parameters differ). Pools use this for tier-1 trust.
    mapping(address => bool) public isFromFactory;

    event TableCreated(
        address indexed table,
        address indexed admin,
        address indexed creator,
        BlackjackTableV2.Rules rules,
        uint256 minWager,
        uint256 maxWager,
        uint256 maxConcurrentGames
    );

    error ZeroAddress();

    constructor(IERC20 chip_, IRandomnessProvider provider_) {
        if (address(chip_) == address(0) || address(provider_) == address(0)) {
            revert ZeroAddress();
        }
        chip = chip_;
        provider = provider_;
    }

    /// @notice Deploy a new table. `admin` receives DEFAULT_ADMIN_ROLE and
    ///         TREASURY_ROLE on the table (defaults to the caller when zero).
    ///         Rule/limit validation happens in the table constructor.
    function createTable(
        BlackjackTableV2.Rules calldata rules,
        uint256 minWager,
        uint256 maxWager,
        uint256 maxConcurrentGames,
        address admin
    ) external returns (address table) {
        address admin_ = admin == address(0) ? msg.sender : admin;
        table = address(
            new BlackjackTableV2(
                chip, provider, rules, minWager, maxWager, maxConcurrentGames, admin_
            )
        );
        _tables.push(table);
        isFromFactory[table] = true;
        emit TableCreated(table, admin_, msg.sender, rules, minWager, maxWager, maxConcurrentGames);
    }

    function tableCount() external view returns (uint256) {
        return _tables.length;
    }

    function tableAt(uint256 index) external view returns (address) {
        return _tables[index];
    }

    function allTables() external view returns (address[] memory) {
        return _tables;
    }
}
