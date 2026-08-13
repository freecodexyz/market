// test/RIKLauncher.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAirlock} from "../src/IAirlock.sol";
import {IRIKRoyaltySplitter} from "../src/IRIKRoyaltySplitter.sol";
import {RIKLauncher} from "../src/RIKLauncher.sol";
import {RIKRoyaltySplitter} from "../src/RIKRoyaltySplitter.sol";
import {MarketFixture} from "./MarketFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReenteringAirlock} from "./mocks/MockAirlock.sol";

contract RIKLauncher_T is MarketFixture {
    function setUp() public {
        _deployMarket();
    }

    // --- wiring -------------------------------------------------------------

    function test_WiringIsImmutableAndCorrect() public view {
        assertEq(address(launcher.airlock()), address(airlock));
        assertEq(address(launcher.registry()), address(rik));
        assertEq(address(launcher.splitter()), address(splitter));
        assertEq(splitter.launcher(), address(launcher));
    }

    function test_MarketOfIsZeroBeforeLaunch() public view {
        assertEq(launcher.marketOf(REPO_ID), address(0));
    }

    // --- launch happy path --------------------------------------------------

    function test_LaunchCreatesMarketAndRecordsIt() public {
        address launched = _launchedMarket();

        assertEq(launched, address(asset));
        assertEq(launcher.marketOf(REPO_ID), address(asset));
        assertEq(airlock.lastCaller(), address(launcher));
        assertEq(airlock.createCount(), 1);
    }

    function test_LaunchEmitsMarketLaunched() public {
        _registerRepo(REPO_ID, OWNER_ID, alice);

        vm.expectEmit(true, true, true, true);
        emit RIKLauncher.MarketLaunched(REPO_ID, address(asset), alice, POOL_ADDRESS);

        vm.prank(alice);
        launcher.launch(REPO_ID, _params());
    }

    function test_LaunchRegistersMarketWithSplitter() public {
        _launchedMarket();

        assertEq(splitter.repoIdOf(address(asset)), REPO_ID);
    }

    /// @dev A caller-chosen integrator would send every trading fee somewhere the splitter cannot
    ///      collect from, which fails silently: the market works and the repository earns nothing.
    function test_LaunchForcesIntegratorToTheSplitter() public {
        _launchedMarket();

        assertEq(_params().integrator, CALLER_INTEGRATOR, "fixture must attempt a foreign integrator");
        assertEq(airlock.lastParams().integrator, address(splitter));
    }

    function test_LaunchForwardsEveryOtherParameterVerbatim() public {
        _launchedMarket();

        IAirlock.CreateParams memory sent = airlock.lastParams();
        IAirlock.CreateParams memory expected = _params();

        assertEq(sent.initialSupply, expected.initialSupply);
        assertEq(sent.numTokensToSell, expected.numTokensToSell);
        assertEq(sent.numeraire, expected.numeraire);
        assertEq(sent.tokenFactory, expected.tokenFactory);
        assertEq(sent.tokenFactoryData, expected.tokenFactoryData);
        assertEq(sent.governanceFactory, expected.governanceFactory);
        assertEq(sent.governanceFactoryData, expected.governanceFactoryData);
        assertEq(sent.poolInitializer, expected.poolInitializer);
        assertEq(sent.poolInitializerData, expected.poolInitializerData);
        assertEq(sent.liquidityMigrator, expected.liquidityMigrator);
        assertEq(sent.liquidityMigratorData, expected.liquidityMigratorData);
        assertEq(sent.salt, expected.salt);
    }

    // --- authorization ------------------------------------------------------

    function test_RejectsNonHolder() public {
        _registerRepo(REPO_ID, OWNER_ID, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RIKLauncher.NotRepositoryKeyHolder.selector, REPO_ID, bob));
        launcher.launch(REPO_ID, _params());
    }

    /// @dev No key, no market: `ownerOf` reverts before the launcher's own check is reached.
    function test_RejectsUnregisteredRepository() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, REPO_ID));
        launcher.launch(REPO_ID, _params());
    }

    /// @dev Authorization follows the key, so selling it hands over the right to launch.
    function test_NewHolderMayLaunchAfterTransfer() public {
        _registerRepo(REPO_ID, OWNER_ID, alice);

        vm.prank(alice);
        rik.transferFrom(alice, bob, REPO_ID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RIKLauncher.NotRepositoryKeyHolder.selector, REPO_ID, alice));
        launcher.launch(REPO_ID, _params());

        vm.prank(bob);
        launcher.launch(REPO_ID, _params());

        assertEq(launcher.marketOf(REPO_ID), address(asset));
    }

    // --- exclusivity --------------------------------------------------------

    function test_RejectsSecondLaunchForSameRepository() public {
        _launchedMarket();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RIKLauncher.MarketAlreadyLaunched.selector, REPO_ID, address(asset)));
        launcher.launch(REPO_ID, _params());
    }

    /// @dev The exclusivity is per repository, not global.
    function test_TwoRepositoriesGetIndependentMarkets() public {
        MockERC20 otherAsset = new MockERC20("Other", "OTHER");

        _launchedMarket();

        _registerRepo(222, OWNER_ID, bob);
        airlock.setAsset(address(otherAsset));

        vm.prank(bob);
        launcher.launch(222, _params());

        assertEq(launcher.marketOf(REPO_ID), address(asset));
        assertEq(launcher.marketOf(222), address(otherAsset));
        assertEq(splitter.repoIdOf(address(asset)), REPO_ID);
        assertEq(splitter.repoIdOf(address(otherAsset)), 222);
    }

    /// @dev Two repositories cannot end up sharing one asset, which would make the splitter's
    ///      reverse mapping meaningless.
    function test_RejectsSecondRepositoryReusingTheSameAsset() public {
        _launchedMarket();
        _registerRepo(222, OWNER_ID, bob);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(RIKRoyaltySplitter.MarketAlreadyRegistered.selector, address(asset), REPO_ID)
        );
        launcher.launch(222, _params());
    }

    // --- failure modes ------------------------------------------------------

    function test_RejectsZeroAssetFromAirlock() public {
        _registerRepo(REPO_ID, OWNER_ID, alice);
        airlock.setReturnZeroAsset(true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RIKLauncher.MarketCreationFailed.selector, REPO_ID));
        launcher.launch(REPO_ID, _params());
    }

    /// @dev An Airlock that calls back in mid-create must not be able to open a second market for
    ///      the repository behind the exclusivity check.
    function test_RejectsReentrantLaunch() public {
        ReenteringAirlock evil = new ReenteringAirlock(REPO_ID);

        uint64 nonce = vm.getNonce(address(this));
        address launcherAddress = vm.computeCreateAddress(address(this), nonce);
        address splitterAddress = vm.computeCreateAddress(address(this), nonce + 1);

        RIKLauncher evilLauncher = new RIKLauncher(evil, IERC721(address(rik)), IRIKRoyaltySplitter(splitterAddress));
        new RIKRoyaltySplitter(IERC721(address(rik)), evil, launcherAddress, protocolOwner);
        evil.setLauncher(evilLauncher);

        _registerRepo(REPO_ID, OWNER_ID, alice);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        evilLauncher.launch(REPO_ID, _params());
    }
}
