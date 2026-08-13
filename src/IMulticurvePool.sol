// src/IMulticurvePool.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title IMulticurvePool
 * @notice The Doppler pool surface {RIKRoyaltySplitter} collects trading fees through.
 *
 * @dev A pool reached through this interface is untrusted. `token0` and `token1` are used only to
 *      look up which repository the pool belongs to, and {collectFees} pays whatever it pays; the
 *      splitter measures a balance delta rather than believing a reported amount.
 */
interface IMulticurvePool {
    /// @notice Returns the lower-sorted token of the pair.
    function token0() external view returns (address);

    /// @notice Returns the higher-sorted token of the pair.
    function token1() external view returns (address);

    /// @notice Pays the caller's accrued position fees out to the caller.
    function collectFees() external;
}
