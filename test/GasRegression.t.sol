// test/GasRegression.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ClaimMatcher} from "../src/ClaimMatcher.sol";
import {GithubOidcVerifier} from "../src/GithubOidcVerifier.sol";
import {JsonClaim} from "../src/JsonClaim.sol";
import {RIK} from "../src/RIK.sol";
import {AudienceHarness} from "./RIKAudience.t.sol";
import {OidcFixture} from "./OidcFixture.sol";

/**
 * @dev Holds the two optimizations to the reason they were made.
 *
 * {ClaimMatcher} and {RIK-_audienceOf} are hand-written assembly that exists only to be cheaper than
 * a correct, audited alternative that is still sitting in the repository. Correctness is pinned
 * elsewhere, differentially. What is pinned here is the other half of the bargain: if either one
 * ever stops being faster than the thing it replaced, it has no reason to exist and should be
 * deleted rather than maintained.
 *
 * The assertions are relative rather than absolute, so a compiler or dependency upgrade that moves
 * every number does not produce a false failure.
 */
contract GasRegression_T is OidcFixture {
    uint256 constant REPO_ID = 1296269;
    uint256 constant OWNER_ID = 583231;

    GithubOidcVerifier verifier;
    RIK rik;
    AudienceHarness audience;

    address alice = address(0x1111111111111111111111111111111111111111);

    function setUp() public {
        verifier = new GithubOidcVerifier(address(this));
        rik = new RIK(verifier);
        audience = new AudienceHarness();
    }

    function _payload() internal returns (bytes memory) {
        Fixture memory f = _fixture("sample-jwt.json");
        verifier.addKey(f.kid, f.modulus, f.exponent);
        return verifier.verifyGithubOidc(f.kid, f.headerB64, f.payloadB64, f.signature);
    }

    /// @dev All four claims RIK checks, through the vendored matcher.
    function _vendoredClaims(bytes memory payload, string memory aud) internal view returns (uint256 used) {
        uint256 g = gasleft();
        JsonClaim.requireStringClaim(payload, "aud", aud);
        JsonClaim.requireStringClaim(payload, "repository_id", Strings.toString(REPO_ID));
        JsonClaim.requireStringClaim(payload, "repository_owner_id", Strings.toString(OWNER_ID));
        JsonClaim.requireStringClaim(payload, "event_name", "workflow_dispatch");
        used = g - gasleft();
    }

    /// @dev The same four, through the unrolled matcher RIK actually links against.
    function _unrolledClaims(bytes memory payload, string memory aud) internal view returns (uint256 used) {
        uint256 g = gasleft();
        ClaimMatcher.requireStringClaim(payload, "aud", aud);
        ClaimMatcher.requireStringClaim(payload, "repository_id", Strings.toString(REPO_ID));
        ClaimMatcher.requireStringClaim(payload, "repository_owner_id", Strings.toString(OWNER_ID));
        ClaimMatcher.requireStringClaim(payload, "event_name", "workflow_dispatch");
        used = g - gasleft();
    }

    function test_UnrolledMatcherIsCheaperThanTheVendoredOne() public {
        bytes memory payload = _payload();
        string memory aud = Strings.toHexString(uint160(alice), 20);

        // Warm both paths so the comparison is not measuring first-touch memory expansion.
        _vendoredClaims(payload, aud);
        _unrolledClaims(payload, aud);

        uint256 vendored = _vendoredClaims(payload, aud);
        uint256 unrolled = _unrolledClaims(payload, aud);

        console2.log("claims, vendored     ", vendored);
        console2.log("claims, unrolled     ", unrolled);
        assertLt(unrolled, vendored, "ClaimMatcher is no longer cheaper than JsonClaim");
    }

    function test_AudienceEncoderIsCheaperThanStrings() public view {
        // Warm both.
        audience.audienceOf(alice);
        audience.stringsAudienceOf(alice);

        uint256 g = gasleft();
        audience.audienceOf(alice);
        uint256 handWritten = g - gasleft();

        g = gasleft();
        audience.stringsAudienceOf(alice);
        uint256 library_ = g - gasleft();

        console2.log("audience, hand-written", handWritten);
        console2.log("audience, Strings     ", library_);
        assertLt(handWritten, library_, "_audienceOf is no longer cheaper than Strings.toHexString");
    }

    /// @dev Reports the split so a future reader can see what is worth attacking, and what is not.
    ///      Two thirds of a registration is RSA verification inside the vendored verifier, which
    ///      this repository does not own and must not fork.
    function test_ReportRegisterBreakdown() public {
        Fixture memory f = _fixture("sample-jwt.json");
        verifier.addKey(f.kid, f.modulus, f.exponent);

        uint256 g = gasleft();
        bytes memory payload = verifier.verifyGithubOidc(f.kid, f.headerB64, f.payloadB64, f.signature);
        uint256 verifyGas = g - gasleft();

        g = gasleft();
        rik.register(f.kid, f.headerB64, f.payloadB64, f.signature, REPO_ID, OWNER_ID, alice);
        uint256 registerGas = g - gasleft();

        console2.log("payload bytes        ", payload.length);
        console2.log("verifyGithubOidc     ", verifyGas);
        console2.log("register             ", registerGas);
        console2.log("verifier share, %    ", (verifyGas * 100) / registerGas);

        assertGt(registerGas, verifyGas);
    }
}
