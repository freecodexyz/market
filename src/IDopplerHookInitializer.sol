// src/IDopplerHookInitializer.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @notice The Uniswap V4 pool key, reproduced so this project can compute a pool id without
 *         importing v4-core.
 *
 * @dev Field order and types are exactly `Uniswap/v4-core/src/types/PoolKey.sol`. `Currency` and
 *      `IHooks` are a user-defined value type over `address` and an interface, both of which ABI
 *      encode as `address`, so this struct decodes identically to the real one.
 */
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/**
 * @title IDopplerHookInitializer
 * @notice The Doppler initializer surface {RIKRoyaltySplitter} collects trading fees through.
 *
 * @dev Uniswap V4 is a singleton, so a pool is a `PoolKey` rather than a contract. Fees are held by
 *      the initializer and distributed by share: `collectFees` harvests into cumulative accounting
 *      and releases only the caller's portion, to a beneficiary registered when the pool was
 *      created. An address with no shares collects nothing.
 *
 *      Every signature here was checked against the contracts deployed on Base Mainnet:
 *
 *      | Function                     | Selector     |
 *      | ---------------------------- | ------------ |
 *      | `getState(address)`          | `0x1bab58f5` |
 *      | `getShares(bytes32,address)` | `0x5ebb58fb` |
 *      | `collectFees(bytes32)`       | `0x817db73b` |
 *
 *      All three are present in both `DopplerHookInitializer` and `RehypeDopplerHookInitializer`.
 *      See AGENTS.md for how to re-check them.
 */
interface IDopplerHookInitializer {
    /**
     * @notice Returns the stored state of the pool created for `asset`.
     *
     * @dev The tuple is the compiler-generated getter over Doppler's `PoolState` struct, which omits
     *      its two struct arrays. Only `poolKey` is read here; the other members are named to
     *      document the shape. `RehypeDopplerHookInitializer.collectFees` destructures it the same
     *      way.
     */
    function getState(address asset)
        external
        view
        returns (
            address numeraire,
            uint256 totalTokensOnBondingCurve,
            address dopplerHook,
            bytes memory graduationDopplerHookCalldata,
            uint8 status,
            PoolKey memory poolKey,
            int24 farTick
        );

    /**
     * @notice Returns the share of `poolId`'s fees allocated to `beneficiary`, denominated in WAD.
     *
     * @dev Zero means the address was not registered as a beneficiary when the pool was created and
     *      can never collect anything from it. Shares are fixed at creation.
     */
    function getShares(bytes32 poolId, address beneficiary) external view returns (uint256);

    /**
     * @notice Harvests `poolId`'s outstanding fees and releases the caller's share to the caller.
     *
     * @dev Permissionless, but only pays an address holding shares. The return value reports what
     *      was harvested into the pool's cumulative accounting, which is not the same as what was
     *      released to the caller, so it must not be treated as an amount received.
     */
    function collectFees(bytes32 poolId) external returns (uint128 fees0, uint128 fees1);
}
