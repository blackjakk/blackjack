// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TableChat} from "../src/TableChat.sol";

contract TableChatTest is Test {
    TableChat chat;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        chat = new TableChat();
        vm.warp(1_000_000); // sane clock
    }

    function send(address who, string memory content) internal returns (uint256 id) {
        vm.prank(who);
        id = chat.sendMessage(TableChat.Kind.TEXT, content, 0);
        vm.warp(block.timestamp + chat.MESSAGE_COOLDOWN());
    }

    // ---------------------------------------------------------- sending

    function test_send_assignsIdsAndAuthor() public {
        uint256 a = send(alice, "gm table");
        uint256 b = send(bob, "gm!");
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(chat.authorOf(a), alice);
        assertEq(chat.authorOf(b), bob);
        assertEq(chat.nextMessageId(), 3);
    }

    function test_send_emitsEventWithTimestamp() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit TableChat.MessageSent(
            1, alice, 0, TableChat.Kind.TEXT, "hello", uint64(block.timestamp)
        );
        chat.sendMessage(TableChat.Kind.TEXT, "hello", 0);
    }

    function test_send_rejectsEmptyAndOversized() public {
        vm.startPrank(alice);
        vm.expectRevert(TableChat.EmptyContent.selector);
        chat.sendMessage(TableChat.Kind.TEXT, "", 0);

        bytes memory big = new bytes(chat.MAX_CONTENT_BYTES() + 1);
        for (uint256 i; i < big.length; ++i) {
            big[i] = "a";
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                TableChat.ContentTooLong.selector, big.length, chat.MAX_CONTENT_BYTES()
            )
        );
        chat.sendMessage(TableChat.Kind.TEXT, string(big), 0);
        vm.stopPrank();
    }

    function test_send_cooldownPerAddress() public {
        vm.prank(alice);
        chat.sendMessage(TableChat.Kind.TEXT, "first", 0);

        // Alice is rate-limited...
        uint256 availableAt = block.timestamp + chat.MESSAGE_COOLDOWN();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TableChat.CooldownActive.selector, availableAt));
        chat.sendMessage(TableChat.Kind.TEXT, "too fast", 0);

        // ...but Bob is not.
        vm.prank(bob);
        chat.sendMessage(TableChat.Kind.TEXT, "independent", 0);

        // And Alice can post again once the window passes.
        vm.warp(availableAt);
        vm.prank(alice);
        chat.sendMessage(TableChat.Kind.TEXT, "ok now", 0);
    }

    function test_reply_mustTargetExistingMessage() public {
        uint256 id = send(alice, "root");
        vm.prank(bob);
        chat.sendMessage(TableChat.Kind.TEXT, "reply", id); // ok

        vm.warp(block.timestamp + chat.MESSAGE_COOLDOWN());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TableChat.BadReplyTarget.selector, 999));
        chat.sendMessage(TableChat.Kind.TEXT, "dangling", 999);
    }

    function test_gifKind_acceptsUrlContent() public {
        vm.prank(alice);
        uint256 id =
            chat.sendMessage(TableChat.Kind.GIF, "https://media.tenor.com/x/blackjack.gif", 0);
        assertEq(chat.authorOf(id), alice);
    }

    // ---------------------------------------------------------- edit / delete

    function test_editAndDelete_authorOnly() public {
        uint256 id = send(alice, "typo");

        vm.prank(alice);
        chat.editMessage(id, "fixed");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TableChat.NotAuthor.selector, id));
        chat.editMessage(id, "hijack");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TableChat.NotAuthor.selector, id));
        chat.deleteMessage(id);

        vm.prank(alice);
        chat.deleteMessage(id);
    }

    function test_editDelete_nonexistentMessageReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(TableChat.NoSuchMessage.selector, 42));
        chat.editMessage(42, "ghost");
        vm.expectRevert(abi.encodeWithSelector(TableChat.NoSuchMessage.selector, 42));
        chat.deleteMessage(42);
        vm.stopPrank();
    }

    // ---------------------------------------------------------- reactions

    function test_reactions_togglePerUserPerEmoji() public {
        uint256 id = send(alice, "nice hand");
        bytes32 key = keccak256(bytes(unicode"🔥"));

        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit TableChat.ReactionToggled(id, bob, unicode"🔥", true);
        chat.toggleReaction(id, unicode"🔥");
        assertTrue(chat.hasReacted(id, bob, key));

        // Same user + same emoji toggles OFF; different emoji is independent.
        vm.prank(bob);
        chat.toggleReaction(id, unicode"🔥");
        assertFalse(chat.hasReacted(id, bob, key));

        vm.prank(bob);
        chat.toggleReaction(id, unicode"❤️");
        assertTrue(chat.hasReacted(id, bob, keccak256(bytes(unicode"❤️"))));
    }

    function test_reactions_validation() public {
        uint256 id = send(alice, "msg");
        vm.startPrank(bob);
        vm.expectRevert(TableChat.EmptyContent.selector);
        chat.toggleReaction(id, "");
        vm.expectRevert(
            abi.encodeWithSelector(
                TableChat.ReactionTooLong.selector, 17, chat.MAX_REACTION_BYTES()
            )
        );
        chat.toggleReaction(id, "12345678901234567");
        vm.expectRevert(abi.encodeWithSelector(TableChat.NoSuchMessage.selector, 99));
        chat.toggleReaction(99, unicode"🔥");
        vm.stopPrank();
    }

    // ---------------------------------------------------------- nicknames

    function test_nickname_setAndCap() public {
        vm.prank(alice);
        chat.setNickname("CardShark");
        assertEq(chat.nicknameOf(alice), "CardShark");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TableChat.NicknameTooLong.selector, 33, uint256(32)));
        chat.setNickname("123456789012345678901234567890123");

        // Clearing is allowed (empty = fall back to address display).
        vm.prank(alice);
        chat.setNickname("");
        assertEq(chat.nicknameOf(alice), "");
    }

    // ---------------------------------------------------------- fuzz

    function testFuzz_contentLengthBoundary(uint256 len) public {
        len = bound(len, 1, chat.MAX_CONTENT_BYTES());
        bytes memory content = new bytes(len);
        for (uint256 i; i < len; ++i) {
            content[i] = "x";
        }
        vm.prank(alice);
        uint256 id = chat.sendMessage(TableChat.Kind.TEXT, string(content), 0);
        assertEq(chat.authorOf(id), alice);
    }
}
