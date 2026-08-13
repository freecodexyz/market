// test/MarketSecurity.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IAirlock} from "../src/IAirlock.sol";
import {IRIKRoyaltySplitter} from "../src/IRIKRoyaltySplitter.sol";
import {RIKLauncher} from "../src/RIKLauncher.sol";
import {RIKRoyaltySplitter} from "../src/RIKRoyaltySplitter.sol";
import {MarketFixture} from "./MarketFixture.sol";
import {
    FalseReturningERC20,
    ObservingAirlock,
    ReenteringERC20,
    RevertingERC20,
    SentinelReturningAirlock
} from "./mocks/Adversarial.sol";
import {DrainingInitializer, MockDopplerHookInitializer} from "./mocks/MockDopplerHookInitializer.sol";
import {FeeOnTransferERC20, MockERC20} from "./mocks/MockERC20.sol";

/**
 * @dev Adversarial coverage for the market half: broken wiring, hostile tokens, and the window
 *      between the launcher asking the Airlock for a market and recording the answer.
 */
contract MarketSecurity_T is MarketFixture {
    function setUp() public {
        _deployMarket();
        _launchedMarket();
    }

    /// @dev Launches a second market whose asset is `token`, so a hostile token is reached through
    ///      a real pool rather than credited directly.
    function _launchWith(address token, uint256 repoId, address holder) internal {
        _registerRepo(repoId, OWNER_ID, holder);
        airlock.setAsset(token);
        vm.prank(holder);
        launcher.launch(repoId, _params());
    }

    // --- wiring -------------------------------------------------------------

    function test_LauncherRejectsZeroAirlock() public {
        vm.expectRevert(RIKLauncher.InvalidWiring.selector);
        new RIKLauncher(IAirlock(address(0)), IERC721(address(rik)), IRIKRoyaltySplitter(address(splitter)));
    }

    function test_LauncherRejectsZeroRegistry() public {
        vm.expectRevert(RIKLauncher.InvalidWiring.selector);
        new RIKLauncher(airlock, IERC721(address(0)), IRIKRoyaltySplitter(address(splitter)));
    }

    function test_LauncherRejectsZeroSplitter() public {
        vm.expectRevert(RIKLauncher.InvalidWiring.selector);
        new RIKLauncher(airlock, IERC721(address(rik)), IRIKRoyaltySplitter(address(0)));
    }

    function test_SplitterRejectsZeroRegistry() public {
        vm.expectRevert(RIKRoyaltySplitter.InvalidWiring.selector);
        new RIKRoyaltySplitter(IERC721(address(0)), airlock, address(launcher), protocolOwner);
    }

    function test_SplitterRejectsZeroAirlock() public {
        vm.expectRevert(RIKRoyaltySplitter.InvalidWiring.selector);
        new RIKRoyaltySplitter(IERC721(address(rik)), IAirlock(address(0)), address(launcher), protocolOwner);
    }

    function test_SplitterRejectsZeroLauncher() public {
        vm.expectRevert(RIKRoyaltySplitter.InvalidWiring.selector);
        new RIKRoyaltySplitter(IERC721(address(rik)), airlock, address(0), protocolOwner);
    }

    function test_SplitterRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RIKRoyaltySplitter(IERC721(address(rik)), airlock, address(launcher), address(0));
    }

    // --- the launch guarantees ----------------------------------------------

    /**
     * @dev Doppler fixes a pool's beneficiaries at creation, so a market launched without the
     *      splitter registered would accrue nothing for the repository and could not be corrected.
     *      The launcher rejects the launch instead.
     */
    function test_RejectsLaunchWhenSplitterIsNotABeneficiary() public {
        MockERC20 otherAsset = new MockERC20("Other", "OTHER");
        _registerRepo(222, OWNER_ID, bob);

        airlock.setAsset(address(otherAsset));
        airlock.setIntegratorShares(0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RIKLauncher.SplitterNotBeneficiary.selector, 222, address(initializer)));
        launcher.launch(222, _params());

        assertEq(launcher.marketOf(222), address(0), "a refused launch must leave no market");
        assertEq(splitter.repoIdOf(address(otherAsset)), 0);
    }

    /// @dev Fees are released as ERC20 transfers, so a native numeraire would be paid as value the
    ///      splitter can neither receive nor account for.
    function test_RejectsNativeNumeraire() public {
        _registerRepo(222, OWNER_ID, bob);

        vm.prank(bob);
        vm.expectRevert(RIKLauncher.NativeNumeraireUnsupported.selector);
        launcher.launch(222, _paramsFor(address(0), address(initializer)));
    }

    /**
     * @dev The launcher reserves a repository's market slot before handing control to the Airlock.
     *      `nonReentrant` already prevents a nested launch; the reservation makes
     *      one-market-per-repository hold even if that guard were removed.
     */
    function test_SlotIsReservedBeforeTheAirlockIsCalled() public {
        ObservingAirlock observer = new ObservingAirlock(address(asset), 222333);

        uint64 nonce = vm.getNonce(address(this));
        address launcherAddress = vm.computeCreateAddress(address(this), nonce);
        address splitterAddress = vm.computeCreateAddress(address(this), nonce + 1);

        RIKLauncher observed = new RIKLauncher(observer, IERC721(address(rik)), IRIKRoyaltySplitter(splitterAddress));
        new RIKRoyaltySplitter(IERC721(address(rik)), observer, launcherAddress, protocolOwner);
        observer.setLauncher(observed);

        _registerRepo(222333, OWNER_ID, bob);
        assertEq(observed.marketOf(222333), address(0), "slot must start empty");

        vm.prank(bob);
        observed.launch(222333, _params());

        assertEq(observer.observedMarket(), address(1), "the slot was not reserved before the call");
        assertEq(observed.marketOf(222333), address(asset), "the slot must end up holding the asset");
    }

    /// @dev An Airlock handing back the launcher's own in-progress marker is refused rather than
    ///      recorded as a market.
    function test_RejectsAirlockReturningTheReservationMarker() public {
        SentinelReturningAirlock hostile = new SentinelReturningAirlock();

        uint64 nonce = vm.getNonce(address(this));
        address launcherAddress = vm.computeCreateAddress(address(this), nonce);
        address splitterAddress = vm.computeCreateAddress(address(this), nonce + 1);

        RIKLauncher hostileLauncher =
            new RIKLauncher(hostile, IERC721(address(rik)), IRIKRoyaltySplitter(splitterAddress));
        new RIKRoyaltySplitter(IERC721(address(rik)), hostile, launcherAddress, protocolOwner);

        _registerRepo(222333, OWNER_ID, bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RIKLauncher.MarketCreationFailed.selector, 222333));
        hostileLauncher.launch(222333, _params());
    }

    // --- market registration ------------------------------------------------

    function test_RegisterMarketRejectsZeroAsset() public {
        vm.prank(address(launcher));
        vm.expectRevert(RIKRoyaltySplitter.InvalidAsset.selector);
        splitter.registerMarket(address(0), address(initializer), REPO_ID);
    }

    // --- payout recipients --------------------------------------------------

    /// @dev Not every ERC20 reverts on a transfer to zero, and a bucket empties only once, so an
    ///      unchecked recipient would permanently destroy a repository's earnings.
    function test_ClaimRejectsZeroRecipient() public {
        _earn(address(asset), 3 ether, 0);
        splitter.collectPoolFees(address(asset));
        (address currency0,) = _currenciesOf(address(asset));

        vm.prank(alice);
        vm.expectRevert(RIKRoyaltySplitter.InvalidRecipient.selector);
        splitter.claim(REPO_ID, currency0, address(0));

        assertEq(splitter.claimable(REPO_ID, currency0), 3 ether, "the bucket must survive");
    }

    function test_CollectIntegratorFeesRejectsZeroRecipient() public {
        numeraire.mint(address(airlock), 5 ether);
        airlock.setFees(address(splitter), address(numeraire), 5 ether);

        vm.prank(protocolOwner);
        vm.expectRevert(RIKRoyaltySplitter.InvalidRecipient.selector);
        splitter.collectIntegratorFees(address(numeraire), address(0));
    }

    // --- hostile tokens -----------------------------------------------------

    /// @dev A payout that cannot be delivered must leave the bucket intact, so the holder can retry
    ///      to a different recipient.
    function test_UndeliverablePayoutLeavesTheBucketIntact() public {
        RevertingERC20 hostile = new RevertingERC20();
        _launchWith(address(hostile), 222, bob);

        hostile.mint(address(initializer), 4 ether);
        (address c0,) = _currenciesOf(address(hostile));
        bool assetIsZero = c0 == address(hostile);
        initializer.accrue(address(hostile), assetIsZero ? 4 ether : 0, assetIsZero ? 0 : 4 ether);
        splitter.collectPoolFees(address(hostile));
        assertEq(splitter.claimable(222, address(hostile)), 4 ether);

        hostile.setBlocked(true);
        vm.prank(bob);
        vm.expectRevert(RevertingERC20.TransferDisabled.selector);
        splitter.claim(222, address(hostile), bob);

        assertEq(splitter.claimable(222, address(hostile)), 4 ether, "the bucket must survive");

        hostile.setBlocked(false);
        vm.prank(bob);
        assertEq(splitter.claim(222, address(hostile), bob), 4 ether);
        assertEq(splitter.claimable(222, address(hostile)), 0);
    }

    /// @dev The non-compliant ERC20 {SafeERC20} exists for: reports failure instead of reverting.
    ///      Doppler's release path requires a successful transfer, so nothing is ever credited.
    function test_TokenReportingFailureIsTreatedAsAFailure() public {
        FalseReturningERC20 silent = new FalseReturningERC20();
        _launchWith(address(silent), 222, bob);

        silent.mint(address(initializer), 4 ether);
        (address c0,) = _currenciesOf(address(silent));
        bool assetIsZero = c0 == address(silent);
        initializer.accrue(address(silent), assetIsZero ? 4 ether : 0, assetIsZero ? 0 : 4 ether);

        vm.expectRevert();
        splitter.collectPoolFees(address(silent));
    }

    /// @dev A token that calls back into the splitter during a payout cannot be paid twice.
    function test_ReentrantTokenCannotDrainABucketTwice() public {
        ReenteringERC20 hostile = new ReenteringERC20();
        _launchWith(address(hostile), 222, bob);

        hostile.mint(address(initializer), 6 ether);
        (address c0,) = _currenciesOf(address(hostile));
        bool assetIsZero = c0 == address(hostile);
        initializer.accrue(address(hostile), assetIsZero ? 6 ether : 0, assetIsZero ? 0 : 6 ether);
        splitter.collectPoolFees(address(hostile));

        hostile.arm(splitter, 222);

        vm.prank(bob);
        uint256 claimed = splitter.claim(222, address(hostile), bob);

        assertEq(claimed, 6 ether);
        assertTrue(hostile.reentered(), "the callback must have been reached");
        assertFalse(hostile.reentrySucceeded(), "the reentrant claim must have failed");
        assertEq(splitter.claimable(222, address(hostile)), 0);
        assertEq(hostile.balanceOf(bob), 6 ether, "paid exactly once");
    }

    /// @dev An initializer that removes tokens instead of paying them must revert, not wrap around
    ///      into an enormous credit that would drain every other repository's bucket.
    function test_CollectPoolFeesRevertsWhenBalanceShrinks() public {
        _earn(address(asset), 5 ether, 5 ether);
        splitter.collectPoolFees(address(asset));

        DrainingInitializer draining = new DrainingInitializer(1 ether);
        MockERC20 otherAsset = new MockERC20("Other", "OTHER");
        _registerRepo(222, OWNER_ID, bob);
        airlock.setAsset(address(otherAsset));
        vm.prank(bob);
        launcher.launch(222, _paramsFor(address(numeraire), address(draining)));

        vm.expectRevert();
        splitter.collectPoolFees(address(otherAsset));
    }

    // --- ownership ----------------------------------------------------------

    /**
     * @dev Renouncing is available, and this records its effect: the sweep is permanently disabled
     *      and repository buckets are unaffected, because the owner has no authority over those.
     */
    function test_RenouncingOwnershipDisablesOnlyTheSweep() public {
        _earn(address(asset), 0, 7 ether);
        splitter.collectPoolFees(address(asset));
        (, address currency1) = _currenciesOf(address(asset));
        uint256 owed = splitter.claimable(REPO_ID, currency1);
        assertGt(owed, 0);

        numeraire.mint(address(airlock), 5 ether);
        airlock.setFees(address(splitter), address(numeraire), 5 ether);

        vm.prank(protocolOwner);
        splitter.renounceOwnership();
        assertEq(splitter.owner(), address(0));

        vm.prank(protocolOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, protocolOwner));
        splitter.collectIntegratorFees(address(numeraire), protocolOwner);

        vm.prank(alice);
        assertEq(splitter.claim(REPO_ID, currency1, alice), owed);
    }

    // --- fuzz ---------------------------------------------------------------

    /// @dev Whatever arrives is what is credited, across the whole uint96 range.
    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 25000
    function testFuzz_AccrualEqualsTheBalanceDelta(uint96 fees0, uint96 fees1) public {
        (address currency0, address currency1) = _currenciesOf(address(asset));
        _earn(address(asset), fees0, fees1);

        uint256 before0 = MockERC20(currency0).balanceOf(address(splitter));
        uint256 before1 = MockERC20(currency1).balanceOf(address(splitter));

        (uint256 amount0, uint256 amount1) = splitter.collectPoolFees(address(asset));

        assertEq(amount0, MockERC20(currency0).balanceOf(address(splitter)) - before0);
        assertEq(amount1, MockERC20(currency1).balanceOf(address(splitter)) - before1);
        assertEq(splitter.claimable(REPO_ID, currency0), amount0);
        assertEq(splitter.claimable(REPO_ID, currency1), amount1);
    }

    /// @dev A claim pays the whole bucket and leaves nothing behind, for any amount.
    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 25000
    function testFuzz_ClaimPaysExactlyTheBucket(uint96 amount, address recipient) public {
        vm.assume(amount != 0);
        vm.assume(recipient != address(0) && recipient != address(splitter) && recipient != address(initializer));

        (address currency0,) = _currenciesOf(address(asset));
        _earn(address(asset), amount, 0);
        splitter.collectPoolFees(address(asset));

        uint256 before = MockERC20(currency0).balanceOf(recipient);

        vm.prank(alice);
        uint256 claimed = splitter.claim(REPO_ID, currency0, recipient);

        assertEq(claimed, amount);
        assertEq(MockERC20(currency0).balanceOf(recipient) - before, amount);
        assertEq(splitter.claimable(REPO_ID, currency0), 0);
    }

    /// @dev A token that keeps part of every transfer must never create a claim that cannot be paid.
    /// forge-config: default.fuzz.runs = 1024
    /// forge-config: deep.fuzz.runs = 10000
    function testFuzz_FeeOnTransferNeverOvercredits(uint96 amount, uint16 rawFeeBps) public {
        uint256 feeBps = bound(uint256(rawFeeBps), 0, 9_999);
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20("Taxed", "TAX", feeBps);
        _launchWith(address(taxed), 222, bob);

        taxed.mint(address(initializer), amount);
        (address c0,) = _currenciesOf(address(taxed));
        bool assetIsZero = c0 == address(taxed);
        initializer.accrue(address(taxed), assetIsZero ? amount : 0, assetIsZero ? 0 : amount);

        splitter.collectPoolFees(address(taxed));

        assertLe(splitter.claimable(222, address(taxed)), taxed.balanceOf(address(splitter)));
    }

    /// @dev Accrual accumulates exactly, over any sequence of collections.
    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 5000
    function testFuzz_AccrualAccumulatesExactly(uint96[8] calldata amounts) public {
        (address currency0,) = _currenciesOf(address(asset));
        uint256 expected;

        for (uint256 i = 0; i < amounts.length; ++i) {
            _earn(address(asset), amounts[i], 0);
            splitter.collectPoolFees(address(asset));
            expected += uint256(amounts[i]);
        }

        assertEq(splitter.claimable(REPO_ID, currency0), expected);
        assertEq(MockERC20(currency0).balanceOf(address(splitter)), expected);
    }
}
