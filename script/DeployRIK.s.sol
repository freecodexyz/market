// script/DeployRIK.s.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";

import {IJwtVerifier} from "../src/IJwtVerifier.sol";
import {RIK} from "../src/RIK.sol";

/**
 * @dev Deploys the repository registry against an already-deployed verifier.
 *
 * `market` never deploys a {GithubOidcVerifier}. The live instance from the `identity` repository
 * already mirrors GitHub's JWKS and is kept in sync there, so pointing at it is what keeps this
 * project's trusted, non-audited surface down to the three contracts in `src/` that are actually
 * new.
 */
contract DeployRIK is Script {
    function run() external returns (RIK rik) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address verifier = vm.envAddress("JWT_VERIFIER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);
        rik = new RIK(IJwtVerifier(verifier));
        vm.stopBroadcast();
    }
}
