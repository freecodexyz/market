// test/DopplerPoolKey.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DopplerPoolKey} from "../src/DopplerPoolKey.sol";
import {PoolKey} from "../src/IDopplerHookInitializer.sol";

contract DopplerPoolKey_T is Test {
    /// @dev Both actual ABI layouts must recover every pool-key bit, independently of sale data.
    function testFuzz_DecodesBothInitializerFamilies(
        PoolKey memory key,
        address numeraire,
        uint8 status,
        int24 farTick,
        uint256 tokens,
        address hook,
        bytes memory graduationData
    ) public pure {
        bytes memory multicurve = abi.encode(numeraire, status, key, farTick);
        bytes memory dopplerHook = abi.encode(numeraire, tokens, hook, graduationData, status, key, farTick);
        bytes memory expected = abi.encode(key);
        assertEq(abi.encode(DopplerPoolKey.decode(multicurve)), expected);
        assertEq(abi.encode(DopplerPoolKey.decode(dopplerHook)), expected);
    }

    /// @dev A truncated static state must never be interpreted as a valid pool identity.
    function testFuzz_RejectsTruncatedMulticurveState(PoolKey memory key, uint8 length) public {
        bytes memory encoded = abi.encode(address(1), uint8(2), key, int24(0));
        bytes memory truncated = new bytes(length);
        for (uint256 i; i < length; ++i) {
            truncated[i] = encoded[i];
        }
        vm.expectRevert();
        this.decode(truncated);
    }

    /// @dev Neither ABI family may accept a noncanonical address, uint24 fee or int24 spacing.
    function testFuzz_RejectsInvalidPoolKey(uint256 invalid, uint8 field, bool multicurve) public {
        field = uint8(bound(field, 0, 4));
        uint256[5] memory words;
        if (field == 2) {
            invalid = bound(invalid, uint256(type(uint24).max) + 1, type(uint256).max);
        } else if (field == 3) {
            invalid = bound(
                invalid, uint256(uint24(type(int24).max)) + 1, type(uint256).max - uint256(uint24(type(int24).max)) - 1
            );
        } else {
            invalid = bound(invalid, uint256(type(uint160).max) + 1, type(uint256).max);
        }
        words[field] = invalid;
        bytes memory encoded = multicurve
            ? abi.encode(address(1), uint8(2), words, int24(0))
            : abi.encode(address(1), uint256(0), address(0), bytes(""), uint8(2), words, int24(0));
        vm.expectRevert();
        this.decode(encoded);
    }

    /// @dev An external boundary lets the tests assert ABI-decoding reverts.
    function decode(bytes memory state) external pure returns (PoolKey memory) {
        return DopplerPoolKey.decode(state);
    }
}
