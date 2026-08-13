// test/RIKRegistry.invariant.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {GithubOidcVerifier} from "../src/GithubOidcVerifier.sol";
import {RIK} from "../src/RIK.sol";
import {OidcFixture} from "./OidcFixture.sol";

/// @dev A signed proof, generated once in `setUp` so the campaign never shells out to Node.
struct Proof {
    bytes32 kid;
    bytes header;
    bytes payload;
    bytes signature;
    uint256 repoId;
    uint256 ownerId;
    uint256 actorId;
    address wallet;
}

/**
 * @dev Drives registration and transfer with real proofs, correct and incorrect.
 *
 * Every attempt is swallowed, so it is the invariants and not the handler that carry the proof. The
 * handler records what it believes should be true about each repository at the moment it succeeds,
 * and the invariants then hold the contract to that record for the rest of the campaign.
 */
contract RegistryHandler is Test {
    RIK private immutable _rik;

    Proof[] private _proofs;
    uint256[] private _repoIds;
    address[4] private _actors;

    mapping(uint256 repoId => bool seen) public everRegistered;
    mapping(uint256 repoId => uint256 ownerId) public expectedOwnerId;
    mapping(uint256 repoId => uint256 timestamp) public expectedRegisteredAt;

    uint256 public registeredCount;
    uint256 public registerCalls;
    uint256 public registerAttempts;
    uint256 public rejectedAttempts;
    uint256 public transferAttempts;

    /// @dev Set if a registration that must fail ever succeeded. Nothing should ever set it.
    bool public forbiddenRegistrationSucceeded;

    constructor(RIK rik_, Proof[] memory proofs_) {
        _rik = rik_;
        for (uint256 i = 0; i < proofs_.length; ++i) {
            _proofs.push(proofs_[i]);
            _repoIds.push(proofs_[i].repoId);
        }
        _actors = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
    }

    function repoIdAt(uint256 index) external view returns (uint256) {
        return _repoIds[index];
    }

    function repoCount() external view returns (uint256) {
        return _repoIds.length;
    }

    function _proof(uint256 seed) private view returns (Proof storage) {
        return _proofs[seed % _proofs.length];
    }

    function _actor(uint256 seed) private view returns (address) {
        return _actors[seed % _actors.length];
    }

    /// @dev The success path. Registering an already-registered repository is included because it
    ///      must continue to fail.
    function register(uint256 seed) external {
        registerAttempts++;
        registerCalls++;
        Proof storage p = _proof(seed);

        bool already = _rik.isRegistered(p.repoId);

        try _rik.register(p.kid, p.header, p.payload, p.signature, p.repoId, p.ownerId, p.actorId, p.wallet) {
            if (already) {
                // A second registration must be impossible, or a repository owner could reclaim a
                // key that has been sold.
                forbiddenRegistrationSucceeded = true;
                return;
            }
            everRegistered[p.repoId] = true;
            expectedOwnerId[p.repoId] = p.ownerId;
            expectedRegisteredAt[p.repoId] = block.timestamp;
            registeredCount++;
        } catch {
            rejectedAttempts++;
        }
    }

    /// @dev The same proof with a repository id it does not attest.
    function registerWrongRepo(uint256 seed, uint256 repoId) external {
        registerAttempts++;
        Proof storage p = _proof(seed);
        repoId = bound(repoId, 1, type(uint64).max);
        if (repoId == p.repoId) return;

        try _rik.register(p.kid, p.header, p.payload, p.signature, repoId, p.ownerId, p.actorId, p.wallet) {
            forbiddenRegistrationSucceeded = true;
        } catch {
            rejectedAttempts++;
        }
    }

    /// @dev The same proof redirected at a wallet it does not name.
    function registerWrongWallet(uint256 seed, uint256 walletSeed) external {
        registerAttempts++;
        Proof storage p = _proof(seed);
        address wallet = _actor(walletSeed);
        if (wallet == p.wallet) return;

        try _rik.register(p.kid, p.header, p.payload, p.signature, p.repoId, p.ownerId, p.actorId, wallet) {
            forbiddenRegistrationSucceeded = true;
        } catch {
            rejectedAttempts++;
        }
    }

    /// @dev The same proof with an owner id it does not attest.
    function registerWrongOwner(uint256 seed, uint256 ownerId) external {
        registerAttempts++;
        Proof storage p = _proof(seed);
        ownerId = bound(ownerId, 1, type(uint64).max);
        if (ownerId == p.ownerId) return;

        try _rik.register(p.kid, p.header, p.payload, p.signature, p.repoId, ownerId, p.actorId, p.wallet) {
            forbiddenRegistrationSucceeded = true;
        } catch {
            rejectedAttempts++;
        }
    }

    /// @dev Keys change hands constantly, so the invariants never see a settled registry.
    function transferKey(uint256 seed, uint256 toSeed) external {
        transferAttempts++;
        Proof storage p = _proof(seed);
        if (!_rik.isRegistered(p.repoId)) return;

        address holder = _rik.ownerOf(p.repoId);
        vm.prank(holder);
        try _rik.transferFrom(holder, _actor(toSeed), p.repoId) {} catch {}
    }

    /// @dev Approvals are a normal ERC-721 affordance here, unlike in a soulbound key.
    function approveAndTransfer(uint256 seed, uint256 operatorSeed, uint256 toSeed) external {
        transferAttempts++;
        Proof storage p = _proof(seed);
        if (!_rik.isRegistered(p.repoId)) return;

        address holder = _rik.ownerOf(p.repoId);
        address operator = _actor(operatorSeed);

        vm.prank(holder);
        try _rik.approve(operator, p.repoId) {} catch {}

        vm.prank(operator);
        try _rik.transferFrom(holder, _actor(toSeed), p.repoId) {} catch {}
    }
}

contract RIKRegistry_Invariant is OidcFixture {
    uint64 constant ATTESTATION_REPO_ID = 900100200;
    string constant WORKFLOW_REF = "freecodexyz/market/.github/workflows/register-rik.yml@refs/heads/main";

    uint256 constant OWNER_ID = 583231;
    uint256 constant ACTOR_ID = 583231;

    GithubOidcVerifier verifier;
    RIK rik;
    RegistryHandler handler;

    address alice = address(0x1111111111111111111111111111111111111111);
    address bob = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        verifier = new GithubOidcVerifier(address(this));
        rik = new RIK(address(this), verifier);
        rik.setAttestationRepoId(ATTESTATION_REPO_ID);
        rik.setJobWorkflowRef(WORKFLOW_REF);

        uint256[3] memory repoIds = [uint256(1296269), 222333, 987654];
        address[3] memory wallets = [alice, bob, alice];

        Proof[] memory proofs = new Proof[](3);
        for (uint256 i = 0; i < 3; ++i) {
            Fixture memory f = _fixture("sample-jwt.json", repoIds[i], OWNER_ID, ACTOR_ID, wallets[i]);
            verifier.addKey(f.kid, f.modulus, f.exponent);
            proofs[i] = Proof({
                kid: f.kid,
                header: f.headerB64,
                payload: f.payloadB64,
                signature: f.signature,
                repoId: repoIds[i],
                ownerId: OWNER_ID,
                actorId: ACTOR_ID,
                wallet: wallets[i]
            });
        }

        handler = new RegistryHandler(rik, proofs);
        targetContract(address(handler));
    }

    /// @dev A repository that has ever been registered is registered forever, and its key always
    ///      has a real holder.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    /// forge-config: deep.invariant.runs = 128
    /// forge-config: deep.invariant.depth = 128
    function invariant_RegisteredRepositoriesAlwaysHaveAHolder() public view {
        for (uint256 i = 0; i < handler.repoCount(); ++i) {
            uint256 repoId = handler.repoIdAt(i);
            if (!handler.everRegistered(repoId)) continue;

            assertTrue(rik.isRegistered(repoId));
            assertTrue(rik.ownerOf(repoId) != address(0));
        }
    }

    /// @dev The registration record is written once and never touched again, whatever happens to
    ///      the key afterwards. Everything downstream attributes royalties through it.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    /// forge-config: deep.invariant.runs = 128
    /// forge-config: deep.invariant.depth = 128
    function invariant_RegistrationRecordIsImmutable() public view {
        for (uint256 i = 0; i < handler.repoCount(); ++i) {
            uint256 repoId = handler.repoIdAt(i);
            if (!handler.everRegistered(repoId)) continue;

            RIK.Repo memory repo = rik.repoOf(repoId);
            assertEq(uint256(repo.githubRepoId), repoId);
            assertEq(uint256(repo.githubOwnerId), handler.expectedOwnerId(repoId));
            assertEq(uint256(repo.registeredAt), handler.expectedRegisteredAt(repoId));
        }
    }

    /// @dev No proof, however it is aimed, ever mints a key it does not attest.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    /// forge-config: deep.invariant.runs = 128
    /// forge-config: deep.invariant.depth = 128
    function invariant_NoForbiddenRegistrationEverSucceeds() public view {
        assertFalse(handler.forbiddenRegistrationSucceeded());
    }

    /// @dev Exactly one key exists per registered repository, and the holders account for all of
    ///      them. A double mint or a lost balance would show up here.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    /// forge-config: deep.invariant.runs = 128
    /// forge-config: deep.invariant.depth = 128
    function invariant_SupplyMatchesRegistrations() public view {
        uint256 registered;
        for (uint256 i = 0; i < handler.repoCount(); ++i) {
            if (rik.isRegistered(handler.repoIdAt(i))) registered++;
        }
        assertEq(registered, handler.registeredCount());

        address[6] memory holders = [address(0xA1), address(0xA2), address(0xA3), address(0xA4), alice, bob];
        uint256 held;
        for (uint256 i = 0; i < holders.length; ++i) {
            held += rik.balanceOf(holders[i]);
        }
        assertEq(held, registered);
    }

    /// @dev Fails if the handler never reached a path, which would make the invariants trivial.
    function afterInvariant() public view {
        assertGt(handler.registerAttempts(), 0);
        assertGt(handler.rejectedAttempts(), 0);
        assertGt(handler.transferAttempts(), 0);

        // `afterInvariant` runs after every sequence, and a sequence need not have called the
        // success path at all. Conditioning on that keeps the assertion about behaviour rather
        // than about what the fuzzer happened to select.
        if (handler.registerCalls() > 0) assertGt(handler.registeredCount(), 0);
    }
}
