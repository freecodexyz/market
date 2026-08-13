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
 *      Registration is triggered by an issue opened on the attestation repository. The claimant
 *      commits nothing to the repository being claimed, installs nothing, and does not submit the
 *      transaction; a relayer does.
 *
 *      The proof is therefore produced by a workflow running in the attestation repository, so
 *      `repository_id` identifies that repository and `actor_id` identifies the account that opened
 *      the issue. Neither describes the repository being claimed. Every claim in an Actions OIDC
 *      token is set by GitHub except `aud`, which is an arbitrary string supplied by the workflow
 *      when it requests the token. `aud` therefore carries the claim being made:
 *
 *          aud = "<wallet>:<repositoryId>:<ownerId>"
 *
 *      The remaining checks establish that this string was produced by reviewed code:
 *
 *      - `repository_id` must equal {attestationRepoId}. Without it, the attestation workflow could
 *        be invoked as a reusable workflow from another repository, which would let the caller
 *        choose `aud`.
 *      - `job_workflow_ref` must equal {jobWorkflowRef}. This pins the file and ref that produced
 *        `aud`. Rotating the workflow requires an owner transaction on this contract.
 *      - `event_name` must equal {expectedEventName} (`issues`). The `issues` trigger runs in the
 *        attestation repository's context while setting `actor_id` to the external account that
 *        opened the issue, so a claimant can prove a repository without granting this project any
 *        permission over it.
 *      - `actor_id` must equal the account credited with the claim.
 *
 *      Removing any one of these checks permits impersonation.
 *
 *      This contract does not determine whether an account controls a repository. It verifies that
 *      the answer originated from the pinned workflow. How that workflow establishes control —
 *      repository ownership, a GitHub App confirming `admin`, or an admin-only topic challenge — is
 *      documented in ATTESTATION.md and is out of scope for the contract.
 *
 *      # Ownership
 *
 *      A repository registers exactly once and the key is then transferable. Royalties from the
 *      repository's market follow the current holder, so the key must be tradeable; re-registration
 *      must not exist, or a repository owner could reclaim a key that has been sold. Rotating
 *      wallets is done by transferring the key.
 *
 *      The owner of this contract can change the attestation source, and can therefore point it at
 *      a workflow it controls and mint any repository's key. This is the highest-privilege role in
 *      the system and should be held by a multisig or timelock.
 *
 *      # Metadata
 *
 *      Metadata is served on-chain as a base64 data URI and is immutable once minted, so ERC-4906 is
 *      not implemented. Only numeric ids are interpolated into the JSON, never a repository name or
 *      owner login, so no escaping or charset validation is required.
 */
contract RIK is ERC721, Ownable2Step {
    /// @dev The only trigger that runs in this repository while naming an external account as the actor.
    string private constant _EXPECTED_EVENT = "issues";

    /// @dev Left-aligned lookup word for {_addressText}.
    bytes32 private constant _HEX_DIGITS = "0123456789abcdef";

    /// @dev Avatars are addressable by account id, so the image needs no stored string.
    string private constant _AVATAR_BASE_URI = "https://avatars.githubusercontent.com/u/";
    /// @dev GitHub has no id-addressable HTML page for a repository. The REST resource is the only
    ///      link addressable by id, and therefore the only one that survives a rename.
    string private constant _REPOSITORY_BASE_URI = "https://api.github.com/repositories/";

    /**
     * @dev The registration record. Four `uint64` fields occupy one slot, so a registration costs a
     *      single storage write. The wallet is not stored here; it is the ERC-721 owner and changes
     *      on transfer.
     */
    struct Repo {
        uint64 githubRepoId; // == tokenId -> kept for clarity
        uint64 githubOwnerId; // account or organisation owning the repository at mint
        uint64 githubActorId; // account that opened the issue and was credited with the claim
        uint64 registeredAt; // block.timestamp -> truncated at uint64
    }

    /**
     * @dev Emitted once per repository, when its key is minted.
     *
     * `registrant` is the account that paid for the transaction and holds no authority. The key is
     * minted to `wallet`, which the proof names. `registrant` is indexed so a relayer can find the
     * registrations it funded, and is not stored because the mint {IERC721-Transfer} already
     * records the holder.
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
     * The verifier is immutable, so using a different one requires deploying a new registry. A zero
     * address is rejected here rather than surfacing as a failure on the first registration.
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
     * Anyone may submit this call. The proof names its beneficiary through the `aud` claim, so a
     * relayer can pay the gas without being able to redirect the key.
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
     * Public so that the attestation workflow can query the encoding rather than reimplementing it.
     * This contract is the single definition of the format.
     */
    function audienceOf(address wallet, uint256 githubRepoId, uint256 githubOwnerId)
        public
        pure
        virtual
        returns (string memory audience)
    {
        // Equivalent to `string.concat(_addressText(wallet), ":", toString(repoId), ":",
        // toString(ownerId))`, built in a single pass rather than four allocations and a copy.
        // `testFuzz_AudienceIsTheConcatenation` compares the two.
        //
        // Written right to left because a decimal number's length is not known until it has been
        // divided out. 256 bytes covers the worst case: 42 for the address, two separators, two
        // decimal numbers of at most 78 digits, and the length word.
        assembly ("memory-safe") {
            let buffer := mload(0x40)
            let end := add(buffer, 0x100)
            let cursor := end

            // Writes the digits of `value`, least significant first, moving the cursor backwards.
            function writeDecimal(to, value) -> at {
                at := to
                for {} 1 {} {
                    at := sub(at, 1)
                    mstore8(at, add(48, mod(value, 10)))
                    value := div(value, 10)
                    if iszero(value) { break }
                }
            }

            cursor := writeDecimal(cursor, githubOwnerId)
            cursor := sub(cursor, 1)
            mstore8(cursor, 0x3a) // ":"

            cursor := writeDecimal(cursor, githubRepoId)
            cursor := sub(cursor, 1)
            mstore8(cursor, 0x3a) // ":"

            let value := wallet
            for { let i := 0 } lt(i, 40) { i := add(i, 1) } {
                cursor := sub(cursor, 1)
                mstore8(cursor, byte(and(value, 0xf), _HEX_DIGITS))
                value := shr(4, value)
            }

            cursor := sub(cursor, 1)
            mstore8(cursor, 0x78) // "x"
            cursor := sub(cursor, 1)
            mstore8(cursor, 0x30) // "0"

            // The length word is written immediately before the text, which remains inside the
            // allocated region: the worst case leaves 24 bytes of head room.
            audience := sub(cursor, 0x20)
            mstore(audience, sub(end, cursor))
            mstore(0x40, end)
        }
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

        // `_safeMint` rather than `_mint`: the key is transferable and carries the repository's
        // royalties, so minting into a contract that cannot transfer an ERC-721 would strand them
        // permanently. A reverted registration can simply be retried.
        //
        // The receiver hook runs after every state change above, so a reentrant `register` for this
        // repository observes a consistent registry and is rejected by the {AlreadyRegistered}
        // check. Registering a different repository from inside the hook is valid and remains
        // permitted, which is why no reentrancy guard is applied. `_safeMint` also reverts on a
        // zero `wallet`.
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

        // Checked in the order GitHub emits them so the scan makes one pass over the payload rather
        // than restarting for each claim. Correctness is independent of the order, because a claim
        // positioned before the cursor is found on the wrap. See {ClaimMatcher-indexOfFrom}.
        uint256 cursor = 0;

        // The claim being made: wallet, repository and owner. The checks that follow establish that
        // this string was produced by reviewed code.
        cursor = ClaimMatcher.requireStringClaimFrom(
            payload, "aud", audienceOf(wallet, githubRepoId, githubOwnerId), cursor
        );
        // With the workflow ref, pins the code that produced `aud` to the attestation workflow.
        cursor = ClaimMatcher.requireStringClaimFrom(payload, "repository_id", _decimalText(uint256(repoId)), cursor);
        // Set by GitHub, not by the workflow.
        cursor = ClaimMatcher.requireStringClaimFrom(payload, "actor_id", _decimalText(githubActorId), cursor);
        cursor = ClaimMatcher.requireStringClaimFrom(payload, "event_name", _EXPECTED_EVENT, cursor);
        // Final claim: there is no subsequent scan to seed, so the cursor is discarded.
        // slither-disable-next-line unused-return
        ClaimMatcher.requireStringClaimFrom(payload, "job_workflow_ref", workflowRef, cursor);
    }

    /**
     * @dev Returns the decimal form of `value`.
     *
     * Equivalent to `Strings.toString`, which writes one bounds-checked byte at a time through a
     * `bytes` index. Two conversions occur on the registration path.
     * `testFuzz_DecimalTextMatchesStrings` compares the two implementations.
     */
    function _decimalText(uint256 value) internal pure virtual returns (string memory text) {
        assembly ("memory-safe") {
            let buffer := mload(0x40)
            // 32 for the length word and 78 for the widest uint256, rounded to whole words.
            let end := add(buffer, 0x80)
            let cursor := end

            for {} 1 {} {
                cursor := sub(cursor, 1)
                mstore8(cursor, add(48, mod(value, 10)))
                value := div(value, 10)
                if iszero(value) { break }
            }

            text := sub(cursor, 0x20)
            mstore(text, sub(end, cursor))
            mstore(0x40, end)
        }
    }

    /**
     * @dev Returns the lowercase `0x`-prefixed hex form of `wallet`.
     *
     * Equivalent to `Strings.toHexString(uint160(wallet), 20)`, which costs roughly 10.7k gas
     * because it writes one bounds-checked byte at a time through a `bytes` index.
     *
     * No longer called by this contract: {audienceOf} writes the address, separators and both
     * numbers in a single pass. It is retained as the reference implementation that
     * `testFuzz_AudienceIsTheConcatenation` compares against. solc removes unreferenced internal
     * functions, so the deployed bytecode is unchanged by its presence.
     */
    // slither-disable-next-line dead-code
    function _addressText(address wallet) internal pure virtual returns (string memory text) {
        assembly ("memory-safe") {
            text := mload(0x40)
            // 32 bytes of length plus 42 of text, rounded up to whole words.
            mstore(0x40, add(text, 0x60))
            mstore(text, 42)

            let ptr := add(text, 0x20)
            // Clear the second word first so the 22 bytes past the end of the string are zero
            // rather than whatever the allocator last left there.
            mstore(add(ptr, 0x20), 0)
            mstore8(ptr, 0x30) // "0"
            mstore8(add(ptr, 1), 0x78) // "x"

            // Nibbles are emitted least significant first, so the cursor moves backwards.
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
     * escaped out of. Interpolating a repository name or owner login would require escaping.
     */
    function _render(uint256 tokenId) internal view virtual returns (string memory) {
        Repo memory repo = _repos[tokenId];
        string memory id = Strings.toString(tokenId);
        string memory ownerId = Strings.toString(uint256(repo.githubOwnerId));

        // Built in two halves: a single long concatenation exhausts the stack when the optimizer is
        // enabled without via-ir.
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
