// test/RIKAudience.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Test} from "forge-std/Test.sol";

import {IJwtVerifier} from "../src/IJwtVerifier.sol";
import {RIK} from "../src/RIK.sol";

/// @dev Exposes the internal encoder, and allocates after it so the free pointer can be checked.
///      The verifier is never called here, but it cannot be the zero address: {RIK} rejects that.
contract AudienceHarness is RIK {
    constructor() RIK(address(0xA11CE), IJwtVerifier(address(0xBEEF))) {}

    function audienceOf(address wallet) external pure returns (string memory) {
        return _addressText(wallet);
    }

    /// @dev The implementation being replaced, behind the same call boundary so the two can be
    ///      compared on gas without the comparison being dominated by call overhead.
    function stringsAudienceOf(address wallet) external pure returns (string memory) {
        return Strings.toHexString(uint160(wallet), 20);
    }

    /// @dev Encodes, then allocates a second value, and returns both. If the encoder mismanaged the
    ///      free memory pointer the two would overlap and the first would come back corrupted.
    function audienceThenAllocate(address wallet, uint256 filler)
        external
        pure
        returns (string memory audience, bytes memory allocated)
    {
        audience = _addressText(wallet);
        allocated = new bytes(filler);
        for (uint256 i = 0; i < filler; ++i) {
            allocated[i] = 0xFF;
        }
    }
}

/**
 * @dev Differential guard for {RIK-_audienceOf}.
 *
 * It replaces `Strings.toHexString(uint160(wallet), 20)` purely for gas, so the only thing that
 * matters is that it is indistinguishable from it. A wrong `aud` encoding would not be a subtle
 * defect: every registration would fail, or worse, two different wallets could render alike.
 */
contract RIKAudience_T is Test {
    AudienceHarness harness;

    function setUp() public {
        harness = new AudienceHarness();
    }

    function _expected(address wallet) internal pure returns (string memory) {
        return Strings.toHexString(uint160(wallet), 20);
    }

    function test_MatchesStringsForZeroAddress() public view {
        assertEq(harness.audienceOf(address(0)), _expected(address(0)));
        assertEq(harness.audienceOf(address(0)), "0x0000000000000000000000000000000000000000");
    }

    function test_MatchesStringsForMaximumAddress() public view {
        address max = address(type(uint160).max);
        assertEq(harness.audienceOf(max), _expected(max));
        assertEq(harness.audienceOf(max), "0xffffffffffffffffffffffffffffffffffffffff");
    }

    /// @dev The fixture wallet the whole suite registers with.
    function test_MatchesStringsForFixtureWallet() public view {
        address wallet = address(0x1111111111111111111111111111111111111111);
        assertEq(harness.audienceOf(wallet), "0x1111111111111111111111111111111111111111");
    }

    /// @dev Lowercase, because that is what the workflow requests as its audience.
    function test_IsLowercase() public view {
        address wallet = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);
        assertEq(harness.audienceOf(wallet), "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd");
    }

    function test_LengthIsAlwaysFortyTwo() public view {
        assertEq(bytes(harness.audienceOf(address(1))).length, 42);
        assertEq(bytes(harness.audienceOf(address(0))).length, 42);
    }

    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: deep.fuzz.runs = 250000
    function testFuzz_MatchesStrings(address wallet) public view {
        assertEq(harness.audienceOf(wallet), _expected(wallet));
    }

    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 25000
    function testFuzz_DistinctWalletsRenderDistinctly(address a, address b) public view {
        vm.assume(a != b);
        assertNotEq(harness.audienceOf(a), harness.audienceOf(b));
    }

    /// @dev Proves the `memory-safe` annotation is earned: a later allocation must not overlap.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: deep.fuzz.runs = 25000
    function testFuzz_LeavesTheFreeMemoryPointerConsistent(address wallet, uint8 filler) public view {
        (string memory audience, bytes memory allocated) = harness.audienceThenAllocate(wallet, filler);

        assertEq(audience, _expected(wallet));
        assertEq(allocated.length, filler);
    }
}
