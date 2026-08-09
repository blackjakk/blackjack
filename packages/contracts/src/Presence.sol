// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Presence
/// @notice Self-reported "I'm online at table X" beacon. Clients ping every
///         minute or so from their gasless chat burner key; UIs derive the
///         online roster from recent Ping events (nothing is stored beyond an
///         anti-spam clock, so pings cost little more than event gas).
///         Ownerless and uncensorable, like TableChat. Presence is honest-user
///         self-reporting for social UX — it secures nothing and pays nothing,
///         so faking it buys nothing. Play-money platform infrastructure.
contract Presence {
    /// @notice Minimum seconds between pings per sender.
    uint64 public constant COOLDOWN = 20;

    mapping(address => uint64) public lastPing;

    /// @param sender  the (burner) key that pinged — chat identity, nickname key
    /// @param account the main wallet it represents (zero if not connected)
    /// @param table   where they are (zero = browsing / in chat)
    event Ping(address indexed sender, address indexed account, address indexed table);

    error TooFast();

    function ping(address account, address table) external {
        if (block.timestamp < uint256(lastPing[msg.sender]) + COOLDOWN) revert TooFast();
        lastPing[msg.sender] = uint64(block.timestamp);
        emit Ping(msg.sender, account, table);
    }
}
