// src/RIK.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ClaimMatcher} from "./ClaimMatcher.sol";
import {IJwtVerifier} from "./IJwtVerifier.sol";

/**
 * @title RIK
 * @notice Repository Identity Key: an ERC-721 binding a GitHub repository to a wallet address.
 *
 * @dev The token id is the GitHub repository's numeric id, which is immutable and never recycled.
 *      Nothing renameable is stored, so the record cannot go stale.
 *
 *      # Proof model
 *
 *      Registration is an issue opened on the attestation repository. Nothing is committed to the
 *      repository being claimed, nothing is installed by the claimant, and the transaction is paid
 *      for by a relayer, so a repository owner needs a wallet address and nothing else.
 *
 *      That shape has a consequence. The proof is produced by a workflow running *here*, so
 *      `repository_id` names the attestation repository and `actor_id` names whoever opened the
 *      issue. Neither says anything about the repository being claimed. Every claim in an Actions
 *      OIDC token is set by GitHub except one: `aud` is an arbitrary string chosen by the workflow
 *      at the moment it requests the token. It is therefore the only channel a reviewed workflow has
 *      to speak to this contract, and it carries the whole claim:
 *
 *          aud = "<wallet>:<repositoryId>:<ownerId>"
 *
 *      The remaining checks exist to prove that string came from code that has been reviewed:
 *
 *      - `repository_id` must equal {attestationRepoId}. Without it, anyone could invoke the
 *        attestation workflow as a reusable workflow from their own repository and choose `aud`.
 *      - `job_workflow_ref` must equal {jobWorkflowRef}. This pins the exact file and ref that chose
 *        `aud`, so the attestation repository's owner cannot silently rewrite it; rotating the
 *        workflow requires an owner transaction on this contract.
 *      - `event_name` must equal {expectedEventName} (`issues`). The `issues` trigger runs in the
 *        attestation repository's context while setting `actor_id` to the *external* account that
 *        opened the issue, which is what lets somebody prove a repository without granting this
 *        project any permission over it.
 *      - `actor_id` must equal the account being credited with the claim.
 *
 *      Dropping any one of those reintroduces impersonation.
 *
 *      This contract cannot check "does this account control that repository", and does not try.
 *      It checks that the answer came from the pinned workflow. How that workflow establishes
 *      control — repository ownership, a GitHub App confirming `admin`, or an admin-only topic
 *      challenge — is written up in ATTESTATION.md, and is a protocol concern rather than a
 *      contract one.
 *
 *      # Ownership
 *
 *      A repository registers exactly once, and the key is then freely transferable. Both halves are
 *      deliberate: royalties from the repository's market follow whoever holds the key, so it has to
 *      be tradeable, and re-registration must never exist, or a repository owner could yank the key
 *      back from someone who bought it. Rotating wallets is a transfer.
 *
 *      The owner of this contract can change the attestation source, and can therefore point it at a
 *      workflow it controls and mint any repository's key. It is the most powerful role in the
 *      system and belongs behind a multisig or a timelock.
 *
 *      # Metadata
 *
 *      Metadata is served fully on-chain as a base64 data URI and is immutable once minted, so
 *      ERC-4906 is not implemented. Only numeric ids are interpolated into the JSON, never a
 *      repository name or owner login, which is what makes the encoding injection-free without a
 *      charset validator.
 */
contract RIK is ERC721, Ownable2Step {
    /// @dev The only trigger that runs here while naming an external account as the actor.
    string private constant _EXPECTED_EVENT = "issues";

    /// @dev Left-aligned lookup word for {_addressText}.
    bytes32 private constant _HEX_DIGITS = "0123456789abcdef";

    /// @dev Avatars are addressable by account id, so the image needs no stored string.
    string private constant _AVATAR_BASE_URI = "https://avatars.githubusercontent.com/u/";
    /// @dev GitHub has no id-addressable HTML page for a repository; the REST resource is the only
    ///      link that survives a rename, which is the property this record is built on.
    string private constant _REPOSITORY_BASE_URI = "https://api.github.com/repositories/";

    /**
     * @dev The registration record. Four `uint64` fields share one slot, so a registration costs a
     *      single storage write. The wallet is not stored here; it is the ERC-721 owner, and it
     *      changes on every transfer.
     */
    struct Repo {
        uint64 githubRepoId; // == tokenId -> kept for clarity
        uint64 githubOwnerId; // account or organisation that owned the repository at mint
        uint64 githubActorId; // account that opened the issue and was credited with the claim
        uint64 registeredAt; // block.timestamp -> truncated at uint64
    }

    /**
     * @dev Emitted once per repository, when its key is minted.
     *
     * `registrant` is whoever paid for the transaction and holds no authority; the key goes to
     * `wallet`, which the proof names. It is indexed so a relayer can find the registrations it
     * funded, and it is not stored, because the mint {IERC721-Transfer} already records the holder.
     */
    event RepoRegistered(
        uint256 indexed githubRepoId,
        address indexed wallet,
        address indexed registrant,
        uint64 githubOwnerId,
        uint64 githubActorId,
        uint64 registeredAt
    );
    event AttestationRepoSet(uint64 indexed githubRepoId);
    event JobWorkflowRefSet(string jobWorkflowRef);

    error InvalidVerifier();
    error AttestationSourceNotConfigured();
    error InvalidGithubRepoId(uint256 githubRepoId);
    error InvalidGithubOwnerId(uint256 githubOwnerId);
    error InvalidGithubActorId(uint256 githubActorId);
    error AlreadyRegistered(uint256 githubRepoId);
    error NotRegistered(uint256 tokenId);

    IJwtVerifier private immutable _jwt;

    uint64 private _attestationRepoId;
    string private _jobWorkflowRef;

    mapping(uint256 tokenId => Repo repo) private _repos;

    /**
     * @dev Sets the initial owner and the JWT verifier. The attestation source must still be
     *      configured through {setAttestationRepoId} and {setJobWorkflowRef} before any
     *      registration can succeed.
     *
     * The verifier is immutable, so pointing at a different one means deploying a different
     * registry, which is why a zero address is rejected here rather than discovered on the first
     * failed registration.
     *
     * Requirements:
     *
     * - `jwt_` must not be the zero address.
     */
    constructor(address initialOwner, IJwtVerifier jwt_)
        ERC721("Repository Identity Key", "RIK")
        Ownable(initialOwner)
    {
        if (address(jwt_) == address(0)) revert InvalidVerifier();
        _jwt = jwt_;
    }

    /**
     * @dev Registers the GitHub repository `githubRepoId` and mints its key to `wallet`.
     *
     * Anyone may submit this call. The proof itself names its beneficiary through the `aud` claim,
     * so a relayer can pay the gas without being able to redirect the key. That is what makes
     * registration free for the repository owner.
     *
     * Requirements:
     *
     * - The attestation source must be configured.
     * - `kid`, `signature`, the issuer and the active window must satisfy {IJwtVerifier}.
     * - The payload must carry `aud`, `actor_id`, `repository_id`, `event_name` and
     *   `job_workflow_ref` matching {audienceOf}, `githubActorId` and the configured attestation
     *   source.
     * - `githubRepoId`, `githubOwnerId` and `githubActorId` must be non-zero and fit in `uint64`.
     * - `githubRepoId` must not already be registered.
     *
     * Emits a {RepoRegistered} event and an {IERC721-Transfer} event from the zero address.
     */
    function register(
        bytes32 kid,
        bytes calldata headerB64,
        bytes calldata payloadB64,
        bytes calldata signature,
        uint256 githubRepoId,
        uint256 githubOwnerId,
        uint256 githubActorId,
        address wallet
    ) external virtual {
        bytes memory payload = _jwt.verifyGithubOidc(kid, headerB64, payloadB64, signature);
        _verifyClaims(payload, githubRepoId, githubOwnerId, githubActorId, wallet);
        _register(githubRepoId, githubOwnerId, githubActorId, wallet, _msgSender());
    }

    /**
     * @dev Returns the verifier this contract trusts for GitHub OIDC signatures.
     */
    function jwt() public view virtual returns (IJwtVerifier) {
        return _jwt;
    }

    /**
     * @dev Returns the GitHub repository id proofs must originate from.
     */
    function attestationRepoId() public view virtual returns (uint64) {
        return _attestationRepoId;
    }

    /**
     * @dev Returns the exact `job_workflow_ref` proofs must carry.
     */
    function jobWorkflowRef() public view virtual returns (string memory) {
        return _jobWorkflowRef;
    }

    /**
     * @dev Returns the GitHub Actions event name proofs must carry.
     */
    function expectedEventName() public pure virtual returns (string memory) {
        return _EXPECTED_EVENT;
    }

    /**
     * @dev Returns the exact `aud` claim a proof must carry to register this triple.
     *
     * Public because it is the single source of truth for the encoding: the attestation workflow
     * asks this contract what audience to request rather than reimplementing the format, so the two
     * cannot drift apart.
     */
    function audienceOf(address wallet, uint256 githubRepoId, uint256 githubOwnerId)
        public
        pure
        virtual
        returns (string memory)
    {
        return string.concat(
            _addressText(wallet), ":", Strings.toString(githubRepoId), ":", Strings.toString(githubOwnerId)
        );
    }

    /**
     * @dev Returns the RIK token id for a GitHub repository id.
     *
     * Identity mapping, stated explicitly so callers do not have to remember the equality. GitHub
     * account ids and repository ids share one numeric range, so never feed an account id here.
     */
    function tokenIdOf(uint64 githubRepoId) public pure virtual returns (uint256) {
        return uint256(githubRepoId);
    }

    /**
     * @dev Returns whether `githubRepoId` has been registered.
     */
    function isRegistered(uint256 githubRepoId) public view virtual returns (bool) {
        return _ownerOf(githubRepoId) != address(0);
    }

    /**
     * @dev Returns the registration record for `tokenId`.
     *
     * Requirements:
     *
     * - `tokenId` must be registered.
     */
    function repoOf(uint256 tokenId) public view virtual returns (Repo memory) {
        if (_ownerOf(tokenId) == address(0)) revert NotRegistered(tokenId);
        return _repos[tokenId];
    }

    /**
     * @dev Returns the metadata URI for `tokenId` as an on-chain base64 JSON data URI.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireOwned(tokenId);
        return _render(tokenId);
    }

    /**
     * @dev Sets the GitHub repository id proofs must originate from.
     *
     * Requirements:
     *
     * - The caller must be the contract owner.
     *
     * Emits an {AttestationRepoSet} event.
     */
    function setAttestationRepoId(uint64 githubRepoId) external virtual onlyOwner {
        _setAttestationRepoId(githubRepoId);
    }

    /**
     * @dev Sets the exact `job_workflow_ref` proofs must carry.
     *
     * Requirements:
     *
     * - The caller must be the contract owner.
     *
     * Emits a {JobWorkflowRefSet} event.
     */
    function setJobWorkflowRef(string calldata ref) external virtual onlyOwner {
        _setJobWorkflowRef(ref);
    }

    /**
     * @dev Single mutation choke point for the attestation repository id.
     *
     * Emits an {AttestationRepoSet} event.
     */
    function _setAttestationRepoId(uint64 githubRepoId) internal virtual {
        _attestationRepoId = githubRepoId;
        emit AttestationRepoSet(githubRepoId);
    }

    /**
     * @dev Single mutation choke point for the pinned workflow ref.
     *
     * Emits a {JobWorkflowRefSet} event.
     */
    function _setJobWorkflowRef(string memory ref) internal virtual {
        _jobWorkflowRef = ref;
        emit JobWorkflowRefSet(ref);
    }

    /**
     * @dev Single mutation choke point for registrations. Mints the key and records the repository.
     *
     * Requirements:
     *
     * - `githubRepoId`, `githubOwnerId` and `githubActorId` must be non-zero and fit in `uint64`.
     * - `githubRepoId` must not already be registered.
     *
     * Emits a {RepoRegistered} event.
     */
    function _register(
        uint256 githubRepoId,
        uint256 githubOwnerId,
        uint256 githubActorId,
        address wallet,
        address registrant
    ) internal virtual {
        if (githubRepoId == 0 || githubRepoId > type(uint64).max) {
            revert InvalidGithubRepoId(githubRepoId);
        }
        if (githubOwnerId == 0 || githubOwnerId > type(uint64).max) revert InvalidGithubOwnerId(githubOwnerId);
        if (githubActorId == 0 || githubActorId > type(uint64).max) revert InvalidGithubActorId(githubActorId);
        if (_ownerOf(githubRepoId) != address(0)) revert AlreadyRegistered(githubRepoId);

        // A uint64 Unix timestamp remains valid far beyond any practical lifetime of this contract.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 registeredAt = uint64(block.timestamp);
        _repos[githubRepoId] = Repo({
            // Every cast is safe because the ids are bounded above.
            // forge-lint: disable-next-line(unsafe-typecast)
            githubRepoId: uint64(githubRepoId),
            // forge-lint: disable-next-line(unsafe-typecast)
            githubOwnerId: uint64(githubOwnerId),
            // forge-lint: disable-next-line(unsafe-typecast)
            githubActorId: uint64(githubActorId),
            registeredAt: registeredAt
        });

        emit RepoRegistered(
            githubRepoId,
            wallet,
            registrant,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64(githubOwnerId),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64(githubActorId),
            registeredAt
        );

        // `_safeMint` rather than `_mint`, because this key is transferable and valuable: minting
        // one into a contract that cannot move ERC-721s would strand a repository's market and its
        // royalties permanently, and a registration that reverts costs nothing but a re-run.
        //
        // The receiver hook it introduces runs after every state change above, so a reentrant
        // `register` sees a fully consistent registry and is rejected by the {AlreadyRegistered}
        // check for this repository. Registering a *different* repository from inside the hook is
        // legitimate and deliberately still allowed, which is why there is no reentrancy guard.
        // Also reverts on a zero `wallet`.
        _safeMint(wallet, githubRepoId);
    }

    /**
     * @dev Reverts unless the payload proves that the pinned attestation workflow, run here by
     *      `githubActorId` opening an issue, asked to bind `githubRepoId` to `wallet`.
     */
    function _verifyClaims(
        bytes memory payload,
        uint256 githubRepoId,
        uint256 githubOwnerId,
        uint256 githubActorId,
        address wallet
    ) internal view virtual {
        uint64 repoId = _attestationRepoId;
        string memory workflowRef = _jobWorkflowRef;
        if (repoId == 0 || bytes(workflowRef).length == 0) revert AttestationSourceNotConfigured();

        // The whole claim, in the one field a workflow controls: which wallet, which repository,
        // which owner. Everything else below exists to prove this string came from reviewed code.
        ClaimMatcher.requireStringClaim(payload, "aud", audienceOf(wallet, githubRepoId, githubOwnerId));
        // The GitHub account that opened the issue, set by GitHub rather than by the workflow.
        ClaimMatcher.requireStringClaim(payload, "actor_id", Strings.toString(githubActorId));
        // Together these three pin the code that chose `aud` to the reviewed attestation workflow.
        ClaimMatcher.requireStringClaim(payload, "repository_id", Strings.toString(uint256(repoId)));
        ClaimMatcher.requireStringClaim(payload, "event_name", _EXPECTED_EVENT);
        ClaimMatcher.requireStringClaim(payload, "job_workflow_ref", workflowRef);
    }

    /**
     * @dev Returns the lowercase `0x`-prefixed hex form of `wallet`.
     *
     * Semantically `Strings.toHexString(uint160(wallet), 20)`. That costs around 10.7k gas because
     * it writes one bounds-checked byte at a time through a `bytes` index, and this sits on the hot
     * path of the only state-changing function this contract has, so the 42 bytes are written
     * directly instead. A differential fuzz test pins it against {Strings}.
     */
    function _addressText(address wallet) internal pure virtual returns (string memory text) {
        assembly ("memory-safe") {
            text := mload(0x40)
            // 32 bytes of length plus 42 of text, rounded up to whole words.
            mstore(0x40, add(text, 0x60))
            mstore(text, 42)

            let ptr := add(text, 0x20)
            // Clear the second word first, so the 22 bytes past the end of the string are never
            // whatever the allocator happened to be sitting on.
            mstore(add(ptr, 0x20), 0)
            mstore8(ptr, 0x30) // "0"
            mstore8(add(ptr, 1), 0x78) // "x"

            // Nibbles are emitted least significant first, so the cursor walks backwards.
            let value := wallet
            for { let i := 41 } gt(i, 1) { i := sub(i, 1) } {
                mstore8(add(ptr, i), byte(and(value, 0xf), _HEX_DIGITS))
                value := shr(4, value)
            }
        }
    }

    /**
     * @dev Renders on-chain metadata as a base64 JSON data URI.
     *
     * Every interpolated value is a decimal number produced by {Strings}, so the JSON cannot be
     * broken out of. Keep it that way: a repository name or owner login would need escaping.
     */
    function _render(uint256 tokenId) internal view virtual returns (string memory) {
        Repo memory repo = _repos[tokenId];
        string memory id = Strings.toString(tokenId);
        string memory ownerId = Strings.toString(uint256(repo.githubOwnerId));

        // Built in two halves. One long concatenation exhausts the stack once the optimizer is
        // enabled without via-ir, which would make the build configuration a trap for later.
        string memory head = string.concat(
            '{"name":"RIK #',
            id,
            '","description":"Repository Identity Key. Proves control of GitHub repository ',
            id,
            ', through a GitHub Actions OIDC attestation.","image":"',
            _AVATAR_BASE_URI,
            ownerId,
            '","external_url":"',
            _REPOSITORY_BASE_URI,
            id,
            '"'
        );

        string memory attributes = string.concat(
            ',"attributes":[{"trait_type":"GitHub Repository ID","value":"',
            id,
            '"},{"trait_type":"GitHub Owner ID","value":"',
            ownerId,
            '"},{"trait_type":"Claimed By GitHub User ID","value":"',
            Strings.toString(uint256(repo.githubActorId)),
            '"},{"display_type":"date","trait_type":"Registered At","value":',
            Strings.toString(uint256(repo.registeredAt)),
            "}]}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(string.concat(head, attributes))));
    }
}
