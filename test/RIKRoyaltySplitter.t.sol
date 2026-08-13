// test/RIKRoyaltySplitter.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {stdError} from "forge-std/StdError.sol";

import {RIKRoyaltySplitter} from "../src/RIKRoyaltySplitter.sol";
import {MarketFixture} from "./MarketFixture.sol";
import {FeeOnTransferERC20, MockERC20} from "./mocks/MockERC20.sol";
import {
    DrainingMulticurvePool,
    MockMulticurvePool,
    ReenteringMulticurvePool,
    SilentMulticurvePool
} from "./mocks/MockMulticurvePool.sol";

contract RIKRoyaltySplitter_T is MarketFixture {
    MockMulticurvePool pool;

    function setUp() public {
        _deployMarket();
        _launchedMarket();

        pool = new MockMulticurvePool(address(asset), address(numeraire));
    }

    /// @dev Funds `pool` and has it pay `amount0`/`amount1` to whoever collects.
    function _fundPool(uint256 amount0, uint256 amount1) internal {
        asset.mint(address(pool), amount0);
        numeraire.mint(address(pool), amount1);
        pool.setFees(amount0, amount1);
    }

    // --- wiring -------------------------------------------------------------

    function test_WiringIsImmutableAndCorrect() public view {
        assertEq(address(splitter.registry()), address(rik));
        assertEq(address(splitter.airlock()), address(airlock));
        assertEq(splitter.launcher(), address(launcher));
        assertEq(splitter.owner(), protocolOwner);
    }

    function test_OwnershipTransferIsTwoStep() public {
        vm.prank(protocolOwner);
        splitter.transferOwnership(bob);

        assertEq(splitter.owner(), protocolOwner);
        assertEq(splitter.pendingOwner(), bob);

        vm.prank(bob);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), bob);
    }

    // --- market registration ------------------------------------------------

    function test_RegisterMarketOnlyLauncher() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.CallerIsNotLauncher.selector, stranger));
        splitter.registerMarket(address(numeraire), 222);
    }

    /// @dev Not even the owner may bind an asset to a repository.
    function test_RegisterMarketRejectsOwner() public {
        vm.prank(protocolOwner);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.CallerIsNotLauncher.selector, protocolOwner));
        splitter.registerMarket(address(numeraire), 222);
    }

    /// @dev Zero is the "not a market" sentinel, so it can never be a repository id.
    function test_RegisterMarketRejectsZeroRepoId() public {
        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.InvalidGithubRepoId.selector, 0));
        splitter.registerMarket(address(numeraire), 0);
    }

    function test_RegisterMarketRejectsRebinding() public {
        vm.prank(address(launcher));
        vm.expectRevert(
            abi.encodeWithSelector(RIKRoyaltySplitter.MarketAlreadyRegistered.selector, address(asset), REPO_ID)
        );
        splitter.registerMarket(address(asset), 222);
    }

    function test_RepoIdOfIsZeroForUnknownAsset() public view {
        assertEq(splitter.repoIdOf(address(numeraire)), 0);
    }

    // --- accrual ------------------------------------------------------------

    function test_CollectPoolFeesCreditsBothSides() public {
        _fundPool(3 ether, 7 ether);

        (uint256 amount0, uint256 amount1) = splitter.collectPoolFees(pool);

        assertEq(amount0, 3 ether);
        assertEq(amount1, 7 ether);
        assertEq(splitter.claimable(REPO_ID, address(asset)), 3 ether);
        assertEq(splitter.claimable(REPO_ID, address(numeraire)), 7 ether);
        assertEq(asset.balanceOf(address(splitter)), 3 ether);
        assertEq(numeraire.balanceOf(address(splitter)), 7 ether);
    }

    function test_CollectPoolFeesEmitsPerToken() public {
        _fundPool(3 ether, 7 ether);

        vm.expectEmit(true, true, false, true);
        emit RIKRoyaltySplitter.FeesAccrued(REPO_ID, address(asset), 3 ether);
        vm.expectEmit(true, true, false, true);
        emit RIKRoyaltySplitter.FeesAccrued(REPO_ID, address(numeraire), 7 ether);

        splitter.collectPoolFees(pool);
    }

    /// @dev Permissionless: calling it for another repository confers no benefit on the caller.
    function test_CollectPoolFeesIsPermissionless() public {
        _fundPool(3 ether, 0);

        vm.prank(stranger);
        splitter.collectPoolFees(pool);

        assertEq(splitter.claimable(REPO_ID, address(asset)), 3 ether);
    }

    function test_CollectPoolFeesAccumulatesAcrossCalls() public {
        _fundPool(3 ether, 0);
        splitter.collectPoolFees(pool);

        _fundPool(5 ether, 0);
        splitter.collectPoolFees(pool);

        assertEq(splitter.claimable(REPO_ID, address(asset)), 8 ether);
    }

    /// @dev Either ordering of the pair resolves to the same repository.
    function test_CollectPoolFeesAcceptsRegisteredAssetOnEitherSide() public {
        MockMulticurvePool flipped = new MockMulticurvePool(address(numeraire), address(asset));
        numeraire.mint(address(flipped), 4 ether);
        flipped.setFees(4 ether, 0);

        splitter.collectPoolFees(flipped);

        assertEq(splitter.claimable(REPO_ID, address(numeraire)), 4 ether);
    }

    function test_CollectPoolFeesRejectsUnknownPool() public {
        MockERC20 other = new MockERC20("Other", "OTHER");
        MockMulticurvePool unknown = new MockMulticurvePool(address(other), address(numeraire));

        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.UnknownPool.selector, address(unknown)));
        splitter.collectPoolFees(unknown);
    }

    /// @dev Two registered assets in one pool cannot be attributed, so it is refused rather than
    ///      resolved by picking a side.
    function test_CollectPoolFeesRejectsAmbiguousPool() public {
        MockERC20 otherAsset = new MockERC20("Other", "OTHER");
        _registerRepo(222, OWNER_ID, bob);
        airlock.setAsset(address(otherAsset));
        vm.prank(bob);
        launcher.launch(222, _params());

        MockMulticurvePool ambiguous = new MockMulticurvePool(address(asset), address(otherAsset));

        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.AmbiguousPool.selector, address(ambiguous)));
        splitter.collectPoolFees(ambiguous);
    }

    /// @dev Without the ambiguity check, a pool reporting one token twice would have a single
    ///      balance delta credited to two buckets.
    function test_CollectPoolFeesRejectsIdenticalTokens() public {
        pool.setTokens(address(asset), address(asset));

        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.AmbiguousPool.selector, address(pool)));
        splitter.collectPoolFees(pool);
    }

    /// @dev Nothing arrived, so nothing is credited and no event is emitted.
    function test_CollectPoolFeesCreditsNothingWhenPoolPaysNothing() public {
        SilentMulticurvePool silent = new SilentMulticurvePool(address(asset), address(numeraire));

        vm.recordLogs();
        (uint256 amount0, uint256 amount1) = splitter.collectPoolFees(silent);

        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(splitter.claimable(REPO_ID, address(asset)), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// @dev Credits what arrived, not what was sent.
    function test_CollectPoolFeesCreditsOnlyWhatArrived() public {
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20("Taxed", "TAX", 1000); // 10%
        MockMulticurvePool taxedPool = new MockMulticurvePool(address(asset), address(taxed));

        asset.mint(address(taxedPool), 1 ether);
        taxed.mint(address(taxedPool), 10 ether);
        taxedPool.setFees(1 ether, 10 ether);

        (, uint256 amount1) = splitter.collectPoolFees(taxedPool);

        assertEq(amount1, 9 ether);
        assertEq(splitter.claimable(REPO_ID, address(taxed)), 9 ether);
        assertEq(taxed.balanceOf(address(splitter)), 9 ether);
    }

    /// @dev A pool that takes tokens instead of paying them must revert, not wrap around into an
    ///      enormous credit that would drain every other repository's bucket.
    function test_CollectPoolFeesRevertsWhenBalanceShrinks() public {
        _fundPool(5 ether, 0);
        splitter.collectPoolFees(pool);

        DrainingMulticurvePool draining = new DrainingMulticurvePool(address(asset), address(numeraire), 1 ether);

        vm.expectRevert(stdError.arithmeticError);
        splitter.collectPoolFees(draining);
    }

    function test_CollectPoolFeesRejectsReentrancy() public {
        ReenteringMulticurvePool evil = new ReenteringMulticurvePool(address(asset), address(numeraire), splitter);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        splitter.collectPoolFees(evil);
    }

    // --- claiming -----------------------------------------------------------

    function test_ClaimPaysTheKeyHolder() public {
        _fundPool(3 ether, 0);
        splitter.collectPoolFees(pool);

        vm.prank(alice);
        uint256 claimed = splitter.claim(REPO_ID, address(asset), alice);

        assertEq(claimed, 3 ether);
        assertEq(asset.balanceOf(alice), 3 ether);
        assertEq(splitter.claimable(REPO_ID, address(asset)), 0);
    }

    function test_ClaimEmitsFeesClaimed() public {
        _fundPool(3 ether, 0);
        splitter.collectPoolFees(pool);

        vm.expectEmit(true, true, true, true);
        emit RIKRoyaltySplitter.FeesClaimed(REPO_ID, address(asset), bob, 3 ether);

        vm.prank(alice);
        splitter.claim(REPO_ID, address(asset), bob);
    }

    function test_ClaimMayPayAnyRecipient() public {
        _fundPool(3 ether, 0);
        splitter.collectPoolFees(pool);

        vm.prank(alice);
        splitter.claim(REPO_ID, address(asset), bob);

        assertEq(asset.balanceOf(bob), 3 ether);
        assertEq(asset.balanceOf(alice), 0);
    }

    function test_ClaimRejectsNonHolder() public {
        _fundPool(3 ether, 0);
        splitter.collectPoolFees(pool);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NotRepositoryKeyHolder.selector, REPO_ID, bob));
        splitter.claim(REPO_ID, address(asset), bob);
    }

    /// @dev Royalties follow the key, which is why RIK is transferable.
    function test_ClaimFollowsTheKeyAfterTransfer() public {
        _fundPool(3 ether, 0);
        splitter.collectPoolFees(pool);

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NotRepositoryKeyHolder.selector, REPO_ID, alice));
        splitter.claim(REPO_ID, address(asset), alice);

        vm.prank(bob);
        assertEq(splitter.claim(REPO_ID, address(asset), bob), 3 ether);
    }

    function test_ClaimRejectsEmptyBucket() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NothingToClaim.selector, REPO_ID, address(asset)));
        splitter.claim(REPO_ID, address(asset), alice);
    }

    function test_ClaimEmptiesTheBucketExactlyOnce() public {
        _fundPool(3 ether, 0);
        splitter.collectPoolFees(pool);

        vm.startPrank(alice);
        splitter.claim(REPO_ID, address(asset), alice);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NothingToClaim.selector, REPO_ID, address(asset)));
        splitter.claim(REPO_ID, address(asset), alice);
        vm.stopPrank();
    }

    // --- isolation between repositories -------------------------------------

    function test_RepositoriesCannotReachEachOthersBuckets() public {
        MockERC20 otherAsset = new MockERC20("Other", "OTHER");
        _registerRepo(222, OWNER_ID, bob);
        airlock.setAsset(address(otherAsset));
        vm.prank(bob);
        launcher.launch(222, _params());

        MockMulticurvePool otherPool = new MockMulticurvePool(address(otherAsset), address(numeraire));
        numeraire.mint(address(otherPool), 7 ether);
        otherPool.setFees(0, 7 ether);

        _fundPool(0, 3 ether);
        splitter.collectPoolFees(pool);
        splitter.collectPoolFees(otherPool);

        assertEq(splitter.claimable(REPO_ID, address(numeraire)), 3 ether);
        assertEq(splitter.claimable(222, address(numeraire)), 7 ether);

        // Bob holds 222 but not REPO_ID.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NotRepositoryKeyHolder.selector, REPO_ID, bob));
        splitter.claim(REPO_ID, address(numeraire), bob);

        vm.prank(bob);
        assertEq(splitter.claim(222, address(numeraire), bob), 7 ether);
        assertEq(splitter.claimable(REPO_ID, address(numeraire)), 3 ether);
    }

    // --- integrator fees ----------------------------------------------------

    function test_CollectIntegratorFeesOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        splitter.collectIntegratorFees(address(numeraire), stranger);
    }

    /// @dev Not even a key holder, because these fees belong to no single repository.
    function test_CollectIntegratorFeesRejectsKeyHolder() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        splitter.collectIntegratorFees(address(numeraire), alice);
    }

    function test_CollectIntegratorFeesRejectsNothingOwed() public {
        vm.prank(protocolOwner);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NoIntegratorFees.selector, address(numeraire)));
        splitter.collectIntegratorFees(address(numeraire), protocolOwner);
    }

    function test_CollectIntegratorFeesPaysRecipient() public {
        numeraire.mint(address(airlock), 11 ether);
        airlock.setFees(address(splitter), address(numeraire), 11 ether);

        vm.expectEmit(true, true, false, true);
        emit RIKRoyaltySplitter.IntegratorFeesCollected(address(numeraire), bob, 11 ether);

        vm.prank(protocolOwner);
        uint256 collected = splitter.collectIntegratorFees(address(numeraire), bob);

        assertEq(collected, 11 ether);
        assertEq(numeraire.balanceOf(bob), 11 ether);
    }

    /// @dev The critical property: the owner's sweep is paid by the Airlock, so it cannot reduce a
    ///      repository bucket or the balance backing one.
    function test_CollectIntegratorFeesCannotTouchRepositoryBuckets() public {
        _fundPool(0, 3 ether);
        splitter.collectPoolFees(pool);

        numeraire.mint(address(airlock), 11 ether);
        airlock.setFees(address(splitter), address(numeraire), 11 ether);

        vm.prank(protocolOwner);
        splitter.collectIntegratorFees(address(numeraire), protocolOwner);

        assertEq(splitter.claimable(REPO_ID, address(numeraire)), 3 ether);
        assertEq(numeraire.balanceOf(address(splitter)), 3 ether);

        vm.prank(alice);
        assertEq(splitter.claim(REPO_ID, address(numeraire), alice), 3 ether);
    }
}
