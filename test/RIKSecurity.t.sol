// test/RIKSecurity.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ClaimMatcher} from "../src/ClaimMatcher.sol";
import {GithubOidcVerifier} from "../src/GithubOidcVerifier.sol";
import {IJwtVerifier} from "../src/IJwtVerifier.sol";
import {RIK} from "../src/RIK.sol";
import {OidcFixture} from "./OidcFixture.sol";
import {
    CompliantReceiver,
    ReenteringReceiver,
    RejectingReceiver,
    RevertingVerifier,
    ScriptedVerifier,
    StateWritingVerifier,
    WrongAnswerReceiver
} from "./mocks/Adversarial.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @dev Adversarial coverage for the registry: hostile receivers, hostile verifiers, and the one
 *      reentrancy window `_safeMint` opens.
 */
contract RIKSecurity_T is OidcFixture {
    uint64 constant ATTESTATION_REPO_ID = 900100200;
    string constant WORKFLOW_REF = "freecodexyz/market/.github/workflows/register-rik.yml@refs/heads/main";

    uint256 constant REPO_ID = 1296269;
    uint256 constant REPO_ID_B = 222333;
    uint256 constant OWNER_ID = 583231;
    uint256 constant ACTOR_ID = 583231;

    GithubOidcVerifier verifier;
    RIK rik;

    address alice = address(0x1111111111111111111111111111111111111111);

    function setUp() public {
        verifier = new GithubOidcVerifier(address(this));
        rik = _configured(verifier);
    }

    function _configured(IJwtVerifier jwt_) internal returns (RIK registry) {
        registry = new RIK(address(this), jwt_);
        registry.setAttestationRepoId(ATTESTATION_REPO_ID);
        registry.setJobWorkflowRef(WORKFLOW_REF);
    }

    function _proofFor(uint256 repoId, address wallet) internal returns (Fixture memory f) {
        f = _fixture("sample-jwt.json", repoId, OWNER_ID, ACTOR_ID, wallet);
        verifier.addKey(f.kid, f.modulus, f.exponent);
    }

    function _register(Fixture memory f, uint256 repoId, address wallet) internal {
        rik.register(f.kid, f.headerB64, f.payloadB64, f.signature, repoId, OWNER_ID, ACTOR_ID, wallet);
    }

    /**
     * @dev Builds a payload the way a JSON encoder would, from parts a hostile verifier controls.
     *
     * `freeText` represents the workflow name, which GitHub copies into the token verbatim and is
     * therefore where claim injection would be attempted.
     */
    function _payload(
        string memory audience,
        uint256 actorId,
        string memory event_,
        string memory workflowRef,
        string memory freeText
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            '{"workflow":"',
            freeText,
            '","aud":"',
            audience,
            '","actor_id":"',
            Strings.toString(actorId),
            '","repository_id":"',
            Strings.toString(uint256(ATTESTATION_REPO_ID)),
            '","event_name":"',
            event_,
            '","job_workflow_ref":"',
            workflowRef,
            '"}'
        );
    }

    /// @dev A payload satisfying every check, for tests concerned with something else.
    function _validPayload() internal view returns (bytes memory) {
        return _payload(rik.audienceOf(alice, REPO_ID, OWNER_ID), ACTOR_ID, "issues", WORKFLOW_REF, "Register");
    }

    // --- construction -------------------------------------------------------

    function test_ConstructorRejectsZeroVerifier() public {
        vm.expectRevert(RIK.InvalidVerifier.selector);
        new RIK(address(this), IJwtVerifier(address(0)));
    }

    // --- receiver safety ----------------------------------------------------

    /// @dev The key is transferable and carries a repository's royalties, so minting one into a
    ///      contract that cannot transfer it would strand the market permanently. A rejected
    ///      registration can be retried.
    function test_RejectsContractThatCannotReceiveKeys() public {
        MockERC20 notAReceiver = new MockERC20("Not A Wallet", "NAW");
        Fixture memory f = _proofFor(REPO_ID, address(notAReceiver));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(notAReceiver)));
        _register(f, REPO_ID, address(notAReceiver));

        assertFalse(rik.isRegistered(REPO_ID));
    }

    function test_RejectsReceiverAnsweringWithTheWrongSelector() public {
        WrongAnswerReceiver wrong = new WrongAnswerReceiver();
        Fixture memory f = _proofFor(REPO_ID, address(wrong));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(wrong)));
        _register(f, REPO_ID, address(wrong));
    }

    function test_RejectsReceiverThatReverts() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        Fixture memory f = _proofFor(REPO_ID, address(rejecting));

        vm.expectRevert(RejectingReceiver.NotToday.selector);
        _register(f, REPO_ID, address(rejecting));
    }

    /// @dev A smart-contract wallet is an expected holder, so this case must succeed.
    function test_AcceptsCompliantContractWallet() public {
        CompliantReceiver wallet = new CompliantReceiver();
        Fixture memory f = _proofFor(REPO_ID, address(wallet));

        _register(f, REPO_ID, address(wallet));

        assertEq(rik.ownerOf(REPO_ID), address(wallet));
    }

    /// @dev A failed delivery leaves no state behind, so the repository can be registered again.
    function test_FailedDeliveryLeavesNoRecord() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        Fixture memory f = _proofFor(REPO_ID, address(rejecting));

        vm.expectRevert(RejectingReceiver.NotToday.selector);
        _register(f, REPO_ID, address(rejecting));

        Fixture memory second = _proofFor(REPO_ID, alice);
        _register(second, REPO_ID, alice);
        assertEq(rik.ownerOf(REPO_ID), alice);
    }

    // --- reentrancy through the mint hook -----------------------------------

    /// @dev The receiver hook runs after every state change, so a nested registration of the same
    ///      repository observes a consistent registry and is refused. This replaces a reentrancy
    ///      guard on `register`.
    function test_ReentrantRegistrationCannotDoubleRegister() public {
        ReenteringReceiver receiver = new ReenteringReceiver();
        Fixture memory f = _proofFor(REPO_ID, address(receiver));

        receiver.arm(
            rik,
            abi.encodeCall(
                RIK.register,
                (f.kid, f.headerB64, f.payloadB64, f.signature, REPO_ID, OWNER_ID, ACTOR_ID, address(receiver))
            )
        );

        _register(f, REPO_ID, address(receiver));

        assertTrue(receiver.reentered(), "the hook must have been reached");
        assertFalse(receiver.reentrySucceeded(), "a repository was registered twice");
        assertEq(rik.ownerOf(REPO_ID), address(receiver));
        assertEq(rik.balanceOf(address(receiver)), 1);
    }

    /// @dev Registering a different repository from inside the hook is valid, and a blanket
    ///      reentrancy guard would prevent it. A factory claiming several repositories in one call
    ///      is one such case.
    function test_ReentrantRegistrationOfAnotherRepositorySucceeds() public {
        ReenteringReceiver receiver = new ReenteringReceiver();
        Fixture memory first = _proofFor(REPO_ID, address(receiver));
        Fixture memory second = _proofFor(REPO_ID_B, address(receiver));

        receiver.arm(
            rik,
            abi.encodeCall(
                RIK.register,
                (
                    second.kid,
                    second.headerB64,
                    second.payloadB64,
                    second.signature,
                    REPO_ID_B,
                    OWNER_ID,
                    ACTOR_ID,
                    address(receiver)
                )
            )
        );

        _register(first, REPO_ID, address(receiver));

        assertTrue(receiver.reentrySucceeded(), "a legitimate nested registration was blocked");
        assertEq(rik.ownerOf(REPO_ID), address(receiver));
        assertEq(rik.ownerOf(REPO_ID_B), address(receiver));
        assertEq(rik.balanceOf(address(receiver)), 2);
    }

    // --- the verifier trust boundary ----------------------------------------

    /// @dev The top of the risk model: the registry accepts whatever the verifier returns. A
    ///      compromised verifier owner can mint any repository's key to any wallet, which is why
    ///      that key lives in the identity repository and is dedicated to the sync job.
    function test_VerifierIsTheRootOfTrust() public {
        RIK trusting = _configured(new ScriptedVerifier(_validPayload()));
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, ACTOR_ID, alice);

        assertEq(trusting.ownerOf(REPO_ID), alice);
    }

    /// @dev Even a trusted verifier's payload still has to carry every claim.
    function test_ScriptedPayloadStillNeedsTheWorkflowPin() public {
        bytes memory incomplete = abi.encodePacked(
            '{"aud":"',
            rik.audienceOf(alice, REPO_ID, OWNER_ID),
            '","actor_id":"',
            Strings.toString(ACTOR_ID),
            '","repository_id":"',
            Strings.toString(uint256(ATTESTATION_REPO_ID)),
            '","event_name":"issues"}'
        );

        RIK trusting = _configured(new ScriptedVerifier(incomplete));

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMissing.selector, "job_workflow_ref"));
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    /// @dev A proof produced by some other workflow in this repository is refused, which is what
    ///      keeps the attestation logic itself pinned.
    function test_ScriptedPayloadFromAnotherWorkflowIsRejected() public {
        bytes memory wrongWorkflow = _payload(
            rik.audienceOf(alice, REPO_ID, OWNER_ID),
            ACTOR_ID,
            "issues",
            "freecodexyz/market/.github/workflows/something-else.yml@refs/heads/main",
            "Register"
        );

        RIK trusting = _configured(new ScriptedVerifier(wrongWorkflow));

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "job_workflow_ref"));
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    function test_RevertingVerifierPropagates() public {
        RIK brittle = _configured(new RevertingVerifier());

        vm.expectRevert(RevertingVerifier.Nope.selector);
        brittle.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    /**
     * @dev {IJwtVerifier-verifyGithubOidc} is `view`, so the compiler reaches it with STATICCALL and
     *      a verifier cannot mutate anything, including reentering the registry. Relaxing that
     *      interface to non-view would remove the protection silently, so it is pinned here.
     */
    function test_VerifierCannotWriteStateWhileVerifying() public {
        StateWritingVerifier hostile = new StateWritingVerifier();
        RIK guarded = _configured(IJwtVerifier(address(hostile)));

        vm.expectRevert();
        guarded.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, ACTOR_ID, alice);

        assertEq(hostile.calls(), 0, "the verifier must not have been able to record the call");
    }

    // --- the JSON encoding assumption ---------------------------------------

    /**
     * @dev Records the assumption the matcher depends on.
     *
     * A payload is produced by a JSON encoder, which escapes `"` inside a value. Given a payload
     * that does not, a claim can be forged from free text. No contract-level check prevents this,
     * which is why the trust boundary is the verifier and why {ClaimMatcher} must not be changed to
     * match anything looser than an exact byte run.
     */
    function test_UnescapedQuoteInARawPayloadWouldForgeTheEventClaim() public {
        // The workflow name is attacker-controlled. Unescaped, it closes its own string and writes
        // a second `event_name` claim.
        string memory injected = '","event_name":"issues';

        RIK trusting = _configured(
            new ScriptedVerifier(
                _payload(rik.audienceOf(alice, REPO_ID, OWNER_ID), ACTOR_ID, "push", WORKFLOW_REF, injected)
            )
        );
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, ACTOR_ID, alice);

        assertEq(trusting.ownerOf(REPO_ID), alice);
    }

    function _containsQuote(string memory value) internal pure returns (bool) {
        bytes memory raw = bytes(value);
        for (uint256 i = 0; i < raw.length; ++i) {
            if (raw[i] == '"') return true;
        }
        return false;
    }

    // --- fuzz ---------------------------------------------------------------

    /**
     * @dev No payload whose `event_name` is anything but `issues` ever registers.
     *
     * Values are constrained to be quote-free, which a JSON encoder guarantees and which
     * {test_UnescapedQuoteInARawPayloadWouldForgeTheEventClaim} shows is load-bearing.
     */
    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 10000
    function testFuzz_OnlyIssuesEverRegisters(string calldata event_) public {
        vm.assume(keccak256(bytes(event_)) != keccak256("issues"));
        vm.assume(!_containsQuote(event_));

        RIK trusting = _configured(
            new ScriptedVerifier(
                _payload(rik.audienceOf(alice, REPO_ID, OWNER_ID), ACTOR_ID, event_, WORKFLOW_REF, "Register")
            )
        );

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "event_name"));
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, ACTOR_ID, alice);
    }

    /// @dev The audience carries the entire claim, so only the attested triple can be bound.
    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 10000
    function testFuzz_OnlyTheAttestedTripleEverRegisters(address wallet, uint64 repoId, uint64 ownerId) public {
        vm.assume(repoId != 0 && ownerId != 0);
        vm.assume(
            keccak256(bytes(rik.audienceOf(wallet, repoId, ownerId)))
                != keccak256(bytes(rik.audienceOf(alice, REPO_ID, OWNER_ID)))
        );

        RIK trusting = _configured(new ScriptedVerifier(_validPayload()));

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "aud"));
        trusting.register(bytes32(0), "", "", "", repoId, ownerId, ACTOR_ID, wallet);
    }

    /// @dev Only the actor GitHub named is credited.
    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 10000
    function testFuzz_OnlyTheAttestedActorEverRegisters(uint64 actorId) public {
        vm.assume(actorId != 0 && uint256(actorId) != ACTOR_ID);

        RIK trusting = _configured(new ScriptedVerifier(_validPayload()));

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "actor_id"));
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, actorId, alice);
    }
}
