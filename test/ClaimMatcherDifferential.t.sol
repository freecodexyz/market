// test/ClaimMatcherDifferential.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ClaimMatcher} from "../src/ClaimMatcher.sol";
import {JsonClaim} from "../src/JsonClaim.sol";

/**
 * @dev The byte-at-a-time search both implementations replaced, kept verbatim as an oracle.
 *
 * Obviously correct and obviously slow, which is exactly what an oracle should be. Do not optimise
 * it, and do not make it share code with either implementation under test.
 */
library NaiveSearch {
    function indexOf(bytes memory hay, bytes memory needle) internal pure returns (int256) {
        if (needle.length == 0 || hay.length < needle.length) return -1;

        for (uint256 i = 0; i <= hay.length - needle.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            // safe to cast uint256 -> int256
            // forge-lint: disable-next-line(unsafe-typecast)
            if (match_) return int256(i);
        }
        return -1;
    }
}

/// @dev External wrapper so `vm.expectRevert` sees a call boundary for the library's reverts.
contract ClaimMatcherHarness {
    function requireStringClaim(bytes memory payload, string memory key, string memory expectedValue) external pure {
        ClaimMatcher.requireStringClaim(payload, key, expectedValue);
    }
}

/**
 * @dev Three-way differential guard for {ClaimMatcher-indexOf}.
 *
 * {ClaimMatcher} exists only to be faster than {JsonClaim}, which is the copy of the deployed
 * `identity` source. Any input on which the two disagree is a bug in the faster one, and the naive
 * search is there so that a shared misunderstanding between the two word-at-a-time implementations
 * cannot hide. The unrolled scan makes the four-position stride and the one-to-three position tail
 * the fragile part, so the fuzzers deliberately hammer lengths and offsets around those boundaries.
 */
contract ClaimMatcherDifferential_T is Test {
    /// @dev Padding long enough that a sliced needle can straddle several word boundaries.
    bytes constant FILLER =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    ClaimMatcherHarness harness;

    function setUp() public {
        harness = new ClaimMatcherHarness();
    }

    function _assertAgrees(bytes memory hay, bytes memory needle) internal pure {
        int256 expected = NaiveSearch.indexOf(hay, needle);
        assertEq(ClaimMatcher.indexOf(hay, needle), expected, "unrolled scan disagrees with naive search");
        assertEq(JsonClaim.indexOf(hay, needle), expected, "vendored scan disagrees with naive search");
    }

    /// @dev Copies `length` bytes out of `source` starting at `start`.
    function _slice(bytes memory source, uint256 start, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = source[start + i];
        }
    }

    // --- unconstrained ------------------------------------------------------

    /// @dev Mostly misses. Proves the scan never reports a match that is not there.
    /// forge-config: default.fuzz.runs = 10000
    /// forge-config: deep.fuzz.runs = 250000
    function testFuzz_AgreesOnArbitraryInput(bytes memory hay, bytes memory needle) public pure {
        _assertAgrees(hay, needle);
    }

    /// @dev Guarantees a hit, so the index itself is compared rather than just "not found".
    /// forge-config: default.fuzz.runs = 10000
    /// forge-config: deep.fuzz.runs = 250000
    function testFuzz_AgreesOnPlantedNeedle(bytes memory prefix, bytes memory needle, bytes memory suffix) public pure {
        _assertAgrees(bytes.concat(prefix, needle, suffix), needle);
    }

    // --- unrolled stride boundaries -----------------------------------------

    /// @dev A match at every possible offset in a fixed haystack. The unrolled loop advances four
    ///      positions per iteration, so a match must be reported at the same index whichever of the
    ///      four slots it lands in, and whether it falls inside the unrolled body or the tail.
    function test_AgreesAtEveryMatchOffset() public pure {
        bytes memory needle = "NEEDLE";

        for (uint256 offset = 0; offset <= 64; offset++) {
            bytes memory hay = bytes.concat(_slice(FILLER, 0, offset), needle, _slice(FILLER, 0, 40));
            _assertAgrees(hay, needle);
        }
    }

    /// @dev Haystacks whose length leaves 0, 1, 2 or 3 positions for the tail loop.
    function test_AgreesAtEveryHaystackLengthNearTheStride() public pure {
        bytes memory needle = "xyz";

        for (uint256 length = 3; length <= 48; length++) {
            bytes memory hay = _slice(FILLER, 0, length);
            // A miss at this length.
            _assertAgrees(hay, needle);
            // And a hit at the very last position, which only the tail loop can reach.
            bytes memory withTailMatch = bytes.concat(_slice(FILLER, 0, length - 3), needle);
            _assertAgrees(withTailMatch, needle);
        }
    }

    /// @dev Needle exactly as long as the haystack, so the unrolled loop must not run at all.
    function test_AgreesWhenNeedleIsWholeHaystack() public pure {
        _assertAgrees(FILLER, FILLER);

        for (uint256 length = 1; length <= 40; length++) {
            bytes memory hay = _slice(FILLER, 0, length);
            _assertAgrees(hay, hay);
        }
    }

    // --- word boundaries ----------------------------------------------------

    /// @dev Needles sliced out of the haystack at a fuzzed offset and length. This is where a
    ///      masked word comparison goes wrong: partial first words, partial tail words, and
    ///      candidate positions that are not word aligned.
    /// forge-config: default.fuzz.runs = 5000
    /// forge-config: deep.fuzz.runs = 150000
    function testFuzz_AgreesOnSlicedNeedle(bytes memory seed, uint8 rawLength, uint8 rawStart) public pure {
        bytes memory hay = bytes.concat(seed, FILLER);

        uint256 length = bound(uint256(rawLength), 1, 70);
        uint256 start = bound(uint256(rawStart), 0, hay.length - length);

        _assertAgrees(hay, _slice(hay, start, length));
    }

    /// @dev Every needle length from one byte to just past two words, exhaustively.
    function test_AgreesOnEveryNeedleLengthAcrossTwoWords() public pure {
        bytes memory hay = bytes.concat(FILLER, "tail");

        for (uint256 length = 1; length <= 66; length++) {
            // Offset by one so the needle is never word aligned with the haystack.
            _assertAgrees(hay, _slice(hay, 1, length));
        }
    }

    /// @dev The same lengths, but with the needle at the very end, where the loads read past the
    ///      end of the array and rely on masking.
    function test_AgreesOnNeedleAtEndOfHaystack() public pure {
        bytes memory hay = bytes.concat(FILLER, "tail");

        for (uint256 length = 1; length <= 66; length++) {
            _assertAgrees(hay, _slice(hay, hay.length - length, length));
        }
    }

    function test_AgreesOnExactWordLengths() public pure {
        bytes memory hay = bytes.concat("x", FILLER);

        _assertAgrees(hay, _slice(hay, 1, 31));
        _assertAgrees(hay, _slice(hay, 1, 32));
        _assertAgrees(hay, _slice(hay, 1, 33));
        _assertAgrees(hay, _slice(hay, 1, 63));
        _assertAgrees(hay, _slice(hay, 1, 64));
        _assertAgrees(hay, _slice(hay, 1, 65));
    }

    /// @dev A near miss in the final byte must not be swallowed by a mask that is one byte too wide.
    function test_AgreesOnNeedleDifferingInLastByteOnly() public pure {
        bytes memory hay = bytes.concat("x", FILLER);

        for (uint256 length = 1; length <= 66; length++) {
            bytes memory needle = _slice(hay, 1, length);
            needle[length - 1] = bytes1(uint8(needle[length - 1]) ^ 1);
            _assertAgrees(hay, needle);
        }
    }

    /// @dev The first occurrence wins, so a later duplicate must never be reported instead.
    function test_AgreesOnRepeatedNeedle() public pure {
        for (uint256 gap = 0; gap <= 40; gap++) {
            bytes memory hay = bytes.concat("ab", _slice(FILLER, 0, gap), "ab");
            _assertAgrees(hay, "ab");
        }
    }

    // --- degenerate inputs --------------------------------------------------

    function test_AgreesOnEmptyNeedle() public pure {
        _assertAgrees("abcdef", "");
    }

    function test_AgreesOnEmptyHaystack() public pure {
        _assertAgrees("", "a");
    }

    function test_AgreesOnBothEmpty() public pure {
        _assertAgrees("", "");
    }

    function test_AgreesWhenNeedleLongerThanHaystack() public pure {
        _assertAgrees("ab", "abc");
    }

    // --- realistic payloads -------------------------------------------------

    /// @dev The shape the library actually sees: a compact JWT payload searched for a claim needle.
    /// forge-config: default.fuzz.runs = 2000
    /// forge-config: deep.fuzz.runs = 25000
    function testFuzz_AgreesOnClaimShapedInput(uint64 repoId, address wallet) public pure {
        string memory id = Strings.toString(uint256(repoId));
        string memory audience = Strings.toHexString(uint160(wallet), 20);

        bytes memory payload = abi.encodePacked(
            '{"jti":"0","sub":"repo:octocat/Hello-World:ref:refs/heads/main","aud":"',
            audience,
            '","repository":"octocat/Hello-World","repository_owner_id":"583231","repository_id":"',
            id,
            '","actor_id":"583231","event_name":"workflow_dispatch",',
            '"job_workflow_ref":"octocat/Hello-World/.github/workflows/register-rik.yml@refs/heads/main"}'
        );

        _assertAgrees(payload, abi.encodePacked('"repository_id":"', id, '"'));
        _assertAgrees(payload, abi.encodePacked('"aud":"', audience, '"'));
        _assertAgrees(payload, '"repository_owner_id":"583231"');
        _assertAgrees(payload, '"event_name":"workflow_dispatch"');
        // The shorter key must not be satisfied by the longer one that contains it.
        _assertAgrees(payload, '"repository_id":"583231"');
        // A claim that is present but with a different value must still miss.
        _assertAgrees(payload, '"event_name":"issues"');
    }

    // --- claim assertions ---------------------------------------------------

    function test_RequireStringClaimAcceptsMatch() public view {
        harness.requireStringClaim('{"repository_id":"1296269"}', "repository_id", "1296269");
    }

    function test_RequireStringClaimRevertsWhenMissing() public {
        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMissing.selector, "repository_id"));
        harness.requireStringClaim('{"other":"1"}', "repository_id", "1296269");
    }

    function test_RequireStringClaimRevertsOnMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "repository_id"));
        harness.requireStringClaim('{"repository_id":"1"}', "repository_id", "1296269");
    }

    function test_RequireStringClaimIsNotPrefixMatched() public {
        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "repository_id"));
        harness.requireStringClaim('{"repository_id":"1296269"}', "repository_id", "129626");
    }

    function test_RequireStringClaimDistinguishesKeyPrefixes() public {
        // `repository_id` must not be satisfied by `repository_owner_id`, and vice versa.
        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMissing.selector, "repository_id"));
        harness.requireStringClaim('{"repository_owner_id":"583231"}', "repository_id", "583231");
    }

    /// @dev Error signatures match {JsonClaim}'s, so a decoder cannot tell which matcher reverted.
    function test_ErrorSelectorsMatchTheVendoredLibrary() public pure {
        assertEq(ClaimMatcher.ClaimMissing.selector, JsonClaim.ClaimMissing.selector);
        assertEq(ClaimMatcher.ClaimMismatch.selector, JsonClaim.ClaimMismatch.selector);
    }

    /// @dev The invariant the whole matcher rests on: a JSON encoder escapes `"` inside a value, so
    ///      attacker-controlled free text cannot contain the unescaped quote needed to forge a
    ///      neighbouring claim.
    function test_EscapedQuotesCannotForgeClaim() public {
        bytes memory payload = '{"workflow":"pwn\\",\\"repository_id\\":\\"999999","repository_id":"1296269"}';

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "repository_id"));
        harness.requireStringClaim(payload, "repository_id", "999999");
    }

    function test_EscapedQuotesLeaveRealClaimIntact() public view {
        bytes memory payload = '{"workflow":"pwn\\",\\"repository_id\\":\\"999999","repository_id":"1296269"}';

        harness.requireStringClaim(payload, "repository_id", "1296269");
    }
}
