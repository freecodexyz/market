// test/RIKTextEncoding.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Test} from "forge-std/Test.sol";

import {IJwtVerifier} from "../src/IJwtVerifier.sol";
import {RIK} from "../src/RIK.sol";

/// @dev Exposes the internal encoders, and allocates after them so the free pointer can be checked.
contract TextHarness is RIK {
    constructor() RIK(address(0xA11CE), IJwtVerifier(address(0xBEEF))) {}

    function decimalText(uint256 value) external pure returns (string memory) {
        return _decimalText(value);
    }

    function addressText(address wallet) external pure returns (string memory) {
        return _addressText(wallet);
    }

    /// @dev The readable form {audienceOf} replaced. Kept here rather than in the contract so the
    ///      optimised path can be compared against it without deploying both.
    function readableAudience(address wallet, uint256 repoId, uint256 ownerId) external pure returns (string memory) {
        return string.concat(_addressText(wallet), ":", Strings.toString(repoId), ":", Strings.toString(ownerId));
    }

    /// @dev Encodes, then allocates, and returns both. If the builder mismanaged the free memory
    ///      pointer the two would overlap and the first would be corrupted.
    function audienceThenAllocate(address wallet, uint256 repoId, uint256 ownerId, uint256 filler)
        external
        pure
        returns (string memory audience, bytes memory allocated)
    {
        audience = audienceOf(wallet, repoId, ownerId);
        allocated = new bytes(filler);
        for (uint256 i = 0; i < filler; ++i) {
            allocated[i] = 0xFF;
        }
    }

    function decimalThenAllocate(uint256 value, uint256 filler)
        external
        pure
        returns (string memory text, bytes memory allocated)
    {
        text = _decimalText(value);
        allocated = new bytes(filler);
        for (uint256 i = 0; i < filler; ++i) {
            allocated[i] = 0xFF;
        }
    }
}

/**
 * @dev Differential guard for the hand-written text encoders on the registration path.
 *
 * {RIK-audienceOf} and {RIK-_decimalText} exist only to be cheaper than the readable form, so the
 * requirement is that they are indistinguishable from it. A malformed audience would fail every
 * registration; an incorrect audience that still parses is the case these tests target, because the
 * audience carries the entire claim.
 */
contract RIKTextEncoding_T is Test {
    TextHarness harness;

    address alice = address(0x1111111111111111111111111111111111111111);

    function setUp() public {
        harness = new TextHarness();
    }

    // --- decimal ------------------------------------------------------------

    function test_DecimalTextHandlesZero() public view {
        assertEq(harness.decimalText(0), "0");
    }

    function test_DecimalTextHandlesMaxUint256() public view {
        assertEq(harness.decimalText(type(uint256).max), Strings.toString(type(uint256).max));
        assertEq(bytes(harness.decimalText(type(uint256).max)).length, 78);
    }

    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: deep.fuzz.runs = 250000
    function testFuzz_DecimalTextMatchesStrings(uint256 value) public view {
        assertEq(harness.decimalText(value), Strings.toString(value));
    }

    /// forge-config: default.fuzz.runs = 256
    /// forge-config: deep.fuzz.runs = 25000
    function testFuzz_DecimalTextLeavesTheFreePointerConsistent(uint256 value, uint8 filler) public view {
        (string memory text, bytes memory allocated) = harness.decimalThenAllocate(value, filler);

        assertEq(text, Strings.toString(value));
        assertEq(allocated.length, filler);
    }

    // --- audience -----------------------------------------------------------

    function test_AudienceMatchesTheDocumentedShape() public view {
        assertEq(
            harness.audienceOf(alice, 1296269, 583231), "0x1111111111111111111111111111111111111111:1296269:583231"
        );
    }

    function test_AudienceHandlesZeroes() public view {
        assertEq(harness.audienceOf(address(0), 0, 0), "0x0000000000000000000000000000000000000000:0:0");
    }

    function test_AudienceHandlesMaximums() public view {
        assertEq(
            harness.audienceOf(address(type(uint160).max), type(uint256).max, type(uint256).max),
            harness.readableAudience(address(type(uint160).max), type(uint256).max, type(uint256).max)
        );
    }

    /// @dev The fused builder must be indistinguishable from the four-allocation version.
    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: deep.fuzz.runs = 250000
    function testFuzz_AudienceIsTheConcatenation(address wallet, uint256 repoId, uint256 ownerId) public view {
        assertEq(harness.audienceOf(wallet, repoId, ownerId), harness.readableAudience(wallet, repoId, ownerId));
    }

    /// @dev Two different triples must never render identically, or one proof would satisfy a
    ///      different claim.
    /// forge-config: default.fuzz.runs = 1024
    /// forge-config: deep.fuzz.runs = 50000
    function testFuzz_DistinctTriplesRenderDistinctly(
        address walletA,
        uint64 repoA,
        uint64 ownerA,
        address walletB,
        uint64 repoB,
        uint64 ownerB
    ) public view {
        vm.assume(walletA != walletB || repoA != repoB || ownerA != ownerB);

        assertNotEq(harness.audienceOf(walletA, repoA, ownerA), harness.audienceOf(walletB, repoB, ownerB));
    }

    /// @dev Checks the `memory-safe` annotation: a later allocation must not overlap.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: deep.fuzz.runs = 25000
    function testFuzz_AudienceLeavesTheFreePointerConsistent(
        address wallet,
        uint64 repoId,
        uint64 ownerId,
        uint8 filler
    ) public view {
        (string memory audience, bytes memory allocated) = harness.audienceThenAllocate(wallet, repoId, ownerId, filler);

        assertEq(audience, harness.readableAudience(wallet, repoId, ownerId));
        assertEq(allocated.length, filler);
    }
}
