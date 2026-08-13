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
    uint256 constant REPO_ID = 1296269;
    uint256 constant REPO_ID_B = 222333;
    uint256 constant OWNER_ID = 583231;

    GithubOidcVerifier verifier;
    RIK rik;

    address alice = address(0x1111111111111111111111111111111111111111);

    function setUp() public {
        verifier = new GithubOidcVerifier(address(this));
        rik = new RIK(verifier);
    }

    function _proofFor(uint256 repoId, address wallet) internal returns (Fixture memory f) {
        f = _fixture("sample-jwt.json", repoId, OWNER_ID, wallet);
        verifier.addKey(f.kid, f.modulus, f.exponent);
    }

    function _register(Fixture memory f, uint256 repoId, address wallet) internal {
        rik.register(f.kid, f.headerB64, f.payloadB64, f.signature, repoId, OWNER_ID, wallet);
    }

    // --- construction -------------------------------------------------------

    function test_ConstructorRejectsZeroVerifier() public {
        vm.expectRevert(RIK.InvalidVerifier.selector);
        new RIK(IJwtVerifier(address(0)));
    }

    // --- receiver safety ----------------------------------------------------

    /// @dev The key is transferable and carries a repository's royalties. Minting one into a
    ///      contract that cannot move it would strand the market permanently, and re-running the
    ///      workflow with a different audience costs nothing.
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

    /// @dev A smart-contract wallet is the expected holder of a valuable key, so this is the case
    ///      that has to work.
    function test_AcceptsCompliantContractWallet() public {
        CompliantReceiver wallet = new CompliantReceiver();
        Fixture memory f = _proofFor(REPO_ID, address(wallet));

        _register(f, REPO_ID, address(wallet));

        assertEq(rik.ownerOf(REPO_ID), address(wallet));
    }

    /// @dev A failed delivery leaves nothing behind, so the repository can simply try again.
    function test_FailedDeliveryLeavesNoRecord() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        Fixture memory f = _proofFor(REPO_ID, address(rejecting));

        vm.expectRevert(RejectingReceiver.NotToday.selector);
        _register(f, REPO_ID, address(rejecting));

        // And the same repository registers cleanly to a wallet that does work.
        Fixture memory second = _proofFor(REPO_ID, alice);
        _register(second, REPO_ID, alice);
        assertEq(rik.ownerOf(REPO_ID), alice);
    }

    // --- reentrancy through the mint hook -----------------------------------

    /// @dev The receiver hook runs after every state change, so a nested registration of the same
    ///      repository sees a consistent registry and is refused. This is what stands in for a
    ///      reentrancy guard on `register`.
    function test_ReentrantRegistrationCannotDoubleRegister() public {
        ReenteringReceiver receiver = new ReenteringReceiver();
        Fixture memory f = _proofFor(REPO_ID, address(receiver));

        receiver.arm(
            rik,
            abi.encodeCall(
                RIK.register, (f.kid, f.headerB64, f.payloadB64, f.signature, REPO_ID, OWNER_ID, address(receiver))
            )
        );

        _register(f, REPO_ID, address(receiver));

        assertTrue(receiver.reentered(), "the hook must have been reached");
        assertFalse(receiver.reentrySucceeded(), "a repository was registered twice");
        assertEq(rik.ownerOf(REPO_ID), address(receiver));
        assertEq(rik.balanceOf(address(receiver)), 1);
    }

    /// @dev Registering a *different* repository from inside the hook is legitimate, and a blanket
    ///      reentrancy guard would have broken it. A factory minting several keys in one call is
    ///      the obvious use.
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

    /// @dev Stated plainly, because it is the top of the risk model: the registry believes whatever
    ///      the verifier hands it. A compromised verifier owner can mint any repository's key to
    ///      any wallet, which is why that key lives in the identity repository and is kept
    ///      dedicated to the sync job.
    function test_VerifierIsTheRootOfTrust() public {
        bytes memory forged = abi.encodePacked(
            '{"aud":"',
            Strings.toHexString(uint160(alice), 20),
            '","repository_id":"',
            Strings.toString(REPO_ID),
            '","repository_owner_id":"',
            Strings.toString(OWNER_ID),
            '","event_name":"workflow_dispatch"}'
        );

        RIK trusting = new RIK(new ScriptedVerifier(forged));
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, alice);

        assertEq(trusting.ownerOf(REPO_ID), alice);
    }

    /// @dev Even a trusted verifier's payload still has to carry every claim.
    function test_ScriptedPayloadStillNeedsTheEventClaim() public {
        bytes memory incomplete = abi.encodePacked(
            '{"aud":"',
            Strings.toHexString(uint160(alice), 20),
            '","repository_id":"',
            Strings.toString(REPO_ID),
            '","repository_owner_id":"',
            Strings.toString(OWNER_ID),
            '"}'
        );

        RIK trusting = new RIK(new ScriptedVerifier(incomplete));

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMissing.selector, "event_name"));
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, alice);
    }

    function test_RevertingVerifierPropagates() public {
        RIK brittle = new RIK(new RevertingVerifier());

        vm.expectRevert(RevertingVerifier.Nope.selector);
        brittle.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, alice);
    }

    /**
     * @dev {IJwtVerifier-verifyGithubOidc} is `view`, so the compiler reaches it with STATICCALL and
     *      a verifier cannot mutate anything, including reentering the registry. Relaxing that
     *      interface to non-view would remove the protection silently, so it is pinned here.
     */
    function test_VerifierCannotWriteStateWhileVerifying() public {
        StateWritingVerifier hostile = new StateWritingVerifier();
        RIK guarded = new RIK(IJwtVerifier(address(hostile)));

        vm.expectRevert();
        guarded.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, alice);

        assertEq(hostile.calls(), 0, "the verifier must not have been able to record the call");
    }

    // --- the JSON encoding assumption ---------------------------------------

    /// @dev Builds a payload the way a JSON encoder would: no unescaped `"` can appear in a value.
    function _payload(uint256 repoId, uint256 ownerId, string memory event_) internal view returns (bytes memory) {
        return abi.encodePacked(
            '{"workflow":"',
            event_,
            '","aud":"',
            Strings.toHexString(uint160(alice), 20),
            '","repository_id":"',
            Strings.toString(repoId),
            '","repository_owner_id":"',
            Strings.toString(ownerId),
            '","event_name":"',
            event_,
            '"}'
        );
    }

    function _containsQuote(string memory value) internal pure returns (bool) {
        bytes memory raw = bytes(value);
        for (uint256 i = 0; i < raw.length; ++i) {
            if (raw[i] == '"') return true;
        }
        return false;
    }

    /**
     * @dev The assumption the whole matcher rests on, stated as an executable fact.
     *
     * A payload is only ever produced by a JSON encoder, which escapes `"` inside a value. Hand one
     * to the registry that does not, and a claim really can be forged out of free text. Nothing in
     * the contracts can prevent that, which is exactly why the trust boundary sits at the verifier
     * and why {ClaimMatcher} must never be changed to match anything looser than an exact byte run.
     */
    function test_UnescapedQuoteInARawPayloadWouldForgeTheEventClaim() public {
        // `workflow` is attacker-controlled free text. Unescaped, it closes its own string and
        // writes a second `event_name` claim.
        string memory injected = '","event_name":"workflow_dispatch';

        RIK trusting = new RIK(new ScriptedVerifier(_payload(REPO_ID, OWNER_ID, injected)));
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, alice);

        assertEq(trusting.ownerOf(REPO_ID), alice);
    }

    // --- fuzz ---------------------------------------------------------------

    /**
     * @dev No payload whose `event_name` is anything but `workflow_dispatch` ever registers.
     *
     * Values are constrained to be quote-free, which is what a JSON encoder guarantees and what
     * {test_UnescapedQuoteInARawPayloadWouldForgeTheEventClaim} shows is load-bearing. Within that
     * assumption, no event name gets through, however it is shaped.
     */
    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 10000
    function testFuzz_OnlyWorkflowDispatchEverRegisters(uint64 repoId, uint64 ownerId, string calldata event_) public {
        vm.assume(repoId != 0 && ownerId != 0);
        vm.assume(keccak256(bytes(event_)) != keccak256("workflow_dispatch"));
        vm.assume(!_containsQuote(event_));

        RIK trusting = new RIK(new ScriptedVerifier(_payload(uint256(repoId), uint256(ownerId), event_)));

        vm.expectRevert();
        trusting.register(bytes32(0), "", "", "", uint256(repoId), uint256(ownerId), alice);
    }

    /// @dev And the audience is likewise unforgeable: no wallet but the attested one is ever bound.
    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 10000
    function testFuzz_OnlyTheAttestedWalletEverRegisters(address wallet) public {
        vm.assume(wallet != alice);

        RIK trusting = new RIK(new ScriptedVerifier(_payload(REPO_ID, OWNER_ID, "workflow_dispatch")));

        vm.expectRevert(abi.encodeWithSelector(ClaimMatcher.ClaimMismatch.selector, "aud"));
        trusting.register(bytes32(0), "", "", "", REPO_ID, OWNER_ID, wallet);
    }
}
