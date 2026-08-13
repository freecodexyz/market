// src/IAirlock.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title IAirlock
 * @notice The Doppler Airlock surface this repository consumes: market creation and integrator fees.
 *
 * @dev Only the calls {RIKLauncher} and {RIKRoyaltySplitter} actually make are declared. The Airlock
 *      is an external protocol, so narrowing the boundary keeps an upstream signature change a
 *      compile error here rather than a silent behavioural one.
 */
interface IAirlock {
    /// @dev The full creation parameter set. Forwarded verbatim except for `integrator`, which
    ///      {RIKLauncher} overwrites so trading fees stay reachable by the splitter.
    struct CreateParams {
        uint256 initialSupply;
        uint256 numTokensToSell;
        address numeraire;
        address tokenFactory;
        bytes tokenFactoryData;
        address governanceFactory;
        bytes governanceFactoryData;
        address poolInitializer;
        bytes poolInitializerData;
        address liquidityMigrator;
        bytes liquidityMigratorData;
        address integrator;
        bytes32 salt;
    }

    /// @notice Creates a market and returns the asset it minted along with its supporting contracts.
    function create(CreateParams calldata params)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool);

    /// @notice Returns the fees the Airlock currently owes `integrator` in `token`.
    function getIntegratorFees(address integrator, address token) external view returns (uint256);

    /**
     * @notice Pays `amount` of the caller's accrued integrator fees in `token` out to `to`.
     *
     * @dev The integrator is the caller, so this only ever moves value the Airlock already holds on
     *      the caller's behalf.
     */
    function collectIntegratorFees(address to, address token, uint256 amount) external;
}
