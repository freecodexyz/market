// test/MarketSystem.invariant.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {RIK} from "../src/RIK.sol";
import {RIKLauncher} from "../src/RIKLauncher.sol";
import {RIKRoyaltySplitter} from "../src/RIKRoyaltySplitter.sol";
import {IAirlock} from "../src/IAirlock.sol";
import {PoolKey} from "../src/IDopplerHookInitializer.sol";
import {MarketFixture} from "./MarketFixture.sol";
import {MockAirlock} from "./mocks/MockAirlock.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDopplerHookInitializer} from "./mocks/MockDopplerHookInitializer.sol";

/// @dev The deployed system, grouped so the handler's constructor stays inside the stack limit.
struct SystemWiring {
    RIK rik;
    RIKLauncher launcher;
    RIKRoyaltySplitter splitter;
    MockAirlock airlock;
    MockERC20 numeraire;
    address owner;
}

/**
 * @dev Drives the whole system: launching markets, collecting fees, moving keys, paying out, and
 *      the owner sweeping what belongs to nobody.
 *
 * The handler keeps a running total of every token that has ever been credited to a repository and
 * every token that has ever left through a claim. That is what turns the accounting into something
 * checkable: the splitter is a pure conduit, so what it still owes plus what it has already paid
 * must equal what it ever took in, exactly, forever.
 */
contract SystemHandler is Test {
    RIK private immutable _rik;
    RIKLauncher private immutable _launcher;
    RIKRoyaltySplitter private immutable _splitter;
    MockAirlock private immutable _airlock;
    MockERC20 private immutable _numeraire;
    address private immutable _owner;

    uint256[] private _repos;
    MockERC20[] private _assets;
    MockDopplerHookInitializer private _initializer;
    MockERC20 private _foreignAsset;
    address[] private _actors;

    /// @dev Every token ever credited into a repository bucket.
    mapping(address token => uint256 amount) public accrued;
    /// @dev Every token ever paid out of a repository bucket.
    mapping(address token => uint256 amount) public paidOut;
    /// @dev The market address first seen for a repository, which must never change afterwards.
    mapping(uint256 repoId => address asset) public firstMarket;

    uint256 public launches;
    uint256 public collections;
    uint256 public unknownPoolCollections;
    uint256 public payouts;
    uint256 public transfers;
    uint256 public sweeps;

    /// @dev Set if anyone but the current key holder ever succeeded in claiming.
    bool public strangerWasPaid;
    /// @dev Set if a pool whose asset was never registered was accepted for collection.
    bool public unknownPoolAccepted;
    /// @dev Set if a repository's market address ever changed after being assigned.
    bool public marketWasReassigned;

    constructor(
        SystemWiring memory wiring,
        uint256[] memory repos_,
        MockERC20[] memory assets_,
        MockDopplerHookInitializer initializer_,
        MockERC20 foreignAsset_,
        address[] memory actors_
    ) {
        _rik = wiring.rik;
        _launcher = wiring.launcher;
        _splitter = wiring.splitter;
        _airlock = wiring.airlock;
        _numeraire = wiring.numeraire;
        _owner = wiring.owner;
        _repos = repos_;
        _assets = assets_;
        _initializer = initializer_;
        _foreignAsset = foreignAsset_;
        _actors = actors_;
    }

    function repoCount() external view returns (uint256) {
        return _repos.length;
    }

    function repoAt(uint256 index) external view returns (uint256) {
        return _repos[index];
    }

    function _repo(uint256 seed) private view returns (uint256 repoId, uint256 index) {
        index = seed % _repos.length;
        repoId = _repos[index];
    }

    function _actor(uint256 seed) private view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _token(uint256 seed) private view returns (address) {
        uint256 index = seed % (_assets.length + 1);
        return index == _assets.length ? address(_numeraire) : address(_assets[index]);
    }

    /// @dev Each repository gets its own asset, so attribution has something to get wrong.
    function launchMarket(uint256 repoSeed) external {
        launches++;
        (uint256 repoId, uint256 index) = _repo(repoSeed);

        _airlock.setAsset(address(_assets[index]));
        address holder = _rik.ownerOf(repoId);

        vm.prank(holder);
        try _launcher.launch(repoId, _params()) {
            firstMarket[repoId] = address(_assets[index]);
        } catch {}
    }

    /// @dev A stranger must never be able to launch a repository's one and only market.
    function launchAsStranger(uint256 repoSeed, uint256 callerSeed) external {
        launches++;
        (uint256 repoId, uint256 index) = _repo(repoSeed);

        address caller = _actor(callerSeed);
        if (caller == _rik.ownerOf(repoId)) return;

        _airlock.setAsset(address(_assets[index]));
        vm.prank(caller);
        try _launcher.launch(repoId, _params()) {
            marketWasReassigned = true;
        } catch {}
    }

    /**
     * @dev Mints trading fees into a pool with a registered asset and collects them.
     *
     * The pool and the amounts are constrained so that a collection always credits something.
     * `afterInvariant` runs after every sequence, not once per campaign, so a sequence in which
     * every collection happened to draw an unregistered pool or a zero amount would fail its
     * coverage assertion without indicating a defect. The unregistered path has its own action.
     */
    function collectFees(uint256 assetSeed, uint96 fees0, uint96 fees1) external {
        collections++;

        // Only the first asset is launched by `setUp`; the others require a launch first.
        uint256 index = assetSeed % _assets.length;
        address asset = address(_assets[index]);
        if (_splitter.repoIdOf(asset) == 0) asset = address(_assets[0]);

        uint256 amount0 = bound(uint256(fees0), 1, type(uint96).max);
        uint256 amount1 = bound(uint256(fees1), 1, type(uint96).max);

        (address token0, address token1) = _currenciesOf(asset);
        // Doppler holds a pool's fees in the initializer until a beneficiary collects them.
        MockERC20(token0).mint(address(_initializer), amount0);
        MockERC20(token1).mint(address(_initializer), amount1);
        _initializer.accrue(asset, amount0, amount1);

        try _splitter.collectPoolFees(asset) returns (uint256 collected0, uint256 collected1) {
            accrued[token0] += collected0;
            accrued[token1] += collected1;
        } catch {}
    }

    /// @dev An asset the launcher never registered. Collection must always be refused.
    function collectFromUnknownPool(uint96, uint96) external {
        unknownPoolCollections++;

        try _splitter.collectPoolFees(address(_foreignAsset)) {
            unknownPoolAccepted = true;
        } catch {}
    }

    function _currenciesOf(address asset) private view returns (address, address) {
        (,,,,, PoolKey memory poolKey,) = _initializer.getState(asset);
        return (poolKey.currency0, poolKey.currency1);
    }

    /// @dev Claims as whoever currently holds the key, which is the only caller that can succeed.
    function claimAsHolder(uint256 repoSeed, uint256 tokenSeed, uint256 toSeed) external {
        payouts++;
        (uint256 repoId,) = _repo(repoSeed);
        address token = _token(tokenSeed);
        address holder = _rik.ownerOf(repoId);

        vm.prank(holder);
        try _splitter.claim(repoId, token, _actor(toSeed)) returns (uint256 amount) {
            paidOut[token] += amount;
        } catch {}
    }

    /// @dev Claims as somebody else. Must never move anything.
    function claimAsStranger(uint256 repoSeed, uint256 tokenSeed, uint256 callerSeed) external {
        payouts++;
        (uint256 repoId,) = _repo(repoSeed);
        address token = _token(tokenSeed);

        address caller = _actor(callerSeed);
        if (caller == _rik.ownerOf(repoId)) return;

        vm.prank(caller);
        try _splitter.claim(repoId, token, caller) returns (uint256 amount) {
            if (amount != 0) strangerWasPaid = true;
        } catch {}
    }

    /// @dev Keys change hands while their buckets are non-empty, which the design must support.
    function transferKey(uint256 repoSeed, uint256 toSeed) external {
        transfers++;
        (uint256 repoId,) = _repo(repoSeed);
        address holder = _rik.ownerOf(repoId);

        vm.prank(holder);
        try _rik.transferFrom(holder, _actor(toSeed), repoId) {} catch {}
    }

    /// @dev The owner sweeping the Airlock's integrator fees must never reach a repository bucket.
    function sweepIntegratorFees(uint96 amount, uint256 tokenSeed, uint256 toSeed) external {
        sweeps++;
        address token = _token(tokenSeed);

        MockERC20(token).mint(address(_airlock), amount);
        _airlock.setFees(address(_splitter), token, amount);

        vm.prank(_owner);
        try _splitter.collectIntegratorFees(token, _actor(toSeed)) {} catch {}
    }

    /// @dev A stranger must not be able to sweep either.
    function sweepAsStranger(uint96 amount, uint256 tokenSeed, uint256 callerSeed) external {
        sweeps++;
        address token = _token(tokenSeed);

        MockERC20(token).mint(address(_airlock), amount);
        _airlock.setFees(address(_splitter), token, amount);

        address caller = _actor(callerSeed);
        if (caller == _owner) return;

        vm.prank(caller);
        try _splitter.collectIntegratorFees(token, caller) {} catch {}
    }

    function _params() private view returns (IAirlock.CreateParams memory p) {
        p.initialSupply = 1_000_000 ether;
        p.numTokensToSell = 500_000 ether;
        p.numeraire = address(_numeraire);
        // Without an initializer the launcher cannot verify the splitter is a beneficiary, so every
        // launch would be refused and the campaign would never reach a second market.
        p.poolInitializer = address(_initializer);
        p.integrator = address(0xDEFEA7);
        p.salt = bytes32(uint256(1));
    }
}

contract MarketSystem_Invariant is MarketFixture {
    uint256 constant REPO_A = 1296269;
    uint256 constant REPO_B = 222333;
    uint256 constant REPO_C = 987654;

    SystemHandler handler;

    MockERC20[] assets;
    address[] tokens;
    address[] actors;

    function setUp() public {
        _deployMarket();

        uint256[] memory repos = new uint256[](3);
        repos[0] = REPO_A;
        repos[1] = REPO_B;
        repos[2] = REPO_C;

        // The registry is exercised on its own in RIKRegistry.invariant.t.sol; here the keys just
        // need to exist so the market half has something to authorize against.
        _registerRepo(REPO_A, OWNER_ID, alice);
        _registerRepo(REPO_B, OWNER_ID, bob);
        _registerRepo(REPO_C, OWNER_ID, alice);

        assets.push(asset);
        assets.push(new MockERC20("Repository Token B", "REPOB"));
        assets.push(new MockERC20("Repository Token C", "REPOC"));

        for (uint256 i = 0; i < 3; ++i) {
            tokens.push(address(assets[i]));
        }
        tokens.push(address(numeraire));
        // An asset the launcher never registered, so the unknown-market path stays exercised.
        MockERC20 foreign = new MockERC20("Foreign", "FGN");

        actors.push(alice);
        actors.push(bob);
        actors.push(address(0xA1));
        actors.push(address(0xA2));
        // The splitter itself, as a recipient. Paying a bucket back into the contract must not
        // break either the accounting or the solvency floor.
        actors.push(address(splitter));

        SystemWiring memory wiring = SystemWiring({
            rik: rik,
            launcher: launcher,
            splitter: splitter,
            airlock: airlock,
            numeraire: numeraire,
            owner: protocolOwner
        });

        handler = new SystemHandler(wiring, repos, assets, initializer, foreign, actors);

        targetContract(address(handler));
    }

    /**
     * @dev The splitter is a conduit, not a vault: everything it has ever been credited is either
     *      still owed to a repository or has already been paid out. Breaking this in either
     *      direction is the difference between an accounting bug and stolen royalties.
     */
    function invariant_ValueIsConserved() public view {
        for (uint256 t = 0; t < tokens.length; ++t) {
            address token = tokens[t];

            uint256 owed;
            for (uint256 i = 0; i < handler.repoCount(); ++i) {
                owed += splitter.claimable(handler.repoAt(i), token);
            }

            assertEq(owed + handler.paidOut(token), handler.accrued(token), "conduit accounting broke");
        }
    }

    /// @dev The splitter holds whatever it reports as owed. This keeps every {claim} payable and
    ///      prevents one repository being paid from another's earnings.
    function invariant_EveryBucketIsBacked() public view {
        for (uint256 t = 0; t < tokens.length; ++t) {
            address token = tokens[t];

            uint256 owed;
            for (uint256 i = 0; i < handler.repoCount(); ++i) {
                owed += splitter.claimable(handler.repoAt(i), token);
            }

            assertLe(owed, MockERC20(token).balanceOf(address(splitter)), "buckets exceed the balance");
        }
    }

    /// @dev A repository gets one market, forever, and it stays attributed to that repository. The
    ///      splitter's reverse mapping is only meaningful while this holds.
    function invariant_MarketAttributionIsStableAndExclusive() public view {
        assertFalse(handler.marketWasReassigned(), "a stranger launched a market");

        for (uint256 i = 0; i < handler.repoCount(); ++i) {
            uint256 repoId = handler.repoAt(i);
            address expected = handler.firstMarket(repoId);
            if (expected == address(0)) continue;

            assertEq(launcher.marketOf(repoId), expected, "a repository's market moved");
            assertEq(splitter.repoIdOf(expected), repoId, "a market was re-attributed");
        }
    }

    /// @dev Only the account currently holding a key can ever be paid for it.
    function invariant_OnlyTheHolderIsEverPaid() public view {
        assertFalse(handler.strangerWasPaid());
    }

    /// @dev A pool whose asset was never registered cannot be attributed to any repository.
    function invariant_UnknownPoolsAreNeverAccepted() public view {
        assertFalse(handler.unknownPoolAccepted());
    }

    /// @dev Fails if the handler never reached a path, which would make the invariants trivial.
    function afterInvariant() public view {
        assertGt(handler.launches(), 0);
        assertGt(handler.collections(), 0);
        assertGt(handler.payouts(), 0);
        assertGt(handler.transfers(), 0);
        assertGt(handler.sweeps(), 0);

        // At least one repository must have earned something, or the accounting invariants are
        // comparing zero to zero. `collectFees` credits a non-zero amount on every call, so this
        // follows from it having been called at all rather than from what the fuzzer chose.
        uint256 everAccrued;
        for (uint256 t = 0; t < tokens.length; ++t) {
            everAccrued += handler.accrued(tokens[t]);
        }
        assertGt(everAccrued, 0, "no fees were ever accrued");
    }
}
