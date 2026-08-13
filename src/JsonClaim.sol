// src/JsonClaim.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title JsonClaim
 * @notice Byte-oriented assertions over a compact JWT JSON payload.
 *
 * @dev This library never parses JSON. It searches for the exact byte sequence `"<key>":"<value>"`.
 *      That is sound only because a JSON encoder escapes `"` inside string values as `\"`, so an
 *      attacker-controlled claim value (a repository name, a branch, a workflow name) cannot contain
 *      the unescaped quote needed to forge another claim. Any change to the matching strategy must
 *      preserve that property; see the injection regression tests.
 */
library JsonClaim {
    error ClaimMissing(string claim);
    error ClaimMismatch(string claim);

    /**
     * @dev Returns the index of the first occurrence of `needle` in `hay`, or `-1` when absent.
     *
     * Still the naive O(n*m) search, but comparing 32 bytes per step instead of one. Every
     * candidate position is rejected by a single masked word comparison, and the remaining words
     * are only touched once that first one matches, which for a JWT payload is almost never.
     *
     * The loads deliberately read up to 31 bytes past the end of `hay` and `needle`. Those bytes
     * are always masked off before comparison, so they cannot affect the result; memory beyond a
     * `bytes` array is readable, and this routine never writes.
     */
    function indexOf(bytes memory hay, bytes memory needle) internal pure returns (int256) {
        uint256 hayLen = hay.length;
        uint256 needleLen = needle.length;
        if (needleLen == 0 || hayLen < needleLen) return -1;

        int256 result = -1;

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

            for { let p := hayPtr } iszero(gt(p, last)) { p := add(p, 1) } {
                if eq(and(mload(p), mask), firstWord) {
                    let matched := 1
                    for { let off := 0x20 } lt(off, needleLen) { off := add(off, 0x20) } {
                        let rem := sub(needleLen, off)
                        let tailMask := not(0)
                        if lt(rem, 0x20) { tailMask := shl(shl(3, sub(0x20, rem)), not(0)) }

                        if iszero(eq(and(mload(add(p, off)), tailMask), and(mload(add(needlePtr, off)), tailMask))) {
                            matched := 0
                            break
                        }
                    }

                    if matched {
                        result := sub(p, hayPtr)
                        break
                    }
                }
            }
        }

        return result;
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
