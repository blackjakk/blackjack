// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomnessProvider.sol";
import {BlackjackTable} from "../../src/BlackjackTable.sol";

// NOTE: state variables here are `internal` with explicit setters — a public `table`
// getter would be picked up by forge as a table-driven test function.

/// @notice Provider that attempts to reenter the table during requestRandomness.
contract ReentrantProvider is IRandomnessProvider {
    BlackjackTable internal tbl;
    uint256 public nextId = 1;

    enum Attack {
        NONE,
        PLACE_BET,
        HIT,
        FULFILL
    }

    Attack public attack;

    function setTable(BlackjackTable t) external {
        tbl = t;
    }

    function setAttack(Attack a) external {
        attack = a;
    }

    function requestRandomness(uint256) external returns (uint256 requestId) {
        requestId = nextId++;
        if (attack == Attack.PLACE_BET) {
            tbl.placeBet(1e18); // must revert: reentrancy guard
        } else if (attack == Attack.HIT) {
            tbl.hit();
        } else if (attack == Attack.FULFILL) {
            tbl.fulfillRandomness(requestId, bytes32(uint256(1)));
        }
    }
}

/// @notice Provider that tries to fulfill its own request BEFORE returning the id
///         (i.e. before the table has bound it). The inner call must revert with
///         UnknownRequest; the provider swallows it and reports what happened.
contract PreFulfillProvider is IRandomnessProvider {
    BlackjackTable internal tbl;
    uint256 public nextId = 1;
    bool public innerCallReverted;

    function setTable(BlackjackTable t) external {
        tbl = t;
    }

    function requestRandomness(uint256) external returns (uint256 requestId) {
        requestId = nextId++;
        try tbl.fulfillRandomness(requestId, bytes32(uint256(42))) {
            innerCallReverted = false; // would be a serious bug
        } catch {
            innerCallReverted = true;
        }
    }

    /// Legitimate later fulfillment for flow continuation.
    function fulfill(uint256 requestId, bytes32 seed) external {
        tbl.fulfillRandomness(requestId, seed);
    }
}

/// @notice ERC20 whose transfers TO a blocked address revert — simulates a token-level
///         transfer failure so tests can prove settlement fails atomically and is
///         retryable. (TestChip itself has no such behavior.)
contract BlockableToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blockable", "BLK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "BLK: transfer blocked");
        super._update(from, to, value);
    }
}
