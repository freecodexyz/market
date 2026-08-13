// src/GithubOidcVerifier.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {RSA} from "@openzeppelin/contracts/utils/cryptography/RSA.sol";

import {IJwtVerifier} from "./IJwtVerifier.sol";
import {JsonClaim} from "./JsonClaim.sol";

/**
 * @title GithubOidcVerifier
 * @notice Verifies GitHub Actions OIDC JWTs against the GitHub JWKS mirrored on-chain.
 *
 * @dev The registry holds the RSA signing keys GitHub publishes at
 *      `https://token.actions.githubusercontent.com/.well-known/jwks`. GitHub rotates them, so the
 *      owner mirrors the active set. Keys are addressed by `keccak256(bytes(kid))` rather than the
 *      raw `kid` string so the mapping key is fixed width.
 *
 *      This contract answers exactly one question: is this a currently valid, GitHub-signed OIDC
 *      token? It deliberately holds no opinion about the claims inside it; binding claims to
 *      meaning is the consumer's job.
 */
contract GithubOidcVerifier is IJwtVerifier, Ownable2Step {
    string private constant _EXPECTED_ISS = "https://token.actions.githubusercontent.com";

    struct RSAKey {
        bytes modulus;
        bytes exponent;
        bool active;
    }

    event KeyAdded(bytes32 indexed kid);
    event KeyRevoked(bytes32 indexed kid);

    error UnknownKid(bytes32 kid);
    error InvalidKey(bytes32 kid);
    error BadJwt();
    error TokenExpired();
    error TokenNotYetValid();

    mapping(bytes32 kid => RSAKey key) private _keys;

    /**
     * @dev Sets the initial registry owner.
     */
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IJwtVerifier
    function verifyGithubOidc(
        bytes32 kid,
        bytes calldata headerB64,
        bytes calldata payloadB64,
        bytes calldata signature
    ) external view virtual returns (bytes memory payload) {
        return _verifyGithubOidc(kid, headerB64, payloadB64, signature);
    }

    /**
     * @dev Returns the trusted GitHub Actions OIDC issuer.
     */
    function expectedIssuer() public pure virtual returns (string memory) {
        return _EXPECTED_ISS;
    }

    /**
     * @dev Returns the stored signing key for `kid`. An inactive key reads as `active == false`.
     */
    function keyOf(bytes32 kid) public view virtual returns (RSAKey memory) {
        return _keys[kid];
    }

    /**
     * @dev Adds or replaces an active GitHub Actions RSA signing key.
     *
     * Requirements:
     *
     * - The caller must be the contract owner.
     * - `modulus` and `exponent` must be non-empty.
     *
     * Emits a {KeyAdded} event.
     */
    function addKey(bytes32 kid, bytes calldata modulus, bytes calldata exponent) external virtual onlyOwner {
        if (modulus.length == 0 || exponent.length == 0) revert InvalidKey(kid);
        _updateKey(kid, modulus, exponent, true);
    }

    /**
     * @dev Revokes a GitHub Actions RSA signing key.
     *
     * Requirements:
     *
     * - The caller must be the contract owner.
     * - `kid` must currently be active.
     *
     * Emits a {KeyRevoked} event.
     */
    function revokeKey(bytes32 kid) external virtual onlyOwner {
        if (!_keys[kid].active) revert UnknownKid(kid);
        _updateKey(kid, "", "", false);
    }

    /**
     * @dev Single mutation choke point for the signing key registry.
     *
     * Deactivation keeps the stored modulus and exponent untouched so a revoked key remains
     * auditable; only the `active` flag gates verification.
     *
     * Emits a {KeyAdded} event when `active` is true, otherwise a {KeyRevoked} event.
     */
    function _updateKey(bytes32 kid, bytes memory modulus, bytes memory exponent, bool active) internal virtual {
        RSAKey storage key = _keys[kid];
        if (active) {
            key.modulus = modulus;
            key.exponent = exponent;
        }
        key.active = active;

        if (active) {
            emit KeyAdded(kid);
        } else {
            emit KeyRevoked(kid);
        }
    }

    /**
     * @dev Verifies `kid`, the RSA signature, the issuer and the active window, and returns the
     *      decoded payload.
     *
     * Requirements:
     *
     * - `kid` must identify an active signing key.
     * - `signature` must be a valid PKCS#1 v1.5 SHA-256 signature over `headerB64.payloadB64`.
     * - The payload issuer must equal {expectedIssuer}.
     * - The current block timestamp must fall inside `[nbf, exp]`.
     */
    function _verifyGithubOidc(
        bytes32 kid,
        bytes calldata headerB64,
        bytes calldata payloadB64,
        bytes calldata signature
    ) internal view virtual returns (bytes memory payload) {
        RSAKey memory key = _keys[kid];
        if (!key.active) revert UnknownKid(kid);

        bytes32 digest = sha256(bytes.concat(headerB64, ".", payloadB64));
        if (!RSA.pkcs1Sha256(digest, signature, key.exponent, key.modulus)) revert BadJwt();

        payload = bytes(Base64.decode(string(payloadB64)));

        JsonClaim.requireStringClaim(payload, "iss", _EXPECTED_ISS);
        _verifyActiveWindow(payload);
    }

    /**
     * @dev Reverts unless the current block timestamp falls inside the payload's `[nbf, exp]` window.
     */
    function _verifyActiveWindow(bytes memory payload) internal view virtual {
        uint256 exp_ = _requireUintClaim(payload, "exp");
        uint256 nbf_ = _requireUintClaim(payload, "nbf");

        // JWT validity must be checked against chain time; small validator timestamp drift is acceptable here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > exp_) revert TokenExpired();

        // JWT validity must be checked against chain time; small validator timestamp drift is acceptable here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < nbf_) revert TokenNotYetValid();
    }

    function _requireUintClaim(bytes memory payload, string memory key) internal pure returns (uint256 value) {
        bool found;
        (value, found) = _readUintClaim(payload, key);
        if (!found) revert JsonClaim.ClaimMissing(key);
    }

    function _readUintClaim(bytes memory payload, string memory key) internal pure returns (uint256 value, bool found) {
        bytes memory marker = abi.encodePacked('"', bytes(key), '":');
        int256 pos = JsonClaim.indexOf(payload, marker);

        if (pos < 0) return (0, false);

        // casting to uint256 is safe because negative positions returned above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 i = uint256(pos) + marker.length;
        uint256 valueStart = i;
        if (i == payload.length) return (0, false);

        while (i < payload.length) {
            uint8 c = uint8(payload[i]);
            if (c < 0x30 || c > 0x39) break; // -> not a digit
            value = value * 10 + (c - 0x30);
            ++i;
        }
        found = i > valueStart;
    }
}
