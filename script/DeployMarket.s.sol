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
 * Both wirings are immutable, so the second contract's address is predicted before the first is
 * deployed. This holds only while the two deployments are consecutive transactions from the same
 * account, so the script asserts that each prediction was correct. An unchecked mismatch would
 * deploy a launcher that routes fees to an address with no code.
 */
contract DeployMarket is Script {
    error AddressPredictionFailed(address predicted, address actual);

    function run() external returns (RIKLauncher launcher, RIKRoyaltySplitter splitter) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address airlock = vm.envAddress("AIRLOCK_ADDRESS");
        address registry = vm.envAddress("RIK_ADDRESS");
        // Required rather than defaulted to the deployer, so the account holding it is stated
        // explicitly. The splitter owner can sweep the Airlock's integrator fees and holds no
        // authority over any repository's bucket.
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
