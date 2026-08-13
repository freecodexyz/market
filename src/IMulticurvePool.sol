// src/IMulticurvePool.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title IMulticurvePool
 * @notice The Doppler pool surface {RIKRoyaltySplitter} collects trading fees through.
 *
 * @dev A pool reached through this interface is untrusted. `token0` and `token1` are used only to
 *      determine which repository the pool belongs to. The splitter measures a balance delta across
 *      {collectFees} rather than relying on any amount the pool reports.
 */
interface IMulticurvePool {
    /// @notice Returns the lower-sorted token of the pair.
    function token0() external view returns (address);

    /// @notice Returns the higher-sorted token of the pair.
    function token1() external view returns (address);

    /// @notice Pays the caller's accrued position fees out to the caller.
    function collectFees() external;
}
