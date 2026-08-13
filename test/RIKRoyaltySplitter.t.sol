// test/RIKRoyaltySplitter.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {PoolKey} from "../src/IDopplerHookInitializer.sol";
import {RIKRoyaltySplitter} from "../src/RIKRoyaltySplitter.sol";
import {MarketFixture} from "./MarketFixture.sol";
import {
    MockDopplerHookInitializer,
    ReenteringInitializer,
    SilentInitializer
} from "./mocks/MockDopplerHookInitializer.sol";
import {FeeOnTransferERC20, MockERC20} from "./mocks/MockERC20.sol";

contract RIKRoyaltySplitter_T is MarketFixture {
    address currency0;
    address currency1;

    function setUp() public {
        _deployMarket();
        _launchedMarket();

        (currency0, currency1) = _currenciesOf(address(asset));
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

    /// @dev The pool id must match what Uniswap V4 computes. A different value would address a
    ///      pool that does not exist, and collection would return nothing.
    function test_PoolIdMatchesUniswapV4() public view {
        (,,,,, PoolKey memory poolKey,) = initializer.getState(address(asset));

        assertEq(splitter.poolIdOf(poolKey), initializer.poolIdOf(address(asset)));
        assertEq(splitter.poolIdOf(poolKey), keccak256(abi.encode(poolKey)));
    }

    // --- market registration ------------------------------------------------

    function test_RegisterMarketOnlyLauncher() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.CallerIsNotLauncher.selector, stranger));
        splitter.registerMarket(address(numeraire), address(initializer), 222);
    }

    /// @dev Not even the owner may bind an asset to a repository.
    function test_RegisterMarketRejectsOwner() public {
        vm.prank(protocolOwner);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.CallerIsNotLauncher.selector, protocolOwner));
        splitter.registerMarket(address(numeraire), address(initializer), 222);
    }

    /// @dev Zero is the "not a market" sentinel, so it can never be a repository id.
    function test_RegisterMarketRejectsZeroRepoId() public {
        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.InvalidGithubRepoId.selector, 0));
        splitter.registerMarket(address(numeraire), address(initializer), 0);
    }

    /// @dev A zero initializer would make every collection revert, stranding the repository's fees.
    function test_RegisterMarketRejectsZeroInitializer() public {
        vm.prank(address(launcher));
        vm.expectRevert(RIKRoyaltySplitter.InvalidInitializer.selector);
        splitter.registerMarket(address(numeraire), address(0), 222);
    }

    function test_RegisterMarketRejectsRebinding() public {
        vm.prank(address(launcher));
        vm.expectRevert(
            abi.encodeWithSelector(RIKRoyaltySplitter.MarketAlreadyRegistered.selector, address(asset), REPO_ID)
        );
        splitter.registerMarket(address(asset), address(initializer), 222);
    }

    function test_RepoIdOfIsZeroForUnknownAsset() public view {
        assertEq(splitter.repoIdOf(address(numeraire)), 0);
    }

    /// @dev The initializer is recorded at launch, so a caller cannot aim collection elsewhere.
    function test_InitializerIsRecordedAtLaunch() public view {
        assertEq(splitter.initializerOf(address(asset)), address(initializer));
        assertEq(splitter.initializerOf(address(numeraire)), address(0));
    }

    // --- accrual ------------------------------------------------------------

    function test_CollectPoolFeesCreditsBothSides() public {
        _earn(address(asset), 3 ether, 7 ether);

        (uint256 amount0, uint256 amount1) = splitter.collectPoolFees(address(asset));

        assertEq(amount0, 3 ether);
        assertEq(amount1, 7 ether);
        assertEq(splitter.claimable(REPO_ID, currency0), 3 ether);
        assertEq(splitter.claimable(REPO_ID, currency1), 7 ether);
        assertEq(MockERC20(currency0).balanceOf(address(splitter)), 3 ether);
        assertEq(MockERC20(currency1).balanceOf(address(splitter)), 7 ether);
    }

    function test_CollectPoolFeesEmitsPerToken() public {
        _earn(address(asset), 3 ether, 7 ether);

        vm.expectEmit(true, true, false, true);
        emit RIKRoyaltySplitter.FeesAccrued(REPO_ID, currency0, 3 ether);
        vm.expectEmit(true, true, false, true);
        emit RIKRoyaltySplitter.FeesAccrued(REPO_ID, currency1, 7 ether);

        splitter.collectPoolFees(address(asset));
    }

    /// @dev Anyone may push a repository's earnings into its bucket; there is nothing to gain.
    function test_CollectPoolFeesIsPermissionless() public {
        _earn(address(asset), 3 ether, 0);

        vm.prank(stranger);
        splitter.collectPoolFees(address(asset));

        assertEq(splitter.claimable(REPO_ID, currency0), 3 ether);
    }

    function test_CollectPoolFeesAccumulatesAcrossCalls() public {
        _earn(address(asset), 3 ether, 0);
        splitter.collectPoolFees(address(asset));

        _earn(address(asset), 5 ether, 0);
        splitter.collectPoolFees(address(asset));

        assertEq(splitter.claimable(REPO_ID, currency0), 8 ether);
    }

    /// @dev The asset may sort either side of the numeraire; both are credited to the repository.
    function test_CollectPoolFeesCreditsWhicheverSideTheAssetSortsTo() public {
        _earn(address(asset), 4 ether, 6 ether);
        splitter.collectPoolFees(address(asset));

        uint256 assetSide = splitter.claimable(REPO_ID, address(asset));
        uint256 numeraireSide = splitter.claimable(REPO_ID, address(numeraire));

        assertGt(assetSide, 0);
        assertGt(numeraireSide, 0);
        assertEq(assetSide + numeraireSide, 10 ether);
    }

    function test_CollectPoolFeesRejectsUnknownMarket() public {
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.UnknownMarket.selector, address(numeraire)));
        splitter.collectPoolFees(address(numeraire));
    }

    /**
     * @dev Doppler releases only a beneficiary's share, so a pool pays this contract nothing unless
     *      it was registered as a beneficiary when the pool was created.
     */
    function test_CollectPoolFeesPaysNothingWithoutShares() public {
        MockERC20 otherAsset = new MockERC20("Other", "OTHER");
        _registerRepo(222, OWNER_ID, bob);

        // Launch with the splitter registered, then remove its shares to model a pool it is not a
        // beneficiary of. The launcher rejects that configuration at launch time; see
        // `test_RejectsLaunchWhenSplitterIsNotABeneficiary`.
        airlock.setAsset(address(otherAsset));
        vm.prank(bob);
        launcher.launch(222, _params());
        initializer.setShares(address(otherAsset), address(splitter), 0);

        _earn(address(otherAsset), 9 ether, 0);
        (uint256 amount0, uint256 amount1) = splitter.collectPoolFees(address(otherAsset));

        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(splitter.claimable(222, address(otherAsset)), 0);
    }

    /// @dev A share below WAD is credited proportionally, not in full.
    function test_CollectPoolFeesCreditsOnlyTheConfiguredShare() public {
        initializer.setShares(address(asset), address(splitter), 0.25e18);
        _earn(address(asset), 8 ether, 0);

        (uint256 amount0,) = splitter.collectPoolFees(address(asset));

        assertEq(amount0, 2 ether);
        assertEq(splitter.claimable(REPO_ID, currency0), 2 ether);
    }

    /// @dev Nothing arrived, so nothing is credited and no event is emitted.
    function test_CollectPoolFeesCreditsNothingWhenThePoolPaysNothing() public {
        vm.recordLogs();
        (uint256 amount0, uint256 amount1) = splitter.collectPoolFees(address(asset));

        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(splitter.claimable(REPO_ID, currency0), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// @dev A second collection with no new fees pays nothing, because Doppler tracks a
    ///      per-beneficiary high-water mark rather than a balance.
    function test_CollectPoolFeesIsIdempotentWithoutNewFees() public {
        _earn(address(asset), 5 ether, 0);
        splitter.collectPoolFees(address(asset));

        (uint256 amount0,) = splitter.collectPoolFees(address(asset));

        assertEq(amount0, 0);
        assertEq(splitter.claimable(REPO_ID, currency0), 5 ether);
    }

    /// @dev Credits what arrived, not what was reported.
    function test_CollectPoolFeesCreditsOnlyWhatArrived() public {
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20("Taxed", "TAX", 1000); // 10%
        _registerRepo(222, OWNER_ID, bob);

        airlock.setAsset(address(taxed));
        vm.prank(bob);
        launcher.launch(222, _paramsFor(address(numeraire), address(initializer)));

        taxed.mint(address(initializer), 10 ether);
        (address c0,) = _currenciesOf(address(taxed));
        initializer.accrue(address(taxed), c0 == address(taxed) ? 10 ether : 0, c0 == address(taxed) ? 0 : 10 ether);

        splitter.collectPoolFees(address(taxed));

        assertEq(splitter.claimable(222, address(taxed)), 9 ether);
        assertEq(taxed.balanceOf(address(splitter)), 9 ether);
    }

    function test_CollectPoolFeesRejectsReentrancy() public {
        ReenteringInitializer evil = new ReenteringInitializer();
        MockERC20 otherAsset = new MockERC20("Other", "OTHER");
        _registerRepo(222, OWNER_ID, bob);

        airlock.setAsset(address(otherAsset));
        vm.prank(bob);
        launcher.launch(222, _paramsFor(address(numeraire), address(evil)));
        evil.arm(splitter, address(otherAsset));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        splitter.collectPoolFees(address(otherAsset));
    }

    /// @dev An initializer that reports a pool but pays nothing is a no-op rather than a failure.
    function test_CollectPoolFeesToleratesASilentInitializer() public {
        SilentInitializer silent = new SilentInitializer();
        MockERC20 otherAsset = new MockERC20("Other", "OTHER");
        _registerRepo(222, OWNER_ID, bob);

        airlock.setAsset(address(otherAsset));
        vm.prank(bob);
        launcher.launch(222, _paramsFor(address(numeraire), address(silent)));

        (uint256 amount0, uint256 amount1) = splitter.collectPoolFees(address(otherAsset));
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    // --- claiming -----------------------------------------------------------

    function test_ClaimPaysTheKeyHolder() public {
        _earn(address(asset), 3 ether, 0);
        splitter.collectPoolFees(address(asset));

        vm.prank(alice);
        uint256 claimed = splitter.claim(REPO_ID, currency0, alice);

        assertEq(claimed, 3 ether);
        assertEq(MockERC20(currency0).balanceOf(alice), 3 ether);
        assertEq(splitter.claimable(REPO_ID, currency0), 0);
    }

    function test_ClaimEmitsFeesClaimed() public {
        _earn(address(asset), 3 ether, 0);
        splitter.collectPoolFees(address(asset));

        vm.expectEmit(true, true, true, true);
        emit RIKRoyaltySplitter.FeesClaimed(REPO_ID, currency0, bob, 3 ether);

        vm.prank(alice);
        splitter.claim(REPO_ID, currency0, bob);
    }

    function test_ClaimMayPayAnyRecipient() public {
        _earn(address(asset), 3 ether, 0);
        splitter.collectPoolFees(address(asset));

        vm.prank(alice);
        splitter.claim(REPO_ID, currency0, bob);

        assertEq(MockERC20(currency0).balanceOf(bob), 3 ether);
        assertEq(MockERC20(currency0).balanceOf(alice), 0);
    }

    function test_ClaimRejectsNonHolder() public {
        _earn(address(asset), 3 ether, 0);
        splitter.collectPoolFees(address(asset));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NotRepositoryKeyHolder.selector, REPO_ID, bob));
        splitter.claim(REPO_ID, currency0, bob);
    }

    /// @dev Royalties follow the key. This is the whole reason RIK is transferable.
    function test_ClaimFollowsTheKeyAfterTransfer() public {
        _earn(address(asset), 3 ether, 0);
        splitter.collectPoolFees(address(asset));

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NotRepositoryKeyHolder.selector, REPO_ID, alice));
        splitter.claim(REPO_ID, currency0, alice);

        vm.prank(bob);
        assertEq(splitter.claim(REPO_ID, currency0, bob), 3 ether);
    }

    function test_ClaimRejectsEmptyBucket() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NothingToClaim.selector, REPO_ID, currency0));
        splitter.claim(REPO_ID, currency0, alice);
    }

    function test_ClaimEmptiesTheBucketExactlyOnce() public {
        _earn(address(asset), 3 ether, 0);
        splitter.collectPoolFees(address(asset));

        vm.startPrank(alice);
        splitter.claim(REPO_ID, currency0, alice);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NothingToClaim.selector, REPO_ID, currency0));
        splitter.claim(REPO_ID, currency0, alice);
        vm.stopPrank();
    }

    // --- isolation between repositories -------------------------------------

    function test_RepositoriesCannotReachEachOthersBuckets() public {
        MockERC20 otherAsset = new MockERC20("Other", "OTHER");
        _registerRepo(222, OWNER_ID, bob);
        airlock.setAsset(address(otherAsset));
        vm.prank(bob);
        launcher.launch(222, _params());

        _earn(address(asset), 3 ether, 0);
        _earn(address(otherAsset), 7 ether, 0);
        splitter.collectPoolFees(address(asset));
        splitter.collectPoolFees(address(otherAsset));

        (address otherCurrency0,) = _currenciesOf(address(otherAsset));
        assertGt(splitter.claimable(REPO_ID, currency0), 0);
        assertGt(splitter.claimable(222, otherCurrency0), 0);

        // Bob holds 222 but not REPO_ID.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RIKRoyaltySplitter.NotRepositoryKeyHolder.selector, REPO_ID, bob));
        splitter.claim(REPO_ID, currency0, bob);
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

    /// @dev The owner's sweep is paid by the Airlock, so it cannot reduce a repository bucket or the
    ///      balance backing one.
    function test_CollectIntegratorFeesCannotTouchRepositoryBuckets() public {
        _earn(address(asset), 0, 3 ether);
        splitter.collectPoolFees(address(asset));
        uint256 owed = splitter.claimable(REPO_ID, currency1);
        assertGt(owed, 0);

        numeraire.mint(address(airlock), 11 ether);
        airlock.setFees(address(splitter), address(numeraire), 11 ether);

        vm.prank(protocolOwner);
        splitter.collectIntegratorFees(address(numeraire), protocolOwner);

        assertEq(splitter.claimable(REPO_ID, currency1), owed);

        vm.prank(alice);
        assertEq(splitter.claim(REPO_ID, currency1, alice), owed);
    }
}
