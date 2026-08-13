// src/IRIKRoyaltySplitter.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title IRIKRoyaltySplitter
 * @notice The one call {RIKLauncher} makes into the splitter.
 *
 * @dev Declared separately so the launcher and the splitter can be immutably wired to each other
 *      without either importing the other's implementation.
 */
interface IRIKRoyaltySplitter {
    /**
     * @notice Records that `asset` is the market token of repository `githubRepoId`.
     *
     * @dev Implementations are expected to accept this only from the launcher, and to reject an
     *      asset that is already bound to a repository.
     */
    function registerMarket(address asset, uint256 githubRepoId) external;
}
