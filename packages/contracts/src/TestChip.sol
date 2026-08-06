// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TestChip
/// @notice Valueless play-money ERC-20 for the MegaETH blackjack testnet MVP.
///         Anyone can mint a fixed amount from the faucet on a per-address cooldown;
///         the owner can mint arbitrary amounts (e.g. to seed the house bankroll).
/// @dev Deliberately a vanilla OZ ERC20: no transfer hooks, no fees, no rebasing.
///      The blackjack table's accounting assumes exactly this behavior.
contract TestChip is ERC20, Ownable {
    uint256 public constant FAUCET_AMOUNT = 1_000e18;
    uint256 public constant FAUCET_COOLDOWN = 1 hours;

    mapping(address => uint256) public lastFaucetClaim;

    event FaucetClaimed(address indexed account, uint256 amount);

    error FaucetCooldownActive(uint256 availableAt);

    constructor(address initialOwner) ERC20("Blackjack Test Chip", "CHIP") Ownable(initialOwner) {}

    /// @notice Mint FAUCET_AMOUNT to the caller, once per cooldown window.
    function faucet() external {
        uint256 availableAt = lastFaucetClaim[msg.sender] + FAUCET_COOLDOWN;
        if (lastFaucetClaim[msg.sender] != 0 && block.timestamp < availableAt) {
            revert FaucetCooldownActive(availableAt);
        }
        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetClaimed(msg.sender, FAUCET_AMOUNT);
    }

    /// @notice Owner mint for seeding house bankrolls and test setups.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
