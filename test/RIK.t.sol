// test/RIK.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

import {GithubOidcVerifier} from "../src/GithubOidcVerifier.sol";
import {JsonClaim} from "../src/JsonClaim.sol";
import {RIK} from "../src/RIK.sol";
import {OidcFixture} from "./OidcFixture.sol";

contract RIK_T is OidcFixture {
    /// @dev Must match the defaults baked into `test/fixtures/load-fixture.mjs`.
    uint64 constant REPO_ID = 1296269;
    uint64 constant OWNER_ID = 583231;

    GithubOidcVerifier verifier;
    RIK rik;

    address owner = address(this);
    address stranger = address(0xBAD);
    address relayer = address(0xFEE);
    address alice = address(0x1111111111111111111111111111111111111111);
    address bob = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        verifier = new GithubOidcVerifier(owner);
        rik = new RIK(verifier);
    }

    function _addKey(Fixture memory f) internal {
        verifier.addKey(f.kid, f.modulus, f.exponent);
    }

    function _register(Fixture memory f, uint256 repoId, uint256 ownerId, address wallet) internal {
        rik.register(f.kid, f.headerB64, f.payloadB64, f.signature, repoId, ownerId, wallet);
    }

    /// @dev Loads a fixture and installs its signing key.
    function _ready(string memory name) internal returns (Fixture memory f) {
        f = _fixture(name);
        _addKey(f);
    }

    function _ready(string memory name, uint256 repoId, uint256 ownerId, address wallet)
        internal
        returns (Fixture memory f)
    {
        f = _fixture(name, repoId, ownerId, wallet);
        _addKey(f);
    }

    // --- metadata and configuration ----------------------------------------

    function test_NameAndSymbol() public view {
        assertEq(rik.name(), "Repository Identity Key");
        assertEq(rik.symbol(), "RIK");
    }

    /// @dev The single claim that carries proof of write access to the repository.
    function test_ExpectedEventName() public view {
        assertEq(rik.expectedEventName(), "workflow_dispatch");
    }

    function test_JwtVerifierIsImmutable() public view {
        assertEq(address(rik.jwt()), address(verifier));
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

    /// @dev There is deliberately no administrative surface: key rotation lives in the verifier.
    function test_HasNoOwnerFunction() public view {
        (bool ok,) = address(rik).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    // --- registration happy path -------------------------------------------

    function test_RegisterMintsToAttestedWallet() public {
        Fixture memory f = _ready("sample-jwt.json");

        _register(f, REPO_ID, OWNER_ID, alice);

        assertEq(rik.ownerOf(REPO_ID), alice);
        assertEq(rik.balanceOf(alice), 1);
        assertTrue(rik.isRegistered(REPO_ID));
    }

    /// @dev The proof names its beneficiary, so a relayer can pay the gas without being able to
    ///      redirect the key.
    function test_RegisterIsPermissionless() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.prank(relayer);
        _register(f, REPO_ID, OWNER_ID, alice);

        assertEq(rik.ownerOf(REPO_ID), alice);
        assertEq(rik.balanceOf(relayer), 0);
    }

    function test_RegisterEmitsRepoRegistered() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.warp(1_700_000_000);
        vm.expectEmit(true, true, true, true);
        emit RIK.RepoRegistered(REPO_ID, alice, relayer, OWNER_ID, 1_700_000_000);

        vm.prank(relayer);
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    function test_RegisterStoresRepo() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.warp(1_700_000_000);
        _register(f, REPO_ID, OWNER_ID, alice);

        RIK.Repo memory repo = rik.repoOf(REPO_ID);
        assertEq(repo.githubRepoId, REPO_ID);
        assertEq(repo.githubOwnerId, OWNER_ID);
        assertEq(repo.registeredAt, 1_700_000_000);
    }

    function test_TwoRepositoriesGetDistinctTokens() public {
        Fixture memory first = _ready("sample-jwt.json", 111, OWNER_ID, alice);
        Fixture memory second = _fixture("sample-jwt.json", 222, OWNER_ID, bob);

        _register(first, 111, OWNER_ID, alice);
        _register(second, 222, OWNER_ID, bob);

        assertEq(rik.ownerOf(111), alice);
        assertEq(rik.ownerOf(222), bob);
    }

    function test_OneWalletMayHoldSeveralKeys() public {
        Fixture memory first = _ready("sample-jwt.json", 111, OWNER_ID, alice);
        Fixture memory second = _fixture("sample-jwt.json", 222, OWNER_ID, alice);

        _register(first, 111, OWNER_ID, alice);
        _register(second, 222, OWNER_ID, alice);

        assertEq(rik.balanceOf(alice), 2);
    }

    function test_IsRegisteredIsFalseBeforeRegistration() public view {
        assertFalse(rik.isRegistered(REPO_ID));
    }

    function test_RepoOfRevertsForUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(RIK.NotRegistered.selector, REPO_ID));
        rik.repoOf(REPO_ID);
    }

    // --- claim binding ------------------------------------------------------

    function test_RejectsAudMismatch() public {
        Fixture memory f = _ready("sample-jwt.json");

        // The proof attests `alice`; nobody can redirect it to another wallet.
        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "aud"));
        _register(f, REPO_ID, OWNER_ID, bob);
    }

    function test_RejectsRepositoryIdMismatch() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "repository_id"));
        _register(f, REPO_ID + 1, OWNER_ID, alice);
    }

    function test_RejectsRepositoryOwnerIdMismatch() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "repository_owner_id"));
        _register(f, REPO_ID, OWNER_ID + 1, alice);
    }

    /// @dev Anyone can open an issue in a repository they do not control, and the resulting run
    ///      still carries that repository's `repository_id`. Without the event pin this proof would
    ///      mint the repository's key to a stranger's wallet.
    function test_RejectsIssuesEvent() public {
        Fixture memory f = _ready("issues-event-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "event_name"));
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    /// @dev The same hole through a different trigger.
    function test_RejectsPullRequestEvent() public {
        Fixture memory f = _ready("pull-request-event-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "event_name"));
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    // --- claim injection ----------------------------------------------------

    /// @dev The whole matcher rests on JSON escaping `"` inside values. A workflow name crafted to
    ///      look like a claim must not be able to forge one.
    function test_ClaimInjectionCannotForgeRepositoryId() public {
        Fixture memory f = _ready("claim-injection-jwt.json");

        // The payload literally contains `pwn","repository_id":"999999"...` inside `workflow`.
        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "repository_id"));
        _register(f, 999999, 999999, alice);
    }

    function test_ClaimInjectionStillRegistersRealRepository() public {
        Fixture memory f = _ready("claim-injection-jwt.json");

        // The genuine claims are unaffected by the injected text.
        _register(f, REPO_ID, OWNER_ID, alice);
        assertEq(rik.ownerOf(REPO_ID), alice);
    }

    /// @dev The sharpest version: an attacker who can only fire `issues` tries to smuggle a
    ///      `workflow_dispatch` event claim in through the workflow name.
    function test_ClaimInjectionCannotForgeEventName() public {
        Fixture memory f = _ready("event-injection-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "event_name"));
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    // --- verifier delegation ------------------------------------------------

    function test_RejectsUnknownKid() public {
        Fixture memory f = _fixture("sample-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(GithubOidcVerifier.UnknownKid.selector, f.kid));
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    function test_RejectsBadSignature() public {
        Fixture memory f = _ready("sample-jwt.json");
        f.signature[0] = bytes1(uint8(f.signature[0]) ^ 1);

        vm.expectRevert(GithubOidcVerifier.BadJwt.selector);
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    function test_RejectsWrongIssuer() public {
        Fixture memory f = _ready("wrong-issuer-jwt.json");

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "iss"));
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    function test_RejectsExpiredProof() public {
        Fixture memory f = _ready("sample-jwt.json");

        vm.warp(f.exp + 1);
        vm.expectRevert(GithubOidcVerifier.TokenExpired.selector);
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    function test_RejectsNotYetValidProof() public {
        Fixture memory f = _ready("future-nbf-jwt.json");

        vm.warp(f.nbf - 1);
        vm.expectRevert(GithubOidcVerifier.TokenNotYetValid.selector);
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    // --- registration is once, forever --------------------------------------

    function test_RejectsReplayedProof() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.AlreadyRegistered.selector, REPO_ID));
        _register(f, REPO_ID, OWNER_ID, alice);
    }

    /// @dev A second, genuinely different proof for the same repository is still refused. This is
    ///      what stops a repository owner yanking the key back from someone who bought it.
    function test_RejectsSecondDistinctProofForSameRepository() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, alice);

        Fixture memory second = _ready("sample-jwt-alt.json");
        assertNotEq(keccak256(second.signature), keccak256(f.signature));

        vm.expectRevert(abi.encodeWithSelector(RIK.AlreadyRegistered.selector, REPO_ID));
        _register(second, REPO_ID, OWNER_ID, alice);
    }

    /// @dev Even after a transfer, so the buyer cannot be rugged by the repository owner.
    function test_RejectsReRegistrationAfterTransfer() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, alice);

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        Fixture memory second = _ready("sample-jwt-alt.json");
        vm.expectRevert(abi.encodeWithSelector(RIK.AlreadyRegistered.selector, REPO_ID));
        _register(second, REPO_ID, OWNER_ID, alice);

        assertEq(rik.ownerOf(REPO_ID), bob);
    }

    // --- identifier bounds --------------------------------------------------

    function test_RejectsZeroRepoId() public {
        Fixture memory f = _ready("sample-jwt.json", 0, OWNER_ID, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.InvalidGithubRepoId.selector, 0));
        _register(f, 0, OWNER_ID, alice);
    }

    function test_RejectsRepoIdTooLarge() public {
        uint256 repoId = uint256(type(uint64).max) + 1;
        Fixture memory f = _ready("sample-jwt.json", repoId, OWNER_ID, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.InvalidGithubRepoId.selector, repoId));
        _register(f, repoId, OWNER_ID, alice);
    }

    function test_AcceptsRepoIdAtUint64Max() public {
        uint256 repoId = uint256(type(uint64).max);
        Fixture memory f = _ready("sample-jwt.json", repoId, OWNER_ID, alice);

        _register(f, repoId, OWNER_ID, alice);
        assertEq(rik.ownerOf(repoId), alice);
    }

    function test_RejectsZeroOwnerId() public {
        Fixture memory f = _ready("sample-jwt.json", REPO_ID, 0, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.InvalidGithubOwnerId.selector, 0));
        _register(f, REPO_ID, 0, alice);
    }

    function test_RejectsOwnerIdTooLarge() public {
        uint256 ownerId = uint256(type(uint64).max) + 1;
        Fixture memory f = _ready("sample-jwt.json", REPO_ID, ownerId, alice);

        vm.expectRevert(abi.encodeWithSelector(RIK.InvalidGithubOwnerId.selector, ownerId));
        _register(f, REPO_ID, ownerId, alice);
    }

    function test_RejectsZeroWallet() public {
        Fixture memory f = _ready("sample-jwt.json", REPO_ID, OWNER_ID, address(0));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        _register(f, REPO_ID, OWNER_ID, address(0));
    }

    // --- transferability ----------------------------------------------------

    /// @dev Royalties follow the holder, so the key has to be tradeable. This is the opposite of
    ///      `UIK`, which is soulbound.
    function test_TransferMovesKey() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, alice);

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        assertEq(rik.ownerOf(REPO_ID), bob);
        assertEq(rik.balanceOf(alice), 0);
        assertEq(rik.balanceOf(bob), 1);
    }

    function test_ApprovedOperatorMayTransfer() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, alice);

        vm.prank(alice);
        rik.approve(stranger, REPO_ID);

        vm.prank(stranger);
        rik.transferFrom(alice, bob, REPO_ID);

        assertEq(rik.ownerOf(REPO_ID), bob);
    }

    function test_TransferLeavesRegistrationRecordIntact() public {
        Fixture memory f = _ready("sample-jwt.json");
        vm.warp(1_700_000_000);
        _register(f, REPO_ID, OWNER_ID, alice);

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        RIK.Repo memory repo = rik.repoOf(REPO_ID);
        assertEq(repo.githubRepoId, REPO_ID);
        assertEq(repo.githubOwnerId, OWNER_ID);
        assertEq(repo.registeredAt, 1_700_000_000);
    }

    function test_StrangerCannotTransfer() public {
        Fixture memory f = _ready("sample-jwt.json");
        _register(f, REPO_ID, OWNER_ID, alice);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, stranger, REPO_ID));
        rik.transferFrom(alice, bob, REPO_ID);
    }

    // --- fuzz ---------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 16
    /// forge-config: deep.fuzz.runs = 64
    function testFuzz_RegisterBindsAnyValidRepository(uint64 repoId, uint64 ownerId, address wallet) public {
        vm.assume(repoId != 0);
        vm.assume(ownerId != 0);
        vm.assume(wallet != address(0));
        // Precompiles and the test contract itself are poor ERC-721 receivers under `_mint`.
        vm.assume(uint160(wallet) > 0x0a);

        Fixture memory f = _ready("sample-jwt.json", uint256(repoId), uint256(ownerId), wallet);
        _register(f, uint256(repoId), uint256(ownerId), wallet);

        assertEq(rik.ownerOf(uint256(repoId)), wallet);
        assertEq(rik.repoOf(uint256(repoId)).githubOwnerId, ownerId);
    }

    /// forge-config: default.fuzz.runs = 16
    /// forge-config: deep.fuzz.runs = 64
    function testFuzz_RejectsAnyWalletButTheAttestedOne(address wallet) public {
        Fixture memory f = _ready("sample-jwt.json");
        vm.assume(wallet != alice);

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "aud"));
        _register(f, REPO_ID, OWNER_ID, wallet);
    }

    /// forge-config: default.fuzz.runs = 16
    /// forge-config: deep.fuzz.runs = 64
    function testFuzz_RejectsAnyRepositoryButTheAttestedOne(uint256 repoId) public {
        Fixture memory f = _ready("sample-jwt.json");
        vm.assume(repoId != REPO_ID);

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "repository_id"));
        _register(f, repoId, OWNER_ID, alice);
    }

    /// forge-config: default.fuzz.runs = 16
    /// forge-config: deep.fuzz.runs = 64
    function testFuzz_RejectsAnyOwnerButTheAttestedOne(uint256 ownerId) public {
        Fixture memory f = _ready("sample-jwt.json");
        vm.assume(ownerId != OWNER_ID);

        vm.expectRevert(abi.encodeWithSelector(JsonClaim.ClaimMismatch.selector, "repository_owner_id"));
        _register(f, REPO_ID, ownerId, alice);
    }
}
