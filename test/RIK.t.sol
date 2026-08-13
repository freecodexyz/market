// test/RIK.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

import {ClaimMatcher} from "../src/ClaimMatcher.sol";
import {GithubOidcVerifier} from "../src/GithubOidcVerifier.sol";
import {JsonClaim} from "../src/JsonClaim.sol";
import {RIK} from "../src/RIK.sol";
import {OidcFixture} from "./OidcFixture.sol";

contract RIK_T is OidcFixture {
    /// @dev Must match the defaults baked into `test/fixtures/load-fixture.mjs`.
    uint64 constant ATTESTATION_REPO_ID = 900100200;
    string constant WORKFLOW_REF = "freecodexyz/market/.github/workflows/register-rik.yml@refs/heads/main";

    /// @dev The repository being claimed, its owner, and the account opening the issue.
    uint64 constant REPO_ID = 1296269;
    uint64 constant OWNER_ID = 583231;
    uint64 constant ACTOR_ID = 583231;

    GithubOidcVerifier verifier;
    RIK rik;

    address owner = address(this);
    address stranger = address(0xBAD);
    address relayer = address(0xFEE);
    address alice = address(0x1111111111111111111111111111111111111111);
    address bob = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        verifier = new GithubOidcVerifier(owner);
        rik = new RIK(owner, verifier);
        rik.setAttestationRepoId(ATTESTATION_REPO_ID);
        rik.setJobWorkflowRef(WORKFLOW_REF);
    }

    function _addKey(Fixture memory f) internal {
        verifier.addKey(f.kid, f.modulus, f.exponent);
    }

    function _register(Fixture memory f, uint256 repoId, uint256 ownerId, uint256 actorId, address wallet) internal {
        rik.register(f.kid, f.headerB64, f.payloadB64, f.signature, repoId, ownerId, actorId, wallet);
    }

    /// @dev Loads a fixture and installs its signing key.
    function _ready(string memory name) internal returns (Fixture memory f) {
        f = _fixture(name);
        _addKey(f);
    }

    function _ready(string memory name, uint256 repoId, uint256 ownerId, uint256 actorId, address wallet)
        internal
        returns (Fixture memory f)
    {
        f = _fixture(name, repoId, ownerId, actorId, wallet);
        _addKey(f);
    }

    // --- metadata and configuration ----------------------------------------

    function test_NameAndSymbol() public view {
        assertEq(rik.name(), "Repository Identity Key");
        assertEq(rik.symbol(), "RIK");
    }

    /// @dev The only trigger that runs here while naming an external account as the actor.
    function test_ExpectedEventName() public view {
        assertEq(rik.expectedEventName(), "issues");
    }

    function test_JwtVerifierIsImmutable() public view {
        assertEq(address(rik.jwt()), address(verifier));
    }

    function test_AttestationSourceReads() public view {
        assertEq(rik.attestationRepoId(), ATTESTATION_REPO_ID);
        assertEq(rik.jobWorkflowRef(), WORKFLOW_REF);
    }

    /// @dev The one field a workflow controls, and therefore the whole claim being made.
    function test_AudienceEncoding() public view {
        assertEq(rik.audienceOf(alice, REPO_ID, OWNER_ID), "0x1111111111111111111111111111111111111111:1296269:583231");
    }

    /// @dev The contract and the fixture generator must agree on the encoding exactly, or every
    ///      registration in this suite would be passing for the wrong reason.
    function test_AudienceMatchesTheSignedToken() public {
        Fixture memory f = _fixture("sample-jwt.json");
        assertEq(rik.audienceOf(alice, REPO_ID, OWNER_ID), f.audience);
    }

    function test_TokenIdOfIsIdentity() public view {
        assertEq(rik.tokenIdOf(REPO_ID), REPO_ID);
    }

    function testFuzz_TokenIdOfIsIdentity(uint64 repoId) public view {
        assertEq(rik.tokenIdOf(repoId), uint256(repoId));
    }

    function test_SupportsExpectedInterfaces() public view {
        assertTrue(rik.supportsInterface(type(IERC165).interfaceId));
        assertTrue(rik.supportsInterface(type(IERC721).interfaceId));
        assertTrue(rik.supportsInterface(type(IERC721Metadata).interfaceId));
        assertFalse(rik.supportsInterface(bytes4(0xdeadbeef)));
    }

    // --- attestation source authority ---------------------------------------

    function test_SetAttestationRepoIdEmits() public {
        vm.expectEmit(true, false, false, false);
        emit RIK.AttestationRepoSet(42);
        rik.setAttestationRepoId(42);

        assertEq(rik.attestationRepoId(), 42);
    }

    function test_SetJobWorkflowRefEmits() public {
        vm.expectEmit(false, false, false, true);
        emit RIK.JobWorkflowRefSet("owner/repo/.github/workflows/x.yml@refs/heads/main");
        rik.setJobWorkflowRef("owner/repo/.github/workflows/x.yml@refs/heads/main");

        assertEq(rik.jobWorkflowRef(), "owner/repo/.github/workflows/x.yml@refs/heads/main");
    }

    function test_SetAttestationRepoIdOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rik.setAttestationRepoId(42);
    }

    function test_SetJobWorkflowRefOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rik.setJobWorkflowRef("x");
    }

    /// @dev The attestation source is the most powerful authority in the system, so handing it over
    ///      cannot be a single mistyped transaction.
    function test_OwnershipTransferIsTwoStep() public {
        rik.transferOwnership(stranger);
        assertEq(rik.owner(), owner);
        assertEq(rik.pendingOwner(), stranger);

        vm.prank(stranger);
        rik.acceptOwnership();
        assertEq(rik.owner(), stranger);
    }

    // --- registration happy path -------------------------------------------

    function test_RegisterMintsToAttestedWallet() public {
        Fixture memory f = _ready("sample-jwt.json");

        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        assertEq(rik.ownerOf(REPO_ID), alice);
        assertEq(rik.balanceOf(alice), 1);
        assertTrue(rik.isRegistered(REPO_ID));
    }

    /// @dev The whole point of the model: the repository owner opens an issue and somebody else
    ///      pays. The proof names its beneficiary, so the relayer cannot redirect the key.
    function test_RegisterIsPermissionless() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.prank(relayer);
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        assertEq(rik.ownerOf(REPO_ID), alice);
        assertEq(rik.balanceOf(relayer), 0);
    }

    function test_RegisterEmitsRepoRegistered() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.warp(1_700_000_000);
        vm.expectEmit(true, true, true, true);
        emit RIK.RepoRegistered(REPO_ID, alice, relayer, OWNER_ID, ACTOR_ID, 1_700_000_000);

        vm.prank(relayer);
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RegisterStoresRepo() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.warp(1_700_000_000);
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        RIK.Repo memory repo = rik.repoOf(REPO_ID);
        assertEq(repo.githubRepoId, REPO_ID);
        assertEq(repo.githubOwnerId, OWNER_ID);
        assertEq(repo.githubActorId, ACTOR_ID);
        assertEq(repo.registeredAt, 1_700_000_000);
    }

    /// @dev An organisation repository: the claimant is not the owner, which is exactly the case
    ///      the workflow has to resolve and the contract simply records.
    function test_RegisterRecordsAClaimantWhoIsNotTheOwner() public {
        uint64 orgId = 9919;
        uint64 memberId = 4242;
        Fixture memory f = _ready("sample-jwt.json", REPO_ID, orgId, memberId, alice);

        _register(f, REPO_ID, orgId, memberId, alice);

        RIK.Repo memory repo = rik.repoOf(REPO_ID);
        assertEq(repo.githubOwnerId, orgId);
        assertEq(repo.githubActorId, memberId);
        assertEq(rik.ownerOf(REPO_ID), alice);
    }

    function test_TwoRepositoriesGetDistinctTokens() public {
        Fixture memory first = _ready("sample-jwt.json", 111, OWNER_ID, ACTOR_ID, alice);
        Fixture memory second = _fixture("sample-jwt.json", 222, OWNER_ID, ACTOR_ID, bob);

        _register(first, 111, OWNER_ID, ACTOR_ID, alice);
        _register(second, 222, OWNER_ID, ACTOR_ID, bob);

        assertEq(rik.ownerOf(111), alice);
        assertEq(rik.ownerOf(222), bob);
    }

    function test_IsRegisteredIsFalseBeforeRegistration() public view {
        assertFalse(rik.isRegistered(REPO_ID));
    }

    function test_RepoOfRevertsForUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(RIK.NotRegistered.selector, REPO_ID));
        rik.repoOf(REPO_ID);
    }

    // --- the audience carries the whole claim -------------------------------

    /// @dev The proof attests `alice`; nobody can redirect it to another wallet.
    function test_RejectsWalletMismatch() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "aud"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, bob);
    }

    /// @dev The repository being claimed lives only in the audience, so claiming a different one
    ///      with the same proof fails there.
    function test_RejectsRepositoryMismatch() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "aud"));
        _register(f, REPO_ID + 1, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsOwnerMismatch() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "aud"));
        _register(f, REPO_ID, OWNER_ID + 1, ACTOR_ID, alice);
    }

    /// @dev A workflow that emitted an audience for a repository it never authorised produces a
    ///      token this contract cannot be talked into accepting for the real one.
    function test_RejectsRedirectedAudience() public {
        Fixture memory f = _ready("redirected-audience-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "aud"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsActorMismatch() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "actor_id"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID + 1, alice);
    }

    // --- the proof must come from the pinned workflow -----------------------

    /// @dev Without the `repository_id` pin, anyone could invoke the attestation workflow as a
    ///      reusable workflow from their own repository and choose the audience outright.
    function test_RejectsForeignAttestationRepository() public {
        Fixture memory f = _ready("foreign-attestation-repo-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "repository_id"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    /// @dev Without the `job_workflow_ref` pin, any other workflow in this repository could mint
    ///      any repository's key, and rewriting the attestation workflow would be enough.
    function test_RejectsForeignJobWorkflowRef() public {
        Fixture memory f = _ready("wrong-workflow-ref-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "job_workflow_ref"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    /// @dev Only `issues` runs here while naming an external account as the actor. A
    ///      `workflow_dispatch` run in this repository is started by somebody with write access to
    ///      *this* project, which proves nothing about the repository being claimed.
    function test_RejectsWorkflowDispatchEvent() public {
        Fixture memory f = _ready("workflow-dispatch-event-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "event_name"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsPullRequestEvent() public {
        Fixture memory f = _ready("pull-request-event-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "event_name"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsWhenAttestationRepoUnset() public {
        RIK fresh = new RIK(owner, verifier);
        Fixture memory f = _ready("sample-jwt.json");

        vm.expectRevert(RIK.AttestationSourceNotConfigured.selector);
        fresh.register(f.kid, f.headerB64, f.payloadB64, f.signature, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsWhenWorkflowRefUnset() public {
        RIK fresh = new RIK(owner, verifier);
        fresh.setAttestationRepoId(ATTESTATION_REPO_ID);
        Fixture memory f = _ready("sample-jwt.json");

        vm.expectRevert(RIK.AttestationSourceNotConfigured.selector);
        fresh.register(f.kid, f.headerB64, f.payloadB64, f.signature, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    // --- claim injection ----------------------------------------------------

    /// @dev The whole matcher rests on JSON escaping `"` inside values. Free text crafted to look
    ///      like a claim must not be able to forge one.
    function test_ClaimInjectionCannotForgeActorId() public {
        Fixture memory f = _ready("claim-injection-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "actor_id"));
        _register(f, REPO_ID, OWNER_ID, 999999, alice);
    }

    function test_ClaimInjectionStillRegistersRealRepository() public {
        Fixture memory f = _ready("claim-injection-jwt.json");

        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
        assertEq(rik.ownerOf(REPO_ID), alice);
    }

    /// @dev The sharpest version: a stranger can only fire `issues`, so an attacker wanting a
    ///      different trigger has to try smuggling the event claim in through free text.
    function test_ClaimInjectionCannotForgeEventName() public {
        Fixture memory f = _ready("event-injection-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "event_name"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    // --- verifier delegation ------------------------------------------------

    function test_RejectsUnknownKid() public {
        Fixture memory f = _fixture("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(GithubOidcVerifier.UnknownKid.selector, f.kid));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsBadSignature() public {
        Fixture memory f = _ready("sample-jwt.json");
        f.signature[0] = bytes1(uint8(f.signature[0]) ^ 1);

        vm.expectRevert(GithubOidcVerifier.BadJwt.selector);
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsWrongIssuer() public {
        Fixture memory f = _ready("wrong-issuer-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "iss"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsExpiredProof() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.warp(f.exp + 1);
        vm.expectRevert(GithubOidcVerifier.TokenExpired.selector);
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsNotYetValidProof() public {
        Fixture memory f = _ready("future-nbf-jwt.json");

        vm.warp(f.nbf - 1);
        vm.expectRevert(GithubOidcVerifier.TokenNotYetValid.selector);
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    // --- registration is once, forever --------------------------------------

    function test_RejectsReplayedProof() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.AlreadyRegistered.selector, REPO_ID));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    /// @dev A second, genuinely different proof for the same repository is still refused. This is
    ///      what stops a repository owner yanking the key back from someone who bought it.
    function test_RejectsSecondDistinctProofForSameRepository() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        Fixture memory second = _ready("sample-jwt-alt.json");
        assertNotEq(keccak256(second.signature), keccak256(f.signature));

        vm.expectRevert(abi.encodeWithSelector(RIK.AlreadyRegistered.selector, REPO_ID));
        _register(second, REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsReRegistrationAfterTransfer() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        Fixture memory second = _ready("sample-jwt-alt.json");
        vm.expectRevert(abi.encodeWithSelector(RIK.AlreadyRegistered.selector, REPO_ID));
        _register(second, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        assertEq(rik.ownerOf(REPO_ID), bob);
    }

    // --- identifier bounds --------------------------------------------------

    function test_RejectsZeroRepoId() public {
        Fixture memory f = _ready("sample-jwt.json", 0, OWNER_ID, ACTOR_ID, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.InvalidGithubRepoId.selector, 0));
        _register(f, 0, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RejectsRepoIdTooLarge() public {
        uint256 repoId = uint256(type(uint64).max) + 1;
        Fixture memory f = _ready("sample-jwt.json", repoId, OWNER_ID, ACTOR_ID, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.InvalidGithubRepoId.selector, repoId));
        _register(f, repoId, OWNER_ID, ACTOR_ID, alice);
    }

    function test_AcceptsRepoIdAtUint64Max() public {
        uint256 repoId = uint256(type(uint64).max);
        Fixture memory f = _ready("sample-jwt.json", repoId, OWNER_ID, ACTOR_ID, alice);

        _register(f, repoId, OWNER_ID, ACTOR_ID, alice);
        assertEq(rik.ownerOf(repoId), alice);
    }

    function test_RejectsZeroOwnerId() public {
        Fixture memory f = _ready("sample-jwt.json", REPO_ID, 0, ACTOR_ID, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.InvalidGithubOwnerId.selector, 0));
        _register(f, REPO_ID, 0, ACTOR_ID, alice);
    }

    function test_RejectsZeroActorId() public {
        Fixture memory f = _ready("sample-jwt.json", REPO_ID, OWNER_ID, 0, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.InvalidGithubActorId.selector, 0));
        _register(f, REPO_ID, OWNER_ID, 0, alice);
    }

    function test_RejectsActorIdTooLarge() public {
        uint256 actorId = uint256(type(uint64).max) + 1;
        Fixture memory f = _ready("sample-jwt.json", REPO_ID, OWNER_ID, actorId, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.InvalidGithubActorId.selector, actorId));
        _register(f, REPO_ID, OWNER_ID, actorId, alice);
    }

    function test_RejectsZeroWallet() public {
        Fixture memory f = _ready("sample-jwt.json", REPO_ID, OWNER_ID, ACTOR_ID, address(0));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, address(0));
    }

    // --- transferability ----------------------------------------------------

    /// @dev Royalties follow the holder, so the key has to be tradeable. This is the opposite of
    ///      `UIK`, which is soulbound.
    function test_TransferMovesKey() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        assertEq(rik.ownerOf(REPO_ID), bob);
        assertEq(rik.balanceOf(alice), 0);
        assertEq(rik.balanceOf(bob), 1);
    }

    function test_ApprovedOperatorMayTransfer() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        vm.prank(alice);
        rik.approve(stranger, REPO_ID);

        vm.prank(stranger);
        rik.transferFrom(alice, bob, REPO_ID);

        assertEq(rik.ownerOf(REPO_ID), bob);
    }

    function test_TransferLeavesRegistrationRecordIntact() public {
        Fixture memory f = _ready("sample-jwt.json");
        vm.warp(1_700_000_000);
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        RIK.Repo memory repo = rik.repoOf(REPO_ID);
        assertEq(repo.githubRepoId, REPO_ID);
        assertEq(repo.githubOwnerId, OWNER_ID);
        assertEq(repo.githubActorId, ACTOR_ID);
        assertEq(repo.registeredAt, 1_700_000_000);
    }

    function test_StrangerCannotTransfer() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, alice);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, stranger, REPO_ID));
        rik.transferFrom(alice, bob, REPO_ID);
    }

    // --- fuzz ---------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 16
    /// forge-config: deep.fuzz.runs = 64
    function testFuzz_RegisterBindsAnyValidRepository(uint64 repoId, uint64 ownerId, uint64 actorId, address wallet)
        public
    {
        vm.assume(repoId != 0 && ownerId != 0 && actorId != 0);
        vm.assume(wallet != address(0));
        // Precompiles and the test contract itself are poor ERC-721 receivers under `_safeMint`.
        vm.assume(uint160(wallet) > 0x0a);

        Fixture memory f = _ready("sample-jwt.json", repoId, ownerId, actorId, wallet);
        _register(f, repoId, ownerId, actorId, wallet);

        assertEq(rik.ownerOf(uint256(repoId)), wallet);
        assertEq(rik.repoOf(uint256(repoId)).githubActorId, actorId);
    }

    /// forge-config: default.fuzz.runs = 16
    /// forge-config: deep.fuzz.runs = 64
    function testFuzz_RejectsAnyWalletButTheAttestedOne(address wallet) public {
        Fixture memory f = _ready("sample-jwt.json");
        vm.assume(wallet != alice);

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "aud"));
        _register(f, REPO_ID, OWNER_ID, ACTOR_ID, wallet);
    }

    /// forge-config: default.fuzz.runs = 16
    /// forge-config: deep.fuzz.runs = 64
    function testFuzz_RejectsAnyRepositoryButTheAttestedOne(uint256 repoId) public {
        Fixture memory f = _ready("sample-jwt.json");
        vm.assume(repoId != REPO_ID);

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "aud"));
        _register(f, repoId, OWNER_ID, ACTOR_ID, alice);
    }

    /// forge-config: default.fuzz.runs = 16
    /// forge-config: deep.fuzz.runs = 64
    function testFuzz_RejectsAnyActorButTheAttestedOne(uint256 actorId) public {
        Fixture memory f = _ready("sample-jwt.json");
        vm.assume(actorId != ACTOR_ID);

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "actor_id"));
        _register(f, REPO_ID, OWNER_ID, actorId, alice);
    }
}
