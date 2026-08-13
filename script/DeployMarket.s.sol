// script/DeployMarket.s.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Script} from "forge-std/Script.sol";

import {IAirlock} from "../src/IAirlock.sol";
import {IRIKRoyaltySplitter} from "../src/IRIKRoyaltySplitter.sol";
import {RIKLauncher} from "../src/RIKLauncher.sol";
import {RIKRoyaltySplitter} from "../src/RIKRoyaltySplitter.sol";

/**
 * @dev Deploys the launcher and the splitter, which point at each other.
 *
 * Both wirings are immutable, so the circle is closed by predicting the second contract's address
 * before deploying the first. That is only sound while the two deployments are consecutive
 * transactions from the same account, which is why the script asserts the prediction held rather
 * than trusting it: a mismatch would otherwise ship a launcher paying fees into an empty address.
 */
contract DeployMarket is Script {
    error AddressPredictionFailed(address predicted, address actual);

    function run() external returns (RIKLauncher launcher, RIKRoyaltySplitter splitter) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address airlock = vm.envAddress("AIRLOCK_ADDRESS");
        address registry = vm.envAddress("RIK_ADDRESS");
        // Required rather than defaulted to the deployer. The splitter owner can sweep the Airlock's
        // integrator fees, so which account ends up holding that is a decision to make out loud.
        // It holds no authority over any repository's bucket.
        address splitterOwner = vm.envAddress("SPLITTER_OWNER");

        uint64 nonce = vm.getNonce(deployer);
        address predictedLauncher = vm.computeCreateAddress(deployer, nonce);
        address predictedSplitter = vm.computeCreateAddress(deployer, nonce + 1);

        vm.startBroadcast(deployerPrivateKey);
        launcher = new RIKLauncher(IAirlock(airlock), IERC721(registry), IRIKRoyaltySplitter(predictedSplitter));
        splitter = new RIKRoyaltySplitter(IERC721(registry), IAirlock(airlock), predictedLauncher, splitterOwner);
        vm.stopBroadcast();

        if (address(launcher) != predictedLauncher) {
            revert AddressPredictionFailed(predictedLauncher, address(launcher));
        }
        if (address(splitter) != predictedSplitter) {
            revert AddressPredictionFailed(predictedSplitter, address(splitter));
        }
    }
}
