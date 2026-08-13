// test/JsonClaimDifferential.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {JsonClaim} from "../src/JsonClaim.sol";

/**
 * @dev The byte-at-a-time search {JsonClaim-indexOf} replaced, kept verbatim as an oracle.
 *
 * Straightforwardly correct and slow. Do not optimise it, and do not let it share code with the
 * implementation under test.
 */
library ReferenceSearch {
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

/**
 * @dev Differential regression guard for the hand-written assembly in {JsonClaim-indexOf}.
 *
 * The rest of the suite pins the behaviour the contracts rely on. This file pins something
 * narrower and more fragile: that a word-at-a-time search with masked loads agrees with a naive
 * byte-at-a-time one on every input, including the word boundaries where the masking is easiest to
 * get wrong. It exists because that routine dominates `register` gas and will be tempting to edit.
 */
contract JsonClaimDifferential_T is Test {
    /// @dev Padding long enough that a sliced needle can straddle several word boundaries.
    bytes constant FILLER =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    function _assertAgrees(bytes memory hay, bytes memory needle) internal pure {
        assertEq(JsonClaim.indexOf(hay, needle), ReferenceSearch.indexOf(hay, needle));
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
    function testFuzz_AgreesOnArbitraryInput(bytes memory hay, bytes memory needle) public pure {
        _assertAgrees(hay, needle);
    }

    /// @dev Guarantees a hit, so the index itself is compared rather than just "not found".
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_AgreesOnPlantedNeedle(bytes memory prefix, bytes memory needle, bytes memory suffix) public pure {
        _assertAgrees(bytes.concat(prefix, needle, suffix), needle);
    }

    // --- word boundaries ----------------------------------------------------

    /// @dev Needles sliced out of the haystack at a fuzzed offset and length. This is where a
    ///      masked word comparison goes wrong: partial first words, partial tail words, and
    ///      candidate positions that are not word aligned.
    /// forge-config: default.fuzz.runs = 5000
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

    function test_AgreesWhenNeedleIsWholeHaystack() public pure {
        _assertAgrees(FILLER, FILLER);
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

    // --- realistic payloads -------------------------------------------------

    /// @dev The shape the library actually sees: a compact JWT payload searched for a claim needle.
    /// forge-config: default.fuzz.runs = 2000
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
        _assertAgrees(payload, abi.encodePacked('"repository_id":"583231"'));
        // A claim that is present but with a different value must still miss.
        _assertAgrees(payload, '"event_name":"issues"');
    }
}
