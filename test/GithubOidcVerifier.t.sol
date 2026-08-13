// test/GithubOidcVerifier.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {GithubOidcVerifier} from "../src/GithubOidcVerifier.sol";
import {JsonClaim} from "../src/JsonClaim.sol";
import {OidcFixture} from "./OidcFixture.sol";

contract GithubOidcVerifier_T is OidcFixture {
    bytes1 constant _OPEN_BRACE = hex"7b";
    bytes1 constant _CLOSE_BRACE = hex"7d";

    GithubOidcVerifier verifier;

    address owner = address(this);
    address stranger = address(0xBAD);

    function setUp() public {
        verifier = new GithubOidcVerifier(owner);
    }

    function _addKey(Fixture memory f) internal {
        verifier.addKey(f.kid, f.modulus, f.exponent);
    }

    function _verify(Fixture memory f) internal view returns (bytes memory) {
        return verifier.verifyGithubOidc(f.kid, f.headerB64, f.payloadB64, f.signature);
    }

    // --- configuration -----------------------------------------------------

    function test_ExpectedIssuer() public view {
        assertEq(verifier.expectedIssuer(), "https://token.actions.githubusercontent.com");
    }

    function test_OwnerIsInitialOwner() public view {
        assertEq(verifier.owner(), owner);
    }

    // --- key registry ------------------------------------------------------

    function test_AddKeyStoresKey() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        GithubOidcVerifier.RSAKey memory key = verifier.keyOf(f.kid);
        assertTrue(key.active);
        assertEq(key.modulus, f.modulus);
        assertEq(key.exponent, f.exponent);
    }

    function test_AddKeyEmitsKeyAdded() public {
        Fixture memory f = _fixture("sample-jwt.json");

        vm.expectEmit(true, false, false, false);
        emit GithubOidcVerifier.KeyAdded(f.kid);
        _addKey(f);
    }

    function test_AddKeyReplacesExistingKey() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        bytes memory replacement = hex"deadbeef";
        verifier.addKey(f.kid, replacement, replacement);

        assertEq(verifier.keyOf(f.kid).modulus, replacement);
    }

    function test_AddKeyRejectsEmptyModulus() public {
        Fixture memory f = _fixture("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(GithubOidcVerifier.InvalidKey.selector, f.kid));
        verifier.addKey(f.kid, "", f.exponent);
    }

    function test_AddKeyRejectsEmptyExponent() public {
        Fixture memory f = _fixture("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(GithubOidcVerifier.InvalidKey.selector, f.kid));
        verifier.addKey(f.kid, f.modulus, "");
    }

    function test_AddKeyOnlyOwner() public {
        Fixture memory f = _fixture("sample-jwt.json");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        verifier.addKey(f.kid, f.modulus, f.exponent);
    }

    function test_RevokeKeyDeactivates() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        vm.expectEmit(true, false, false, false);
        emit GithubOidcVerifier.KeyRevoked(f.kid);
        verifier.revokeKey(f.kid);

        assertFalse(verifier.keyOf(f.kid).active);
    }

    function test_RevokeKeyKeepsMaterialAuditable() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);
        verifier.revokeKey(f.kid);

        // The key stays readable after revocation so past verifications remain explainable.
        assertEq(verifier.keyOf(f.kid).modulus, f.modulus);
        assertEq(verifier.keyOf(f.kid).exponent, f.exponent);
    }

    function test_RevokeKeyRejectsUnknownKid() public {
        bytes32 kid = keccak256("never-added");

        vm.expectRevert(abi.encodeWithSelector(GithubOidcVerifier.UnknownKid.selector, kid));
        verifier.revokeKey(kid);
    }

    function test_RevokeKeyRejectsDoubleRevoke() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);
        verifier.revokeKey(f.kid);

        vm.expectRevert(abi.encodeWithSelector(GithubOidcVerifier.UnknownKid.selector, f.kid));
        verifier.revokeKey(f.kid);
    }

    function test_RevokeKeyOnlyOwner() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        verifier.revokeKey(f.kid);
    }

    function test_AddKeyRestoresRevokedKid() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);
        verifier.revokeKey(f.kid);
        _addKey(f);

        assertTrue(verifier.keyOf(f.kid).active);
    }

    // --- verification ------------------------------------------------------

    function test_VerifyReturnsDecodedPayload() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        bytes memory payload = _verify(f);

        // The decoded payload must be the JSON object the claim matcher scans.
        assertGt(payload.length, 0);
        assertEq(payload[0], _OPEN_BRACE);
        assertEq(payload[payload.length - 1], _CLOSE_BRACE);
    }

    function test_RejectsUnknownKid() public {
        Fixture memory f = _fixture("sample-jwt.json");
        bytes32 wrongKid = keccak256("kid-zzz");

        vm.expectRevert(abi.encodeWithSelector(GithubOidcVerifier.UnknownKid.selector, wrongKid));
        verifier.verifyGithubOidc(wrongKid, f.headerB64, f.payloadB64, f.signature);
    }

    function test_RejectsRevokedKid() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);
        verifier.revokeKey(f.kid);

        vm.expectRevert(abi.encodeWithSelector(GithubOidcVerifier.UnknownKid.selector, f.kid));
        _verify(f);
    }

    function test_RejectsTamperedSignature() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        f.signature[0] = bytes1(uint8(f.signature[0]) ^ 1);

        vm.expectRevert(GithubOidcVerifier.BadJwt.selector);
        _verify(f);
    }

    function test_RejectsTamperedPayload() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        // Flipping any payload byte breaks the signed digest.
        f.payloadB64[10] = bytes1(uint8(f.payloadB64[10]) ^ 1);

        vm.expectRevert(GithubOidcVerifier.BadJwt.selector);
        _verify(f);
    }

    function test_RejectsTamperedHeader() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        f.headerB64[5] = bytes1(uint8(f.headerB64[5]) ^ 1);

        vm.expectRevert(GithubOidcVerifier.BadJwt.selector);
        _verify(f);
    }

    function test_RejectsWrongIssuer() public {
        Fixture memory f = _fixture("wrong-issuer-jwt.json");
        _addKey(f);

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "iss"));
        _verify(f);
    }

    function test_RejectsMissingExp() public {
        Fixture memory f = _fixture("missing-exp-jwt.json");
        _addKey(f);

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMissing.selector, "exp"));
        _verify(f);
    }

    function test_RejectsMissingNbf() public {
        Fixture memory f = _fixture("missing-nbf-jwt.json");
        _addKey(f);

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMissing.selector, "nbf"));
        _verify(f);
    }

    function test_RejectsExpired() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        vm.warp(f.exp + 1);
        vm.expectRevert(GithubOidcVerifier.TokenExpired.selector);
        _verify(f);
    }

    function test_AcceptsAtExactExpiry() public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        // `exp` is inclusive: rejection starts one second later.
        vm.warp(f.exp);
        _verify(f);
    }

    function test_RejectsNotYetValid() public {
        Fixture memory f = _fixture("future-nbf-jwt.json");
        _addKey(f);

        vm.warp(f.nbf - 1);
        vm.expectRevert(GithubOidcVerifier.TokenNotYetValid.selector);
        _verify(f);
    }

    function test_AcceptsAtExactNbf() public {
        Fixture memory f = _fixture("future-nbf-jwt.json");
        _addKey(f);

        vm.warp(f.nbf);
        _verify(f);
    }

    // --- fuzz --------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_RejectsAnyUnregisteredKid(bytes32 kid) public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);
        vm.assume(kid != f.kid);

        vm.expectRevert(abi.encodeWithSelector(GithubOidcVerifier.UnknownKid.selector, kid));
        verifier.verifyGithubOidc(kid, f.headerB64, f.payloadB64, f.signature);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_RejectsAnySignatureBitFlip(uint256 index, uint8 mask) public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        vm.assume(mask != 0);
        index = bound(index, 0, f.signature.length - 1);
        f.signature[index] = bytes1(uint8(f.signature[index]) ^ mask);

        vm.expectRevert(GithubOidcVerifier.BadJwt.selector);
        _verify(f);
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_RejectsOutsideActiveWindow(uint256 timestamp) public {
        Fixture memory f = _fixture("sample-jwt.json");
        _addKey(f);

        timestamp = bound(timestamp, f.exp + 1, type(uint64).max);
        vm.warp(timestamp);

        vm.expectRevert(GithubOidcVerifier.TokenExpired.selector);
        _verify(f);
    }
}
