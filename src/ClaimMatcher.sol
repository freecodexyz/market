// src/ClaimMatcher.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title ClaimMatcher
 * @notice Byte-oriented assertions over a compact JWT JSON payload.
 *
 * @dev This library never parses JSON. It searches for the exact byte sequence `"<key>":"<value>"`.
 *      That is sound only because a JSON encoder escapes `"` inside string values as `\"`, so an
 *      attacker-controlled claim value (a repository name, a branch, a workflow name) cannot contain
 *      the unescaped quote needed to forge another claim. Any change to the matching strategy must
 *      preserve that property; see the injection regression tests.
 *
 *      # Why this exists next to {JsonClaim}
 *
 *      {JsonClaim} is a verbatim copy of the deployed `identity` source and has to stay byte
 *      identical, because the {GithubOidcVerifier} vendored beside it is a live contract. This is
 *      the same matcher with the scan unrolled, and it is what {RIK} links against.
 *
 *      Both are `internal`, so exactly one of them is inlined into `RIK`'s bytecode. Using this one
 *      does not widen the deployed surface, it only changes which implementation is inlined; the
 *      differential suite pins it against {JsonClaim} and against a naive byte-at-a-time search on
 *      every input shape.
 *
 *      Error signatures are identical to {JsonClaim}'s, so callers and tooling decoding a revert do
 *      not have to care which one produced it.
 */
library ClaimMatcher {
    error ClaimMissing(string claim);
    error ClaimMismatch(string claim);

    /**
     * @dev Returns the index of the first occurrence of `needle` in `hay`, or `-1` when absent.
     *
     * Still the naive O(n*m) search, but comparing 32 bytes per step instead of one, and testing
     * four candidate positions per loop iteration. The comparison itself is four opcodes; without
     * the unrolling the loop's own bookkeeping and jumps cost more than the work they guard, and
     * this scan is the largest part of `register` that this repository actually owns.
     *
     * The loads deliberately read up to 31 bytes past the end of `hay` and `needle`. Those bytes
     * are always masked off before comparison, so they cannot affect the result; memory beyond a
     * `bytes` array is readable, and this routine never writes. That out-of-bounds read is also why
     * the block below must not be marked `memory-safe`.
     */
    function indexOf(bytes memory hay, bytes memory needle) internal pure returns (int256 result) {
        uint256 hayLen = hay.length;
        uint256 needleLen = needle.length;
        if (needleLen == 0 || hayLen < needleLen) return -1;

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

            // Confirms the words after the first one, and is only ever reached once the first has
            // matched, which for a JWT payload is almost never.
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

            let p := hayPtr
            let found := 0

            // `last` is a memory pointer past the array header, so it is always far above 3 and
            // this cannot underflow.
            let unrolledLimit := sub(last, 3)

            for {} iszero(gt(p, unrolledLimit)) {} {
                if eq(and(mload(p), mask), firstWord) {
                    if tailMatches(p, needlePtr, needleLen) {
                        found := 1
                        break
                    }
                }
                p := add(p, 1)

                if eq(and(mload(p), mask), firstWord) {
                    if tailMatches(p, needlePtr, needleLen) {
                        found := 1
                        break
                    }
                }
                p := add(p, 1)

                if eq(and(mload(p), mask), firstWord) {
                    if tailMatches(p, needlePtr, needleLen) {
                        found := 1
                        break
                    }
                }
                p := add(p, 1)

                if eq(and(mload(p), mask), firstWord) {
                    if tailMatches(p, needlePtr, needleLen) {
                        found := 1
                        break
                    }
                }
                p := add(p, 1)
            }

            // The one to three positions the unrolled loop could not cover.
            if iszero(found) {
                for {} iszero(gt(p, last)) { p := add(p, 1) } {
                    if eq(and(mload(p), mask), firstWord) {
                        if tailMatches(p, needlePtr, needleLen) {
                            found := 1
                            break
                        }
                    }
                }
            }

            if found { result := sub(p, hayPtr) }
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
        bytes memory needle = abi.encodePacked('"', bytes(key), '":"', bytes(expectedValue), '"');
        if (indexOf(payload, needle) >= 0) return;

        bytes memory claim = abi.encodePacked('"', bytes(key), '":');
        if (indexOf(payload, claim) < 0) revert ClaimMissing(key);

        revert ClaimMismatch(key);
    }
}
