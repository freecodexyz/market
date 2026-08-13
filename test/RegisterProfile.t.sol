// test/RegisterProfile.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {console2} from "forge-std/console2.sol";

import {ClaimMatcher} from "../src/ClaimMatcher.sol";
import {GithubOidcVerifier} from "../src/GithubOidcVerifier.sol";
import {RIK} from "../src/RIK.sol";
import {OidcFixture} from "./OidcFixture.sol";
import {TextHarness} from "./RIKTextEncoding.t.sol";

/**
 * @dev Records why the registration path is shaped as it is.
 *
 * Two properties of `register` are intentional and would otherwise appear arbitrary: claims are
 * checked in the order GitHub emits them so the scan resumes rather than restarting, and the
 * audience is built in one pass rather than concatenated. Both exist only to reduce gas, so both are
 * asserted to be cheaper here. If either stops being cheaper, it should be removed.
 *
 * The assertions are relative, so a compiler upgrade that changes every number does not fail this.
 * The printed breakdown shows where registration gas is spent: most of it is RSA verification inside
 * the vendored verifier, which this repository does not own and must not fork.
 */
contract RegisterProfile_T is OidcFixture {
    uint64 constant ATTESTATION_REPO_ID = 900100200;
    string constant WORKFLOW_REF = "freecodexyz/market/.github/workflows/register-rik.yml@refs/heads/main";

    uint256 constant REPO_ID = 1296269;
    uint256 constant OWNER_ID = 583231;
    uint256 constant ACTOR_ID = 583231;

    GithubOidcVerifier verifier;
    RIK rik;
    TextHarness text;
    address alice = address(0x1111111111111111111111111111111111111111);

    function setUp() public {
        verifier = new GithubOidcVerifier(address(this));
        rik = new RIK(address(this), verifier);
        rik.setAttestationRepoId(ATTESTATION_REPO_ID);
        rik.setJobWorkflowRef(WORKFLOW_REF);
        text = new TextHarness();
    }

    /// @dev The exact sequence RIK runs, cursor and all.
    function _cursoredClaims(bytes memory payload, string memory aud) internal view returns (uint256 used) {
        uint256 g = gasleft();
        uint256 cursor;
        cursor = ClaimMatcher.requireStringClaimFrom(payload, "aud", aud, cursor);
        cursor = ClaimMatcher.requireStringClaimFrom(
            payload, "repository_id", Strings.toString(uint256(ATTESTATION_REPO_ID)), cursor
        );
        cursor = ClaimMatcher.requireStringClaimFrom(payload, "actor_id", Strings.toString(ACTOR_ID), cursor);
        cursor = ClaimMatcher.requireStringClaimFrom(payload, "event_name", "issues", cursor);
        ClaimMatcher.requireStringClaimFrom(payload, "job_workflow_ref", WORKFLOW_REF, cursor);
        used = g - gasleft();
    }

    /// @dev The same five without a cursor, for the comparison.
    function _restartingClaims(bytes memory payload, string memory aud) internal view returns (uint256 used) {
        uint256 g = gasleft();
        ClaimMatcher.requireStringClaim(payload, "aud", aud);
        ClaimMatcher.requireStringClaim(payload, "repository_id", Strings.toString(uint256(ATTESTATION_REPO_ID)));
        ClaimMatcher.requireStringClaim(payload, "actor_id", Strings.toString(ACTOR_ID));
        ClaimMatcher.requireStringClaim(payload, "event_name", "issues");
        ClaimMatcher.requireStringClaim(payload, "job_workflow_ref", WORKFLOW_REF);
        used = g - gasleft();
    }

    function test_Profile() public {
        Fixture memory f = _fixture("sample-jwt.json");
        verifier.addKey(f.kid, f.modulus, f.exponent);

        uint256 g = gasleft();
        bytes memory payload = verifier.verifyGithubOidc(f.kid, f.headerB64, f.payloadB64, f.signature);
        uint256 verifyGas = g - gasleft();

        string memory aud = rik.audienceOf(alice, REPO_ID, OWNER_ID);

        // Warm every path before measuring.
        _cursoredClaims(payload, aud);
        _restartingClaims(payload, aud);
        rik.audienceOf(alice, REPO_ID, OWNER_ID);
        Strings.toString(ACTOR_ID);

        uint256 cursored = _cursoredClaims(payload, aud);
        uint256 restarting = _restartingClaims(payload, aud);

        // Both measured through the same external boundary, so call overhead is included on both
        // sides of the comparison.
        text.audienceOf(alice, REPO_ID, OWNER_ID);
        text.readableAudience(alice, REPO_ID, OWNER_ID);

        g = gasleft();
        text.audienceOf(alice, REPO_ID, OWNER_ID);
        uint256 audienceGas = g - gasleft();

        g = gasleft();
        text.readableAudience(alice, REPO_ID, OWNER_ID);
        uint256 readableGas = g - gasleft();

        g = gasleft();
        Strings.toString(ACTOR_ID);
        uint256 toStringGas = g - gasleft();

        g = gasleft();
        rik.register(f.kid, f.headerB64, f.payloadB64, f.signature, REPO_ID, OWNER_ID, ACTOR_ID, alice);
        uint256 registerGas = g - gasleft();

        console2.log("payload bytes         ", payload.length);
        console2.log("register              ", registerGas);
        console2.log("  verifyGithubOidc    ", verifyGas);
        console2.log("  claims, cursored    ", cursored);
        console2.log("  claims, restarting  ", restarting);
        console2.log("  audience, fused     ", audienceGas);
        console2.log("  audience, readable  ", readableGas);
        console2.log("  toString            ", toStringGas);
        console2.log("  mint/storage/rest   ", registerGas - verifyGas - cursored);

        assertLt(cursored, restarting, "the resumable scan is no longer cheaper than restarting");
        assertLt(audienceGas, readableGas, "the fused audience builder is no longer cheaper than concatenating");
        assertGt(registerGas, verifyGas, "the verifier should still dominate a registration");
    }
}
