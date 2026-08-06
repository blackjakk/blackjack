// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title TableChat
/// @notice Fully onchain, permissionless chat room for the blackjack table.
///         Messages, replies, reactions, GIF links, nicknames, edits and deletes are
///         all emitted as events; frontends reconstruct the room from logs — no
///         backend, no accounts, no operator.
///
///         MegaETH's ~10ms mini-blocks and near-zero testnet gas make this feel like
///         a regular chat. Clients are expected to use a funded burner key so sending
///         doesn't prompt a wallet popup per message.
///
///         Deliberately has NO owner and NO moderator: nothing here can be censored
///         or confiscated, which also means spam/abuse can only be filtered
///         client-side (see docs/KNOWN_LIMITATIONS.md). Per-address cooldown and
///         size caps are the only onchain rate limits. Play-money testnet toy — the
///         chat is public and permanent; users should never post private information.
contract TableChat {
    enum Kind {
        TEXT,
        GIF // content is a URL; clients only embed known GIF/image hosts
    }

    uint64 public constant MESSAGE_COOLDOWN = 2 seconds;
    uint256 public constant MAX_CONTENT_BYTES = 600;
    uint256 public constant MAX_NICKNAME_BYTES = 32;
    uint256 public constant MAX_REACTION_BYTES = 16;

    uint256 public nextMessageId = 1;
    mapping(uint256 => address) public authorOf;
    mapping(address => uint64) public lastMessageAt;
    mapping(address => string) public nicknameOf;
    /// @dev message id => reactor => keccak(emoji) => currently reacted
    mapping(uint256 => mapping(address => mapping(bytes32 => bool))) public hasReacted;

    event MessageSent(
        uint256 indexed id,
        address indexed author,
        uint256 indexed replyTo, // 0 = not a reply
        Kind kind,
        string content,
        uint64 timestamp
    );
    event MessageEdited(uint256 indexed id, address indexed author, string content);
    event MessageDeleted(uint256 indexed id, address indexed author);
    event ReactionToggled(uint256 indexed id, address indexed reactor, string emoji, bool added);
    event NicknameSet(address indexed user, string name);

    error EmptyContent();
    error ContentTooLong(uint256 length, uint256 max);
    error CooldownActive(uint256 availableAt);
    error BadReplyTarget(uint256 replyTo);
    error NoSuchMessage(uint256 id);
    error NotAuthor(uint256 id);
    error NicknameTooLong(uint256 length, uint256 max);
    error ReactionTooLong(uint256 length, uint256 max);

    function _checkContent(string calldata content) internal pure {
        uint256 len = bytes(content).length;
        if (len == 0) revert EmptyContent();
        if (len > MAX_CONTENT_BYTES) revert ContentTooLong(len, MAX_CONTENT_BYTES);
    }

    /// @notice Post a message. `replyTo` references an earlier message id (0 = none).
    function sendMessage(Kind kind, string calldata content, uint256 replyTo)
        external
        returns (uint256 id)
    {
        _checkContent(content);
        uint256 availableAt = uint256(lastMessageAt[msg.sender]) + MESSAGE_COOLDOWN;
        if (block.timestamp < availableAt) revert CooldownActive(availableAt);
        if (replyTo != 0 && replyTo >= nextMessageId) revert BadReplyTarget(replyTo);

        id = nextMessageId++;
        authorOf[id] = msg.sender;
        lastMessageAt[msg.sender] = uint64(block.timestamp);
        emit MessageSent(id, msg.sender, replyTo, kind, content, uint64(block.timestamp));
    }

    /// @notice Edit your own message. History stays in logs; clients show the latest.
    function editMessage(uint256 id, string calldata content) external {
        _checkContent(content);
        if (authorOf[id] == address(0)) revert NoSuchMessage(id);
        if (authorOf[id] != msg.sender) revert NotAuthor(id);
        emit MessageEdited(id, msg.sender, content);
    }

    /// @notice Delete your own message (a tombstone: clients hide the content, but
    ///         earlier log history remains publicly readable forever).
    function deleteMessage(uint256 id) external {
        if (authorOf[id] == address(0)) revert NoSuchMessage(id);
        if (authorOf[id] != msg.sender) revert NotAuthor(id);
        emit MessageDeleted(id, msg.sender);
    }

    /// @notice Toggle an emoji reaction on a message (Telegram-style like).
    function toggleReaction(uint256 id, string calldata emoji) external {
        uint256 len = bytes(emoji).length;
        if (len == 0) revert EmptyContent();
        if (len > MAX_REACTION_BYTES) revert ReactionTooLong(len, MAX_REACTION_BYTES);
        if (authorOf[id] == address(0)) revert NoSuchMessage(id);

        bytes32 key = keccak256(bytes(emoji));
        bool added = !hasReacted[id][msg.sender][key];
        hasReacted[id][msg.sender][key] = added;
        emit ReactionToggled(id, msg.sender, emoji, added);
    }

    /// @notice Set your display name (shown instead of your address).
    function setNickname(string calldata name) external {
        uint256 len = bytes(name).length;
        if (len > MAX_NICKNAME_BYTES) revert NicknameTooLong(len, MAX_NICKNAME_BYTES);
        nicknameOf[msg.sender] = name;
        emit NicknameSet(msg.sender, name);
    }
}
