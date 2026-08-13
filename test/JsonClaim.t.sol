// test/JsonClaim.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {JsonClaim} from "../src/JsonClaim.sol";

/// @dev External wrapper so `vm.expectRevert` sees a call boundary for the library's reverts.
contract JsonClaimHarness {
    function indexOf(bytes memory hay, bytes memory needle) external pure returns (int256) {
        return JsonClaim.indexOf(hay, needle);
    }

    function requireStringClaim(bytes memory payload, string memory key, string memory expectedValue) external pure {
        JsonClaim.requireStringClaim(payload, key, expectedValue);
    }
}

contract JsonClaim_T is Test {
    JsonClaimHarness harness;

    function setUp() public {
        harness = new JsonClaimHarness();
    }

    // --- indexOf ------------------------------------------------------------

    function test_IndexOfFindsAtStart() public view {
        assertEq(harness.indexOf("abcdef", "abc"), 0);
    }

    function test_IndexOfFindsInMiddle() public view {
        assertEq(harness.indexOf("abcdef", "cd"), 2);
    }

    function test_IndexOfFindsAtEnd() public view {
        assertEq(harness.indexOf("abcdef", "ef"), 4);
    }

    function test_IndexOfFindsFirstOccurrence() public view {
        assertEq(harness.indexOf("abab", "ab"), 0);
    }

    function test_IndexOfReturnsNegativeWhenAbsent() public view {
        assertEq(harness.indexOf("abcdef", "xyz"), -1);
    }

    function test_IndexOfRejectsEmptyNeedle() public view {
        assertEq(harness.indexOf("abcdef", ""), -1);
    }

    function test_IndexOfRejectsNeedleLongerThanHay() public view {
        assertEq(harness.indexOf("ab", "abc"), -1);
    }

    function test_IndexOfHandlesEmptyHay() public view {
        assertEq(harness.indexOf("", "a"), -1);
    }

    function test_IndexOfMatchesWholeHay() public view {
        assertEq(harness.indexOf("abc", "abc"), 0);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_IndexOfFindsPlantedNeedle(bytes memory prefix, bytes memory suffix) public view {
        bytes memory needle = "\"actor_id\":\"1\"";
        bytes memory hay = bytes.concat(prefix, needle, suffix);

        int256 found = harness.indexOf(hay, needle);
        assertGe(found, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertLe(uint256(found), prefix.length);
    }

    // --- requireStringClaim -------------------------------------------------

    function test_RequireStringClaimAcceptsMatch() public view {
        harness.requireStringClaim('{"actor_id":"583231"}', "actor_id", "583231");
    }

    function test_RequireStringClaimAcceptsClaimAmongOthers() public view {
        harness.requireStringClaim('{"a":"1","actor_id":"583231","b":"2"}', "actor_id", "583231");
    }

    function test_RequireStringClaimRevertsWhenMissing() public {
        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMissing.selector, "actor_id"));
        harness.requireStringClaim('{"other":"1"}', "actor_id", "583231");
    }

    function test_RequireStringClaimRevertsOnMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "actor_id"));
        harness.requireStringClaim('{"actor_id":"1"}', "actor_id", "583231");
    }

    function test_RequireStringClaimIsNotPrefixMatched() public {
        // `5832` must not satisfy a check for the full value.
        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "actor_id"));
        harness.requireStringClaim('{"actor_id":"583231"}', "actor_id", "5832");
    }

    function test_RequireStringClaimDistinguishesKeyPrefixes() public {
        // `actor` must not be satisfied by `actor_id`, because the needle includes the closing
        // quote and colon of the key.
        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMissing.selector, "actor"));
        harness.requireStringClaim('{"actor_id":"583231"}', "actor", "583231");
    }

    function test_RequireStringClaimAcceptsEmptyValue() public view {
        harness.requireStringClaim('{"head_ref":""}', "head_ref", "");
    }

    // --- injection safety ---------------------------------------------------

    /// @dev This is the invariant the whole matcher rests on: a JSON encoder escapes `"` inside a
    ///      value, so attacker-controlled free text cannot contain the unescaped quote needed to
    ///      forge a neighbouring claim.
    function test_EscapedQuotesCannotForgeClaim() public {
        bytes memory payload = '{"workflow":"pwn\\",\\"actor_id\\":\\"999999","actor_id":"583231"}';

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "actor_id"));
        harness.requireStringClaim(payload, "actor_id", "999999");
    }

    function test_EscapedQuotesLeaveRealClaimIntact() public view {
        bytes memory payload = '{"workflow":"pwn\\",\\"actor_id\\":\\"999999","actor_id":"583231"}';

        harness.requireStringClaim(payload, "actor_id", "583231");
    }

    /// @dev An unescaped quote would forge a claim, which is exactly why the payload must always
    ///      come from a JSON encoder. Pinned as an explicit statement of the trust boundary.
    function test_UnescapedQuoteWouldForgeClaim() public view {
        bytes memory forged = '{"workflow":"pwn","actor_id":"999999","actor_id":"583231"}';

        harness.requireStringClaim(forged, "actor_id", "999999");
    }
}
