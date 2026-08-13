// test/RIKRoyaltySplitterSolvency.invariant.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {RIK} from "../src/RIK.sol";
import {RIKRoyaltySplitter} from "../src/RIKRoyaltySplitter.sol";
import {MarketFixture} from "./MarketFixture.sol";
import {MockAirlock} from "./mocks/MockAirlock.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMulticurvePool} from "./mocks/MockMulticurvePool.sol";

/**
 * @dev Drives two competing repositories through every value-moving path on the splitter.
 *
 * Every call is attempted rather than arranged to succeed, and failures are swallowed, so it is the
 * invariant and not the handler that carries the proof.
 */
contract SplitterSolvencyHandler is Test {
    RIKRoyaltySplitter private immutable _splitter;
    RIK private immutable _rik;
    MockAirlock private immutable _airlock;
    MockMulticurvePool private immutable _poolA;
    MockMulticurvePool private immutable _poolB;
    MockERC20 private immutable _assetA;
    MockERC20 private immutable _assetB;
    MockERC20 private immutable _numeraire;
    address private immutable _owner;

    uint256[2] private _repos;
    address[3] private _actors;

    uint256 public collects;
    uint256 public claims;
    uint256 public transfers;
    uint256 public sweeps;

    constructor(
        RIKRoyaltySplitter splitter_,
        RIK rik_,
        MockAirlock airlock_,
        MockMulticurvePool poolA_,
        MockMulticurvePool poolB_,
        MockERC20[3] memory tokens_,
        uint256[2] memory repos_,
        address owner_
    ) {
        _splitter = splitter_;
        _rik = rik_;
        _airlock = airlock_;
        _poolA = poolA_;
        _poolB = poolB_;
        _assetA = tokens_[0];
        _assetB = tokens_[1];
        _numeraire = tokens_[2];
        _repos = repos_;
        _owner = owner_;
        _actors = [address(0xA1), address(0xA2), address(0xA3)];
    }

    function _repo(uint256 seed) private view returns (uint256) {
        return _repos[seed % _repos.length];
    }

    function _actor(uint256 seed) private view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _token(uint256 seed) private view returns (MockERC20) {
        uint256 index = seed % 3;
        if (index == 0) return _assetA;
        if (index == 1) return _assetB;
        return _numeraire;
    }

    /// @dev Mints trading fees into a pool and pushes them into the owning repository's bucket.
    function collectFromPoolA(uint96 fees0, uint96 fees1) external {
        collects++;
        _assetA.mint(address(_poolA), fees0);
        _numeraire.mint(address(_poolA), fees1);
        _poolA.setFees(fees0, fees1);
        try _splitter.collectPoolFees(_poolA) {} catch {}
    }

    function collectFromPoolB(uint96 fees0, uint96 fees1) external {
        collects++;
        _assetB.mint(address(_poolB), fees0);
        _numeraire.mint(address(_poolB), fees1);
        _poolB.setFees(fees0, fees1);
        try _splitter.collectPoolFees(_poolB) {} catch {}
    }

    /// @dev Claims as whoever currently holds the key, which is the only caller that can succeed.
    function claimAsHolder(uint256 repoSeed, uint256 tokenSeed, uint256 recipientSeed) external {
        claims++;
        uint256 repoId = _repo(repoSeed);
        address holder = _rik.ownerOf(repoId);

        vm.prank(holder);
        try _splitter.claim(repoId, address(_token(tokenSeed)), _actor(recipientSeed)) {} catch {}
    }

    /// @dev Claims as somebody else. Must never move anything.
    function claimAsStranger(uint256 repoSeed, uint256 tokenSeed, uint256 callerSeed) external {
        claims++;
        uint256 repoId = _repo(repoSeed);

        vm.prank(_actor(callerSeed));
        try _splitter.claim(repoId, address(_token(tokenSeed)), _actor(callerSeed)) {} catch {}
    }

    /// @dev Moves a key mid-campaign, so buckets change hands while they are non-empty.
    function transferKey(uint256 repoSeed, uint256 toSeed) external {
        transfers++;
        uint256 repoId = _repo(repoSeed);
        address holder = _rik.ownerOf(repoId);

        vm.prank(holder);
        try _rik.transferFrom(holder, _actor(toSeed), repoId) {} catch {}
    }

    /// @dev The owner sweeping integrator fees must never eat into a repository's bucket.
    function sweepIntegratorFees(uint96 amount, uint256 tokenSeed, uint256 recipientSeed) external {
        sweeps++;
        MockERC20 token = _token(tokenSeed);
        token.mint(address(_airlock), amount);
        _airlock.setFees(address(_splitter), address(token), amount);

        vm.prank(_owner);
        try _splitter.collectIntegratorFees(address(token), _actor(recipientSeed)) {} catch {}
    }
}

contract RIKRoyaltySplitterSolvency_Invariant is MarketFixture {
    uint256 constant REPO_A = 1296269;
    uint256 constant REPO_B = 222333;

    MockERC20 assetB;
    MockMulticurvePool poolA;
    MockMulticurvePool poolB;
    SplitterSolvencyHandler handler;

    function setUp() public {
        _deployMarket();

        // Repository A takes the fixture defaults; B is a second, competing market.
        _launchedMarket();

        assetB = new MockERC20("Other Repository Token", "OTHER");
        _registerRepo(REPO_B, OWNER_ID, bob);
        airlock.setAsset(address(assetB));
        vm.prank(bob);
        launcher.launch(REPO_B, _params());

        poolA = new MockMulticurvePool(address(asset), address(numeraire));
        poolB = new MockMulticurvePool(address(assetB), address(numeraire));

        handler = new SplitterSolvencyHandler(
            splitter, rik, airlock, poolA, poolB, [asset, assetB, numeraire], [REPO_A, REPO_B], protocolOwner
        );

        targetContract(address(handler));
    }

    function _assertBacked(MockERC20 token) internal view {
        uint256 owed = splitter.claimable(REPO_A, address(token)) + splitter.claimable(REPO_B, address(token));
        assertLe(owed, token.balanceOf(address(splitter)));
    }

    /**
     * @dev The property everything else rests on: whatever the splitter says it owes, it holds. If
     *      this can be broken then one repository can be paid out of another's earnings, or a claim
     *      can be recorded that the contract cannot honour.
     */
    function invariant_EveryBucketIsBacked() public view {
        _assertBacked(asset);
        _assertBacked(assetB);
        _assertBacked(numeraire);
    }

    /// @dev A market is bound to one repository for good, so payouts cannot be redirected.
    function invariant_MarketAttributionNeverChanges() public view {
        assertEq(splitter.repoIdOf(address(asset)), REPO_A);
        assertEq(splitter.repoIdOf(address(assetB)), REPO_B);
        assertEq(launcher.marketOf(REPO_A), address(asset));
        assertEq(launcher.marketOf(REPO_B), address(assetB));
    }

    /// @dev Fails if the handler never reached a path, which would make the invariants trivial.
    function afterInvariant() public view {
        assertGt(handler.collects(), 0);
        assertGt(handler.claims(), 0);
        assertGt(handler.transfers(), 0);
        assertGt(handler.sweeps(), 0);
    }
}
