// src/IRIKRoyaltySplitter.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title IRIKRoyaltySplitter
 * @notice The one call {RIKLauncher} makes into the splitter.
 *
 * @dev Declared separately so the launcher and the splitter can be wired to each other immutably
 *      without either importing the other's implementation.
 */
interface IRIKRoyaltySplitter {
    /**
     * @notice Records that `asset` is the market token of repository `githubRepoId`, and that its
     *         fees are collected from `initializer`.
     *
     * @dev Implementations are expected to accept this only from the launcher, and to reject an
     *      asset that is already bound to a repository. The initializer is recorded here rather
     *      than accepted per collection, so that no caller can point fee collection at a contract
     *      of their own choosing.
     */
    function registerMarket(address asset, address initializer, uint256 githubRepoId) external;
}
