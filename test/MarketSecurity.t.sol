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
import {FeeOnTransferERC20, MockERC20} from "./mocks/MockERC20.sol";
import {MockMulticurvePool} from "./mocks/MockMulticurvePool.sol";

/**
 * @dev Adversarial coverage for the market half: broken wiring, hostile tokens, and the window
 *      between the launcher asking the Airlock for a market and recording the answer.
 */
contract MarketSecurity_T is MarketFixture {
    MockMulticurvePool pool;

    function setUp() public {
        _deployMarket();
        _launchedMarket();

        pool = new MockMulticurvePool(address(asset), address(numeraire));
    }

    function _accrue(MockERC20 token, uint256 amount) internal {
        MockMulticurvePool feeder = new MockMulticurvePool(address(asset), address(token));
        token.mint(address(feeder), amount);
        feeder.setFees(0, amount);
        splitter.collectPoolFees(feeder);
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

    /// @dev The quietest broken deployment of the three: no market could ever be registered, so
    ///      every pool would look unknown and no repository would ever be paid.
    function test_SplitterRejectsZeroLauncher() public {
        vm.expectRevert(RIKRoyaltySplitter.InvalidWiring.selector);
        new RIKRoyaltySplitter(IERC721(address(rik)), airlock, address(0), protocolOwner);
    }

    function test_SplitterRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RIKRoyaltySplitter(IERC721(address(rik)), airlock, address(launcher), address(0));
    }

    // --- the launch window --------------------------------------------------

    /**
     * @dev The launcher claims a repository's slot before handing control to the Airlock.
     *
     * `nonReentrant` already stops a nested launch, but one market per repository is what the
     * splitter's reverse mapping depends on, so it is held independently: an Airlock looking at the
     * launcher mid-create sees the slot already taken.
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

    /// @dev A zero asset would make every pool holding the zero address on one side resolve to a
    ///      repository.
    function test_RegisterMarketRejectsZeroAsset() public {
        vm.prank(address(launcher));
        vm.expectRevert(RIKRoyaltySplitter.InvalidAsset.selector);
        splitter.registerMarket(address(0), REPO_ID);
    }

    // --- payout recipients --------------------------------------------------

    /// @dev Not every ERC20 reverts on a transfer to zero, and a bucket empties only once, so an
    ///      unchecked recipient is a one-shot way to burn a repository's earnings.
    function test_ClaimRejectsZeroRecipient() public {
        _accrue(numeraire, 3 ether);

        vm.prank(alice);
        vm.expectRevert(RIKRoyaltySplitter.InvalidRecipient.selector);
        splitter.claim(REPO_ID, address(numeraire), address(0));

        assertEq(splitter.claimable(REPO_ID, address(numeraire)), 3 ether, "the bucket must survive");
    }

    function test_CollectIntegratorFeesRejectsZeroRecipient() public {
        numeraire.mint(address(airlock), 5 ether);
        airlock.setFees(address(splitter), address(numeraire), 5 ether);

        vm.prank(protocolOwner);
        vm.expectRevert(RIKRoyaltySplitter.InvalidRecipient.selector);
        splitter.collectIntegratorFees(address(numeraire), address(0));
    }

    // --- hostile tokens -----------------------------------------------------

    /// @dev A payout that cannot be delivered must leave the bucket intact, so the holder can try
    ///      again to a different recipient.
    function test_UndeliverablePayoutLeavesTheBucketIntact() public {
        RevertingERC20 hostile = new RevertingERC20();

        MockMulticurvePool feeder = new MockMulticurvePool(address(asset), address(hostile));
        hostile.mint(address(feeder), 4 ether);
        feeder.setFees(0, 4 ether);
        splitter.collectPoolFees(feeder);
        assertEq(splitter.claimable(REPO_ID, address(hostile)), 4 ether);

        hostile.setBlocked(true);
        vm.prank(alice);
        vm.expectRevert(RevertingERC20.TransferDisabled.selector);
        splitter.claim(REPO_ID, address(hostile), alice);

        assertEq(splitter.claimable(REPO_ID, address(hostile)), 4 ether, "the bucket must survive");

        // And once the token works again, the same bucket pays out exactly once.
        hostile.setBlocked(false);
        vm.prank(alice);
        assertEq(splitter.claim(REPO_ID, address(hostile), alice), 4 ether);
        assertEq(splitter.claimable(REPO_ID, address(hostile)), 0);
    }

    /// @dev The non-compliant ERC20 {SafeERC20} exists for: reports failure instead of reverting.
    function test_TokenReportingFailureIsTreatedAsAFailure() public {
        FalseReturningERC20 silent = new FalseReturningERC20();

        MockMulticurvePool feeder = new MockMulticurvePool(address(asset), address(silent));
        silent.mint(address(feeder), 4 ether);
        feeder.setFees(0, 4 ether);
        // The pool's own transfer also reports false, so nothing ever arrives and nothing accrues.
        vm.expectRevert();
        splitter.collectPoolFees(feeder);
    }

    /// @dev A token that calls back into the splitter during a payout cannot be paid twice.
    function test_ReentrantTokenCannotDrainABucketTwice() public {
        ReenteringERC20 hostile = new ReenteringERC20();

        MockMulticurvePool feeder = new MockMulticurvePool(address(asset), address(hostile));
        hostile.mint(address(feeder), 6 ether);
        feeder.setFees(0, 6 ether);
        splitter.collectPoolFees(feeder);

        hostile.arm(splitter, REPO_ID);

        vm.prank(alice);
        uint256 claimed = splitter.claim(REPO_ID, address(hostile), alice);

        assertEq(claimed, 6 ether);
        assertTrue(hostile.reentered(), "the callback must have been reached");
        assertFalse(hostile.reentrySucceeded(), "the reentrant claim must have failed");
        assertEq(splitter.claimable(REPO_ID, address(hostile)), 0);
        assertEq(hostile.balanceOf(alice), 6 ether, "paid exactly once");
    }

    // --- ownership ----------------------------------------------------------

    /**
     * @dev Renouncing is left available, and this pins what it costs: the sweep is gone for good,
     *      and every repository bucket is completely unaffected. The owner never had any authority
     *      over those, which is what makes renouncing survivable rather than catastrophic.
     */
    function test_RenouncingOwnershipDisablesOnlyTheSweep() public {
        _accrue(numeraire, 7 ether);
        numeraire.mint(address(airlock), 5 ether);
        airlock.setFees(address(splitter), address(numeraire), 5 ether);

        vm.prank(protocolOwner);
        splitter.renounceOwnership();
        assertEq(splitter.owner(), address(0));

        vm.prank(protocolOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, protocolOwner));
        splitter.collectIntegratorFees(address(numeraire), protocolOwner);

        // The repository is untouched and can still be paid.
        vm.prank(alice);
        assertEq(splitter.claim(REPO_ID, address(numeraire), alice), 7 ether);
    }

    // --- fuzz ---------------------------------------------------------------

    /// @dev Whatever arrives is what is credited, across the whole uint96 range.
    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 25000
    function testFuzz_AccrualEqualsTheBalanceDelta(uint96 fees0, uint96 fees1) public {
        asset.mint(address(pool), fees0);
        numeraire.mint(address(pool), fees1);
        pool.setFees(fees0, fees1);

        uint256 before0 = asset.balanceOf(address(splitter));
        uint256 before1 = numeraire.balanceOf(address(splitter));

        (uint256 amount0, uint256 amount1) = splitter.collectPoolFees(pool);

        assertEq(amount0, asset.balanceOf(address(splitter)) - before0);
        assertEq(amount1, numeraire.balanceOf(address(splitter)) - before1);
        assertEq(splitter.claimable(REPO_ID, address(asset)), amount0);
        assertEq(splitter.claimable(REPO_ID, address(numeraire)), amount1);
    }

    /// @dev A claim pays the whole bucket and leaves nothing behind, for any amount.
    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 25000
    function testFuzz_ClaimPaysExactlyTheBucket(uint96 amount, address recipient) public {
        vm.assume(amount != 0);
        vm.assume(recipient != address(0) && recipient != address(splitter));

        numeraire.mint(address(pool), amount);
        pool.setFees(0, amount);
        splitter.collectPoolFees(pool);

        uint256 before = numeraire.balanceOf(recipient);

        vm.prank(alice);
        uint256 claimed = splitter.claim(REPO_ID, address(numeraire), recipient);

        assertEq(claimed, amount);
        assertEq(numeraire.balanceOf(recipient) - before, amount);
        assertEq(splitter.claimable(REPO_ID, address(numeraire)), 0);
    }

    /// @dev A token that keeps part of every transfer must never create a claim that cannot be
    ///      paid, at any fee rate.
    /// forge-config: default.fuzz.runs = 1024
    /// forge-config: deep.fuzz.runs = 10000
    function testFuzz_FeeOnTransferNeverOvercredits(uint96 amount, uint16 rawFeeBps) public {
        uint256 feeBps = bound(uint256(rawFeeBps), 0, 9_999);
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20("Taxed", "TAX", feeBps);

        MockMulticurvePool feeder = new MockMulticurvePool(address(asset), address(taxed));
        taxed.mint(address(feeder), amount);
        feeder.setFees(0, amount);

        (, uint256 credited) = splitter.collectPoolFees(feeder);

        assertLe(credited, uint256(amount));
        assertLe(splitter.claimable(REPO_ID, address(taxed)), taxed.balanceOf(address(splitter)));
    }

    /// @dev Accrual accumulates exactly, over any sequence of collections.
    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 5000
    function testFuzz_AccrualAccumulatesExactly(uint96[8] calldata amounts) public {
        uint256 expected;
        for (uint256 i = 0; i < amounts.length; ++i) {
            numeraire.mint(address(pool), amounts[i]);
            pool.setFees(0, amounts[i]);
            splitter.collectPoolFees(pool);
            expected += uint256(amounts[i]);
        }

        assertEq(splitter.claimable(REPO_ID, address(numeraire)), expected);
        assertEq(numeraire.balanceOf(address(splitter)), expected);
    }
}
