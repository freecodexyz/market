// test/OidcFixture.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/**
 * @dev Shared loader for the signed OIDC fixtures produced by `test/fixtures/load-fixture.mjs`.
 *
 * Fixtures are generated rather than committed as blobs so a negative case is a small JSON file
 * instead of a hand-crafted token, and so every payload is a real RSA signature over a realistic
 * GitHub Actions claim set.
 *
 * The token is the one an `issues` run in the attestation repository produces: `attestationRepoId`
 * and `jobWorkflowRef` describe this project, `actorId` is whoever opened the issue, and the
 * repository being claimed appears only inside `audience`.
 */
abstract contract OidcFixture is Test {
    struct Fixture {
        bytes32 kid;
        bytes headerB64;
        bytes payloadB64;
        bytes signature;
        bytes modulus;
        bytes exponent;
        address wallet;
        uint256 repoId;
        uint256 ownerId;
        uint256 actorId;
        uint256 attestationRepoId;
        string jobWorkflowRef;
        string audience;
        string eventName;
        uint256 exp;
        uint256 nbf;
    }

    /// @dev Loads `name` with the values baked into the fixture file.
    function _fixture(string memory name) internal returns (Fixture memory f) {
        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "test/fixtures/load-fixture.mjs";
        inputs[2] = string.concat("test/fixtures/", name);

        f = _runFixture(inputs);
    }

    /// @dev Loads `name`, overriding the repository being claimed, its owner, the account claiming
    ///      it, and the wallet the key is bound to.
    function _fixture(string memory name, uint256 repoId, uint256 ownerId, uint256 actorId, address wallet)
        internal
        returns (Fixture memory f)
    {
        string[] memory inputs = new string[](7);
        inputs[0] = "node";
        inputs[1] = "test/fixtures/load-fixture.mjs";
        inputs[2] = string.concat("test/fixtures/", name);
        inputs[3] = vm.toString(repoId);
        inputs[4] = vm.toString(ownerId);
        inputs[5] = vm.toString(actorId);
        inputs[6] = vm.toString(wallet);

        f = _runFixture(inputs);
    }

    /// @dev Decodes a base64 JSON token URI, proving it parses, and returns it for `vm.parseJson*`.
    ///      `attributes` are flattened to `trait_<trait_type>` keys.
    function _decodeTokenURI(string memory uri) internal returns (string memory) {
        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "test/fixtures/decode-token-uri.mjs";
        inputs[2] = uri;

        return string(vm.ffi(inputs));
    }

    function _runFixture(string[] memory inputs) private returns (Fixture memory f) {
        string memory json = string(vm.ffi(inputs));
        f.kid = vm.parseJsonBytes32(json, ".kid");
        f.headerB64 = bytes(vm.parseJsonString(json, ".headerB64"));
        f.payloadB64 = bytes(vm.parseJsonString(json, ".payloadB64"));
        f.signature = vm.parseJsonBytes(json, ".signature");
        f.modulus = vm.parseJsonBytes(json, ".modulus");
        f.exponent = vm.parseJsonBytes(json, ".exponent");
        f.wallet = vm.parseJsonAddress(json, ".wallet");
        // Carried as strings so an id at the uint64 boundary stays exact; see load-fixture.mjs.
        f.repoId = vm.parseUint(vm.parseJsonString(json, ".repoId"));
        f.ownerId = vm.parseUint(vm.parseJsonString(json, ".ownerId"));
        f.actorId = vm.parseUint(vm.parseJsonString(json, ".actorId"));
        f.attestationRepoId = vm.parseUint(vm.parseJsonString(json, ".attestationRepoId"));
        f.jobWorkflowRef = vm.parseJsonString(json, ".jobWorkflowRef");
        f.audience = vm.parseJsonString(json, ".audience");
        f.eventName = vm.parseJsonString(json, ".eventName");
        f.exp = vm.parseJsonUint(json, ".exp");
        f.nbf = vm.parseJsonUint(json, ".nbf");
    }
}
