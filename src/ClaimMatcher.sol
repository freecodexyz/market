// src/ClaimMatcher.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title ClaimMatcher
 * @notice Byte-oriented assertions over a compact JWT JSON payload.
 *
 * @dev This library does not parse JSON. It searches for the exact byte sequence `"<key>":"<value>"`.
 *      This is sound only because a JSON encoder escapes `"` inside string values as `\"`, so an
 *      attacker-controlled claim value (a repository name, a branch, a workflow name) cannot contain
 *      the unescaped quote needed to forge another claim. Any change to the matching strategy must
 *      preserve that property; see the injection regression tests.
 *
 *      # Relationship to {JsonClaim}
 *
 *      {JsonClaim} is a verbatim copy of the deployed `identity` source and must stay byte
 *      identical, because the {GithubOidcVerifier} vendored beside it is a live contract. This
 *      library implements the same matching semantics with a faster scan, and is what {RIK} links
 *      against.
 *
 *      Both are `internal`, so exactly one is inlined into `RIK`'s bytecode. Selecting this one does
 *      not widen the deployed surface; it determines which implementation is inlined. The
 *      differential suite compares it against {JsonClaim} and against a naive byte-at-a-time search.
 *
 *      Error signatures are identical to {JsonClaim}'s, so a caller decoding a revert does not need
 *      to know which produced it.
 */
library ClaimMatcher {
    error ClaimMissing(string claim);
    error ClaimMismatch(string claim);

    /**
     * @dev Returns the index of the first occurrence of `needle` in `hay`, or `-1` when absent.
     */
    function indexOf(bytes memory hay, bytes memory needle) internal pure returns (int256) {
        return indexOfFrom(hay, needle, 0);
    }

    /**
     * @dev Returns the index of an occurrence of `needle` in `hay`, or `-1` when absent.
     *
     * The scan begins at `start` and wraps to the beginning of the array, so every candidate
     * position is inspected and `-1` means absent from the whole array. `start` affects only which
     * occurrence is returned when there is more than one; at `start == 0` it is the first, which is
     * what {indexOf} depends on.
     *
     * Resuming exists so that a caller checking several claims against one payload does not rescan
     * from the beginning each time. Checking claims in the order they appear in the payload costs
     * one pass rather than one pass per claim. Correctness is independent of that order, because a
     * claim positioned before the cursor is found on the wrap.
     *
     * The scan uses Boyer-Moore-Horspool skipping; see {scan}. A surviving candidate is confirmed a
     * word at a time.
     *
     * The loads read up to 31 bytes past the end of `hay` and `needle`. Those bytes are masked off
     * before comparison and cannot affect the result. Memory beyond a `bytes` array is readable and
     * this routine never writes, but the out-of-bounds read is why the block below must not be
     * marked `memory-safe`.
     */
    function indexOfFrom(bytes memory hay, bytes memory needle, uint256 start) internal pure returns (int256 result) {
        uint256 hayLen = hay.length;
        uint256 needleLen = needle.length;
        if (needleLen == 0 || hayLen < needleLen) return -1;

        // Bounds `hayPtr + start` for any caller-supplied value. A start past the end means the
        // entire scan happens on the wrap.
        if (start > hayLen) start = hayLen;

        result = -1;

        assembly {
            let hayPtr := add(hay, 0x20)
            let needlePtr := add(needle, 0x20)

            // Selects the leading min(needleLen, 32) bytes of a word.
            let head := needleLen
            if gt(head, 0x20) { head := 0x20 }
            let mask := not(0)
            if lt(head, 0x20) { mask := shl(shl(3, sub(0x20, head)), not(0)) }

            let firstWord := and(mload(needlePtr), mask)
            let last := add(hayPtr, sub(hayLen, needleLen))

            // Compares the words after the first. Only reached once the first word has matched.
            function tailMatches(p, nPtr, nLen) -> ok {
                ok := 1
                for { let off := 0x20 } lt(off, nLen) { off := add(off, 0x20) } {
                    let rem := sub(nLen, off)
                    let tailMask := not(0)
                    if lt(rem, 0x20) { tailMask := shl(shl(3, sub(0x20, rem)), not(0)) }

                    if iszero(eq(and(mload(add(p, off)), tailMask), and(mload(add(nPtr, off)), tailMask))) {
                        ok := 0
                        break
                    }
                }
            }

            // One set bit per byte value occurring in the needle. The scan uses it to skip a full
            // needle length at a time.
            //
            // The final word read extends up to 31 bytes past the needle, so bytes not belonging to
            // it may also be set. Only extra bits can result, never missing ones, and an extra bit
            // makes the scan advance one position instead of many. A missing bit would allow a
            // position to be skipped incorrectly, so the map must never be narrowed.
            function charBitmap(nPtr, nLen) -> bm {
                bm := 0
                for { let i := 0 } lt(i, nLen) { i := add(i, 0x20) } {
                    let w := mload(add(nPtr, i))
                    bm := or(bm, shl(byte(0, w), 1))
                    bm := or(bm, shl(byte(1, w), 1))
                    bm := or(bm, shl(byte(2, w), 1))
                    bm := or(bm, shl(byte(3, w), 1))
                    bm := or(bm, shl(byte(4, w), 1))
                    bm := or(bm, shl(byte(5, w), 1))
                    bm := or(bm, shl(byte(6, w), 1))
                    bm := or(bm, shl(byte(7, w), 1))
                    bm := or(bm, shl(byte(8, w), 1))
                    bm := or(bm, shl(byte(9, w), 1))
                    bm := or(bm, shl(byte(10, w), 1))
                    bm := or(bm, shl(byte(11, w), 1))
                    bm := or(bm, shl(byte(12, w), 1))
                    bm := or(bm, shl(byte(13, w), 1))
                    bm := or(bm, shl(byte(14, w), 1))
                    bm := or(bm, shl(byte(15, w), 1))
                    bm := or(bm, shl(byte(16, w), 1))
                    bm := or(bm, shl(byte(17, w), 1))
                    bm := or(bm, shl(byte(18, w), 1))
                    bm := or(bm, shl(byte(19, w), 1))
                    bm := or(bm, shl(byte(20, w), 1))
                    bm := or(bm, shl(byte(21, w), 1))
                    bm := or(bm, shl(byte(22, w), 1))
                    bm := or(bm, shl(byte(23, w), 1))
                    bm := or(bm, shl(byte(24, w), 1))
                    bm := or(bm, shl(byte(25, w), 1))
                    bm := or(bm, shl(byte(26, w), 1))
                    bm := or(bm, shl(byte(27, w), 1))
                    bm := or(bm, shl(byte(28, w), 1))
                    bm := or(bm, shl(byte(29, w), 1))
                    bm := or(bm, shl(byte(30, w), 1))
                    bm := or(bm, shl(byte(31, w), 1))
                }
            }

            // Scans candidate positions `from..to` inclusive. Returns the match position plus one,
            // so that zero denotes "absent" without colliding with a match at position zero.
            //
            // Boyer-Moore-Horspool: examine the haystack byte that the last byte of the needle
            // would align with. If that byte does not occur in the needle, no alignment covering it
            // can match, so every start position up to and including it can be skipped, which is a
            // full needle length. Claim needles are 20 to 90 bytes over a narrow alphabet, so most
            // positions in a JWT payload are skipped rather than compared.
            function scan(from, to, nPtr, nLen, hmask, fw, bm) -> hit {
                hit := 0
                if gt(from, to) { leave }

                let lastOffset := sub(nLen, 1)
                let p := from
                for {} iszero(gt(p, to)) {} {
                    let c := byte(0, mload(add(p, lastOffset)))

                    switch and(shr(c, bm), 1)
                    case 0 {
                        // Not in the needle, so no alignment covering this byte can match.
                        p := add(p, nLen)
                    }
                    default {
                        if eq(and(mload(p), hmask), fw) {
                            if tailMatches(p, nPtr, nLen) {
                                hit := add(p, 1)
                                leave
                            }
                        }
                        p := add(p, 1)
                    }
                }
            }

            let from := add(hayPtr, start)
            let bitmap := charBitmap(needlePtr, needleLen)

            let hit := 0
            if iszero(gt(from, last)) {
                hit := scan(from, last, needlePtr, needleLen, mask, firstWord, bitmap)
            }

            // Wrap: positions below the cursor have not been examined yet.
            if and(iszero(hit), gt(from, hayPtr)) {
                let upper := sub(from, 1)
                if gt(upper, last) { upper := last }
                hit := scan(hayPtr, upper, needlePtr, needleLen, mask, firstWord, bitmap)
            }

            if hit { result := sub(sub(hit, 1), hayPtr) }
        }
    }

    /**
     * @dev Asserts the bytes for `"<key>":"<expectedValue>"` are present in `payload`.
     *
     * Requirements:
     *
     * - `payload` must contain `key`.
     * - The value of `key` must equal `expectedValue`.
     */
    function requireStringClaim(bytes memory payload, string memory key, string memory expectedValue) internal pure {
        requireStringClaimFrom(payload, key, expectedValue, 0);
    }

    /**
     * @dev {requireStringClaim}, resuming the scan at `start`, and returning where the match ended
     *      so the next claim can carry on from there.
     *
     * This asserts presence only, and the wrap in {indexOfFrom} keeps the search exhaustive, so
     * threading the returned cursor through several claims affects gas but not the result.
     *
     * Requirements:
     *
     * - `payload` must contain `key`.
     * - The value of `key` must equal `expectedValue`.
     */
    function requireStringClaimFrom(bytes memory payload, string memory key, string memory expectedValue, uint256 start)
        internal
        pure
        returns (uint256 next)
    {
        bytes memory needle = abi.encodePacked('"', bytes(key), '":"', bytes(expectedValue), '"');

        int256 position = indexOfFrom(payload, needle, start);
        if (position >= 0) {
            // Safe: a non-negative index, plus a length, both bounded by the payload.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint256(position) + needle.length;
        }

        // Starting from zero keeps the distinction between the two failure reasons independent of
        // the cursor position.
        bytes memory claim = abi.encodePacked('"', bytes(key), '":');
        if (indexOf(payload, claim) < 0) revert ClaimMissing(key);

        revert ClaimMismatch(key);
    }
}
