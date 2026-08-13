// src/RIK.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

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
 *      A GitHub Actions OIDC token is signed by GitHub and cannot be forged. GitHub sets
 *      `repository_id` from the repository the workflow actually ran in, so that claim is not
 *      something a caller can choose. But any workflow running in a repository may ask for any
 *      `aud`, which reduces the security of the whole scheme to one question:
 *
 *          who was allowed to start that workflow run?
 *
 *      This contract answers it with `event_name`. A proof is only accepted when it was produced by
 *      a `workflow_dispatch` run, and dispatching a workflow requires write access to the
 *      repository. Every other trigger fails that test while still running in the repository's own
 *      context: `issues`, `issue_comment`, `watch`, `fork` and `pull_request` can all be fired by an
 *      account with no permissions at all, so accepting one of them would let a stranger mint a
 *      repository's key to their own wallet.
 *
 *      The remaining claims pin the registration to a specific repository and owner:
 *
 *      - `repository_id` must equal the token being minted.
 *      - `repository_owner_id` must equal the account or organisation recorded alongside it.
 *      - `aud` must equal the wallet being bound, which the dispatching workflow chooses.
 *
 *      Dropping any one of those four checks reintroduces impersonation.
 *
 *      Unlike `UIK` in the `identity` repository there is no `job_workflow_ref` pin, because the
 *      registration workflow lives in the user's own repository and there is no single reviewed file
 *      to pin. `workflow_dispatch` carries the authorization instead.
 *
 *      Signature, issuer and validity-window checking is not done here. It is delegated to a
 *      deployed {IJwtVerifier}, which is the contract that mirrors GitHub's rotating JWKS.
 *
 *      # Ownership
 *
 *      A repository registers exactly once, and the key is then freely transferable. Both halves are
 *      deliberate: royalties from the repository's market follow whoever holds the key, so it has to
 *      be tradeable, and re-registration must never exist, or a repository owner could yank the key
 *      back from someone who bought it. Rotating wallets is a transfer.
 *
 *      This contract has no owner and no administrative function. Key rotation lives in the
 *      verifier; there is nothing here to configure after deployment.
 *
 *      # Metadata
 *
 *      Metadata is served fully on-chain as a base64 data URI and is immutable once minted, so
 *      ERC-4906 is not implemented. Only numeric ids are interpolated into the JSON, never a
 *      repository name or owner login, which is what makes the encoding injection-free without a
 *      charset validator.
 */
contract RIK is ERC721 {
    /// @dev The only GitHub Actions trigger that requires write access to the repository.
    string private constant _EXPECTED_EVENT = "workflow_dispatch";

    /// @dev Left-aligned lookup word for {_audienceOf}.
    bytes32 private constant _HEX_DIGITS = "0123456789abcdef";

    /// @dev Avatars are addressable by account id, so the image needs no stored string.
    string private constant _AVATAR_BASE_URI = "https://avatars.githubusercontent.com/u/";
    /// @dev GitHub has no id-addressable HTML page for a repository; the REST resource is the only
    ///      link that survives a rename, which is the property this record is built on.
    string private constant _REPOSITORY_BASE_URI = "https://api.github.com/repositories/";

    /**
     * @dev The registration record. Three `uint64` fields share one slot, so a registration costs a
     *      single storage write. The wallet is not stored here; it is the ERC-721 owner, and it
     *      changes on every transfer.
     */
    struct Repo {
        uint64 githubRepoId; // == tokenId -> kept for clarity
        uint64 githubOwnerId; // GitHub account or organisation that owned the repository at mint
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
        uint64 registeredAt
    );

    error InvalidVerifier();
    error InvalidGithubRepoId(uint256 githubRepoId);
    error InvalidGithubOwnerId(uint256 githubOwnerId);
    error AlreadyRegistered(uint256 githubRepoId);
    error NotRegistered(uint256 tokenId);

    IJwtVerifier private immutable _jwt;

    mapping(uint256 tokenId => Repo repo) private _repos;

    /**
     * @dev Sets the JWT verifier this registry trusts. It is immutable, so pointing at a different
     *      verifier means deploying a different registry, which is also why a zero address is
     *      rejected here rather than discovered on the first failed registration.
     *
     * Requirements:
     *
     * - `jwt_` must not be the zero address.
     */
    constructor(IJwtVerifier jwt_) ERC721("Repository Identity Key", "RIK") {
        if (address(jwt_) == address(0)) revert InvalidVerifier();
        _jwt = jwt_;
    }

    /**
     * @dev Registers the GitHub repository `githubRepoId` and mints its key to `wallet`.
     *
     * Anyone may submit this call. The proof itself names its beneficiary through the `aud` claim,
     * so a relayer can pay the gas without being able to redirect the key.
     *
     * Requirements:
     *
     * - `kid`, `signature`, the issuer and the active window must satisfy {IJwtVerifier}.
     * - The payload must carry `aud`, `repository_id`, `repository_owner_id` and `event_name`
     *   matching `wallet`, `githubRepoId`, `githubOwnerId` and {expectedEventName}.
     * - `githubRepoId` and `githubOwnerId` must be non-zero and fit in `uint64`.
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
        address wallet
    ) external virtual {
        bytes memory payload = _jwt.verifyGithubOidc(kid, headerB64, payloadB64, signature);
        _verifyClaims(payload, githubRepoId, githubOwnerId, wallet);
        _register(githubRepoId, githubOwnerId, wallet, _msgSender());
    }

    /**
     * @dev Returns the verifier this contract trusts for GitHub OIDC signatures.
     */
    function jwt() public view virtual returns (IJwtVerifier) {
        return _jwt;
    }

    /**
     * @dev Returns the GitHub Actions event name proofs must carry.
     */
    function expectedEventName() public pure virtual returns (string memory) {
        return _EXPECTED_EVENT;
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
     * @dev Single mutation choke point for registrations. Mints the key and records the repository.
     *
     * Requirements:
     *
     * - `githubRepoId` must be non-zero and fit in `uint64`.
     * - `githubOwnerId` must be non-zero and fit in `uint64`.
     * - `githubRepoId` must not already be registered.
     *
     * Emits a {RepoRegistered} event.
     */
    function _register(uint256 githubRepoId, uint256 githubOwnerId, address wallet, address registrant)
        internal
        virtual
    {
        if (githubRepoId == 0 || githubRepoId > type(uint64).max) revert InvalidGithubRepoId(githubRepoId);
        if (githubOwnerId == 0 || githubOwnerId > type(uint64).max) revert InvalidGithubOwnerId(githubOwnerId);
        if (_ownerOf(githubRepoId) != address(0)) revert AlreadyRegistered(githubRepoId);

        // A uint64 Unix timestamp remains valid far beyond any practical lifetime of this contract.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 registeredAt = uint64(block.timestamp);
        _repos[githubRepoId] = Repo({
            // Both casts are safe because the ids are bounded above.
            // forge-lint: disable-next-line(unsafe-typecast)
            githubRepoId: uint64(githubRepoId),
            // forge-lint: disable-next-line(unsafe-typecast)
            githubOwnerId: uint64(githubOwnerId),
            registeredAt: registeredAt
        });

        // forge-lint: disable-next-line(unsafe-typecast)
        emit RepoRegistered(githubRepoId, wallet, registrant, uint64(githubOwnerId), registeredAt);

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
     * @dev Reverts unless the payload proves that a `workflow_dispatch` run inside repository
     *      `githubRepoId`, owned by `githubOwnerId`, asked for `wallet` as its audience.
     */
    function _verifyClaims(bytes memory payload, uint256 githubRepoId, uint256 githubOwnerId, address wallet)
        internal
        pure
        virtual
    {
        // The address the key is minted to. Chosen by whoever dispatched the workflow.
        ClaimMatcher.requireStringClaim(payload, "aud", _audienceOf(wallet));
        // The repository the run happened in. Set by GitHub, never by the workflow.
        ClaimMatcher.requireStringClaim(payload, "repository_id", Strings.toString(githubRepoId));
        // Recorded so the key can be attributed to an account without storing a renameable login.
        ClaimMatcher.requireStringClaim(payload, "repository_owner_id", Strings.toString(githubOwnerId));
        // The whole proof of control: only write access can dispatch a workflow.
        ClaimMatcher.requireStringClaim(payload, "event_name", _EXPECTED_EVENT);
    }

    /**
     * @dev Returns the lowercase `0x`-prefixed hex form of `wallet`, which is what the `aud` claim
     *      carries.
     *
     * Semantically `Strings.toHexString(uint160(wallet), 20)`. That costs around 10.7k gas because
     * it writes one bounds-checked byte at a time through a `bytes` index, and this sits on the hot
     * path of the only state-changing function this contract has, so the 42 bytes are written
     * directly instead. A differential fuzz test pins it against {Strings}.
     */
    function _audienceOf(address wallet) internal pure virtual returns (string memory audience) {
        assembly ("memory-safe") {
            audience := mload(0x40)
            // 32 bytes of length plus 42 of text, rounded up to whole words.
            mstore(0x40, add(audience, 0x60))
            mstore(audience, 42)

            let ptr := add(audience, 0x20)
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
            '"},{"display_type":"date","trait_type":"Registered At","value":',
            Strings.toString(uint256(repo.registeredAt)),
            "}]}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(string.concat(head, attributes))));
    }
}
