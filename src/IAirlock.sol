// src/IAirlock.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title IAirlock
 * @notice The Doppler Airlock surface this repository consumes: market creation and integrator fees.
 *
 * @dev Declares only the calls {RIKLauncher} and {RIKRoyaltySplitter} make. The Airlock is an
 *      external protocol; narrowing the boundary makes an upstream signature change a compile error
 *      rather than a silent behavioural change.
 */
interface IAirlock {
    /// @dev The full creation parameter set. Forwarded unchanged except for `integrator`, which
    ///      {RIKLauncher} overwrites so that trading fees remain collectable by the splitter.
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
     * @dev The integrator is the caller, so this moves only value the Airlock already holds on the
     *      caller's behalf.
     */
    function collectIntegratorFees(address to, address token, uint256 amount) external;
}
