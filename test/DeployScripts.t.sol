// test/DeployScripts.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployMarket} from "../script/DeployMarket.s.sol";
import {DeployRIK} from "../script/DeployRIK.s.sol";
import {RIK} from "../src/RIK.sol";
import {RIKLauncher} from "../src/RIKLauncher.sol";
import {RIKRoyaltySplitter} from "../src/RIKRoyaltySplitter.sol";

/**
 * @dev Runs the deploy scripts in-process, without broadcasting.
 *
 * The launcher and the splitter can only be wired to each other through a predicted CREATE address,
 * and an incorrect prediction produces contracts that compile, deploy, and then send every fee to
 * an address with no code. That failure is not visible in a unit test of either contract, so the
 * script itself requires coverage.
 */
contract DeployScripts_T is Test {
    uint256 constant DEPLOYER_KEY = 0xA11CE;
    /// @dev The live `identity` verifier on Base Mainnet, which is the one `market` is meant to use.
    address constant VERIFIER = address(0x3731e6a5c0732bf5E9D2fE31bb884A73513be157);
    address constant AIRLOCK = address(0xA141_0c4);
    address constant SPLITTER_OWNER = address(0x0FEE);
    address constant RIK_OWNER = address(0x5AFE);

    uint64 constant ATTESTATION_REPO_ID = 900100200;
    string constant WORKFLOW_REF = "freecodexyz/market/.github/workflows/register-rik.yml@refs/heads/main";

    address deployer;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_KEY);
        vm.setEnv("PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("JWT_VERIFIER_ADDRESS", vm.toString(VERIFIER));
        vm.setEnv("AIRLOCK_ADDRESS", vm.toString(AIRLOCK));
        vm.setEnv("RIK_OWNER", vm.toString(RIK_OWNER));
        vm.setEnv("ATTESTATION_REPO_ID", vm.toString(uint256(ATTESTATION_REPO_ID)));
        vm.setEnv("JOB_WORKFLOW_REF", WORKFLOW_REF);
    }

    function test_DeployRIKPointsAtTheConfiguredVerifier() public {
        RIK rik = new DeployRIK().run();

        assertEq(address(rik.jwt()), VERIFIER);
        assertEq(rik.name(), "Repository Identity Key");
        assertEq(rik.symbol(), "RIK");
    }

    /// @dev A registry with no attestation source rejects every proof, so the script has to leave it
    ///      configured rather than leaving that to a follow-up transaction somebody may forget.
    function test_DeployRIKPinsTheAttestationSource() public {
        RIK rik = new DeployRIK().run();

        assertEq(rik.attestationRepoId(), ATTESTATION_REPO_ID);
        assertEq(rik.jobWorkflowRef(), WORKFLOW_REF);
    }

    /**
     * @dev Configuring the attestation source needs ownership, so the deployer holds it during the
     *      script and hands it over at the end. The handover is two-step, so the deployment finishes
     *      with ownership *pending*: this pins that the deployer is still in control until the new
     *      owner accepts, which is the part an operator has to finish.
     */
    function test_DeployRIKLeavesOwnershipPendingWithTheConfiguredOwner() public {
        RIK rik = new DeployRIK().run();

        assertEq(rik.owner(), deployer);
        assertEq(rik.pendingOwner(), RIK_OWNER);

        vm.prank(RIK_OWNER);
        rik.acceptOwnership();
        assertEq(rik.owner(), RIK_OWNER);
    }

    /// @dev The purpose of the script: each contract ends up holding the other's actual address.
    function test_DeployMarketWiresLauncherAndSplitterToEachOther() public {
        RIK rik = new DeployRIK().run();
        vm.setEnv("RIK_ADDRESS", vm.toString(address(rik)));
        vm.setEnv("SPLITTER_OWNER", vm.toString(SPLITTER_OWNER));

        (RIKLauncher launcher, RIKRoyaltySplitter splitter) = new DeployMarket().run();

        assertEq(address(launcher.splitter()), address(splitter));
        assertEq(splitter.launcher(), address(launcher));
        assertEq(address(launcher.registry()), address(rik));
        assertEq(address(splitter.registry()), address(rik));
        assertEq(address(launcher.airlock()), AIRLOCK);
        assertEq(address(splitter.airlock()), AIRLOCK);
        assertEq(splitter.owner(), SPLITTER_OWNER);
    }

    /// @dev Both addresses must carry code, which is what a stale nonce prediction would break.
    function test_DeployMarketProducesTwoLiveContracts() public {
        RIK rik = new DeployRIK().run();
        vm.setEnv("RIK_ADDRESS", vm.toString(address(rik)));
        vm.setEnv("SPLITTER_OWNER", vm.toString(SPLITTER_OWNER));

        (RIKLauncher launcher, RIKRoyaltySplitter splitter) = new DeployMarket().run();

        assertGt(address(launcher).code.length, 0);
        assertGt(address(splitter).code.length, 0);
        assertGt(address(launcher.splitter()).code.length, 0);
        assertGt(splitter.launcher().code.length, 0);
    }

    /// @dev The launcher must be authorized on the splitter it was handed, or the first launch
    ///      reverts after the market has already been created.
    function test_DeployedLauncherIsAcceptedBySplitter() public {
        RIK rik = new DeployRIK().run();
        vm.setEnv("RIK_ADDRESS", vm.toString(address(rik)));
        vm.setEnv("SPLITTER_OWNER", vm.toString(SPLITTER_OWNER));

        (RIKLauncher launcher, RIKRoyaltySplitter splitter) = new DeployMarket().run();

        vm.prank(address(launcher));
        splitter.registerMarket(address(0xA55E7), address(0x1417), 1296269);
        assertEq(splitter.repoIdOf(address(0xA55E7)), 1296269);
        assertEq(splitter.initializerOf(address(0xA55E7)), address(0x1417));
    }
}
