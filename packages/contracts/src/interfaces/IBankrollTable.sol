// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IBankrollTable
/// @notice The treasury surface every house-banked game on this platform exposes.
///         BlackjackTableV2/V3 and InfiniteBlackjack all satisfy it, which is what
///         lets one SharedBankrollVault back every game of the same asset.
interface IBankrollTable {
    /// @notice The ERC-20 the table is denominated in (named after the v1 test chip;
    ///         real-asset tables return their asset token here).
    function chip() external view returns (IERC20);

    /// @notice Funds owned by the house (excludes player escrow).
    function houseFunds() external view returns (uint256);

    /// @notice House funds not reserved for in-flight games.
    function availableLiquidity() external view returns (uint256);

    /// @notice Permissionless bankroll deposit (pulls via transferFrom).
    function fundHouse(uint256 amount) external;

    /// @notice TREASURY_ROLE-gated withdrawal of UNRESERVED house funds.
    function withdrawHouseFunds(address to, uint256 amount) external;

    function TREASURY_ROLE() external view returns (bytes32);

    function hasRole(bytes32 role, address account) external view returns (bool);
}
