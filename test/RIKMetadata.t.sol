// test/RIKMetadata.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {GithubOidcVerifier} from "../src/GithubOidcVerifier.sol";
import {RIK} from "../src/RIK.sol";
import {OidcFixture} from "./OidcFixture.sol";

/**
 * @dev Metadata is asserted by decoding the data URI through `JSON.parse` in Node rather than by
 *      substring matching in Solidity, so malformed JSON fails loudly instead of passing quietly.
 */
contract RIKMetadata_T is OidcFixture {
    uint256 constant REPO_ID = 1296269;
    uint256 constant OWNER_ID = 583231;

    GithubOidcVerifier verifier;
    RIK rik;

    address alice = address(0x1111111111111111111111111111111111111111);
    address bob = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        verifier = new GithubOidcVerifier(address(this));
        rik = new RIK(verifier);
    }

    function _registered(uint256 repoId, uint256 ownerId, address wallet) internal {
        Fixture memory f = _fixture("sample-jwt.json", repoId, ownerId, wallet);
        verifier.addKey(f.kid, f.modulus, f.exponent);
        rik.register(f.kid, f.headerB64, f.payloadB64, f.signature, repoId, ownerId, wallet);
    }

    function _metadata(uint256 tokenId) internal returns (string memory) {
        return _decodeTokenURI(rik.tokenURI(tokenId));
    }

    // --- existence ----------------------------------------------------------

    function test_TokenURIRevertsForUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, REPO_ID));
        rik.tokenURI(REPO_ID);
    }

    function test_TokenURIIsABase64JsonDataUri() public {
        _registered(REPO_ID, OWNER_ID, alice);

        string memory uri = rik.tokenURI(REPO_ID);
        assertTrue(bytes(uri).length > 0);
        // Decoding also proves it parses as JSON.
        assertTrue(bytes(_decodeTokenURI(uri)).length > 0);
    }

    // --- content ------------------------------------------------------------

    function test_MetadataNamesTheRepositoryById() public {
        _registered(REPO_ID, OWNER_ID, alice);

        assertEq(vm.parseJsonString(_metadata(REPO_ID), ".name"), "RIK #1296269");
    }

    function test_MetadataDescribesTheProof() public {
        _registered(REPO_ID, OWNER_ID, alice);

        assertEq(
            vm.parseJsonString(_metadata(REPO_ID), ".description"),
            "Repository Identity Key. Proves control of GitHub repository 1296269, through a GitHub Actions OIDC attestation."
        );
    }

    /// @dev GitHub serves avatars by account id, so the image needs no stored string.
    function test_MetadataImageIsTheOwnerAvatar() public {
        _registered(REPO_ID, OWNER_ID, alice);

        assertEq(vm.parseJsonString(_metadata(REPO_ID), ".image"), "https://avatars.githubusercontent.com/u/583231");
    }

    /// @dev The REST resource is the only GitHub link addressable by repository id, which is what
    ///      keeps it correct after a rename.
    function test_MetadataExternalUrlIsIdAddressable() public {
        _registered(REPO_ID, OWNER_ID, alice);

        assertEq(vm.parseJsonString(_metadata(REPO_ID), ".external_url"), "https://api.github.com/repositories/1296269");
    }

    function test_MetadataCarriesIdentifierTraits() public {
        _registered(REPO_ID, OWNER_ID, alice);
        string memory json = _metadata(REPO_ID);

        assertEq(vm.parseJsonString(json, ".trait_github_repository_id"), "1296269");
        assertEq(vm.parseJsonString(json, ".trait_github_owner_id"), "583231");
    }

    function test_MetadataCarriesRegistrationDate() public {
        vm.warp(1_700_000_000);
        _registered(REPO_ID, OWNER_ID, alice);

        assertEq(vm.parseJsonString(_metadata(REPO_ID), ".trait_registered_at"), "1700000000");
    }

    // --- immutability -------------------------------------------------------

    /// @dev Nothing in the metadata depends on the holder, which is why this contract does not
    ///      implement ERC-4906: there is never anything for an indexer to refresh.
    function test_MetadataIsUnchangedByTransfer() public {
        _registered(REPO_ID, OWNER_ID, alice);
        string memory before = rik.tokenURI(REPO_ID);

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        assertEq(rik.tokenURI(REPO_ID), before);
    }

    function test_DistinctRepositoriesRenderDistinctMetadata() public {
        _registered(111, OWNER_ID, alice);
        _registered(222, OWNER_ID, alice);

        assertNotEq(rik.tokenURI(111), rik.tokenURI(222));
    }

    // --- fuzz ---------------------------------------------------------------

    /// @dev Only decimal numbers reach the JSON, so no identifier can break the encoding. This is
    ///      what removes the need for the charset validation `UIK` has to do on a login.
    /// forge-config: default.fuzz.runs = 8
    /// forge-config: deep.fuzz.runs = 32
    function testFuzz_MetadataAlwaysParses(uint64 repoId, uint64 ownerId) public {
        vm.assume(repoId != 0);
        vm.assume(ownerId != 0);

        _registered(uint256(repoId), uint256(ownerId), alice);
        string memory json = _metadata(uint256(repoId));

        assertEq(vm.parseJsonString(json, ".trait_github_repository_id"), Strings.toString(uint256(repoId)));
        assertEq(vm.parseJsonString(json, ".trait_github_owner_id"), Strings.toString(uint256(ownerId)));
    }
}
