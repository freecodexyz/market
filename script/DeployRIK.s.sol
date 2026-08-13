// script/DeployRIK.s.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";

import {IJwtVerifier} from "../src/IJwtVerifier.sol";
import {RIK} from "../src/RIK.sol";

/**
 * @dev Deploys the repository registry against an already-deployed verifier, and pins the
 *      attestation source it will accept proofs from.
 *
 * `market` never deploys a {GithubOidcVerifier}. The live instance from the `identity` repository
 * already mirrors GitHub's JWKS and is kept in sync there, so referencing it limits this project's
 * unaudited surface to the contracts in `src/` that are new.
 *
 * The registry is deployed owned by the deployer, because configuring the attestation source
 * requires ownership, and is then transferred to `RIK_OWNER`. The transfer is two-step, so the
 * deployment completes with ownership pending: `RIK_OWNER` must call `acceptOwnership` for it to
 * take effect, and until then the deployer retains control. This owner can repoint the attestation
 * source and therefore mint any repository's key, so `RIK_OWNER` should be a multisig or timelock
 * and the acceptance should be completed promptly.
 */
contract DeployRIK is Script {
    function run() external returns (RIK rik) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address verifier = vm.envAddress("JWT_VERIFIER_ADDRESS");
        // Required rather than defaulted: this is the highest-privilege role in the system.
        address initialOwner = vm.envAddress("RIK_OWNER");

        // The attestation repository and the workflow file within it permitted to produce proofs.
        // Both are derived from a checkout rather than entered by hand; see bin/market.
        uint64 attestationRepoId = uint64(vm.envUint("ATTESTATION_REPO_ID"));
        string memory jobWorkflowRef = vm.envString("JOB_WORKFLOW_REF");

        vm.startBroadcast(deployerPrivateKey);
        rik = new RIK(deployer, IJwtVerifier(verifier));
        rik.setAttestationRepoId(attestationRepoId);
        rik.setJobWorkflowRef(jobWorkflowRef);
        if (initialOwner != deployer) rik.transferOwnership(initialOwner);
        vm.stopBroadcast();
    }
}
