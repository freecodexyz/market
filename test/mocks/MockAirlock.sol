// test/mocks/MockAirlock.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAirlock} from "../../src/IAirlock.sol";
import {RIKLauncher} from "../../src/RIKLauncher.sol";

/**
 * @dev Stands in for the Doppler Airlock.
 *
 * Records the {IAirlock-CreateParams} it was handed so a test can prove the launcher rewrote
 * `integrator` and forwarded everything else untouched, and keeps a per-integrator fee ledger it
 * pays out of its own balance.
 */
contract MockAirlock is IAirlock {
    address private _asset;
    address private _pool;
    bool private _returnZeroAsset;

    address private _lastCaller;
    CreateParams private _lastParams;
    uint256 private _createCount;

    mapping(address integrator => mapping(address token => uint256 amount)) private _fees;

    constructor(address asset_, address pool_) {
        _asset = asset_;
        _pool = pool_;
    }

    function setAsset(address asset_) external {
        _asset = asset_;
    }

    function setReturnZeroAsset(bool value) external {
        _returnZeroAsset = value;
    }

    function setFees(address integrator, address token, uint256 amount) external {
        _fees[integrator][token] = amount;
    }

    function lastCaller() external view returns (address) {
        return _lastCaller;
    }

    function lastParams() external view returns (CreateParams memory) {
        return _lastParams;
    }

    function createCount() external view returns (uint256) {
        return _createCount;
    }

    function create(CreateParams calldata params)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool)
    {
        _lastCaller = msg.sender;
        _lastParams = params;
        _createCount++;

        return (_returnZeroAsset ? address(0) : _asset, _pool, address(0xC0DE), address(0xD00D), address(0xE5C0));
    }

    function getIntegratorFees(address integrator, address token) external view returns (uint256) {
        return _fees[integrator][token];
    }

    function collectIntegratorFees(address to, address token, uint256 amount) external {
        uint256 owed = _fees[msg.sender][token];
        require(owed >= amount, "MockAirlock: insufficient fees");

        _fees[msg.sender][token] = owed - amount;
        require(IERC20(token).transfer(to, amount), "MockAirlock: transfer failed");
    }
}

/// @dev An Airlock that calls back into the launcher while it is creating a market.
contract ReenteringAirlock is IAirlock {
    RIKLauncher private _launcher;
    uint256 private immutable _repoId;

    constructor(uint256 repoId_) {
        _repoId = repoId_;
    }

    function setLauncher(RIKLauncher launcher_) external {
        _launcher = launcher_;
    }

    function create(CreateParams calldata params)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool)
    {
        _launcher.launch(_repoId, params);
        return (address(0xA55E7), address(0xB001), address(0), address(0), address(0));
    }

    function getIntegratorFees(address, address) external pure returns (uint256) {
        return 0;
    }

    function collectIntegratorFees(address, address, uint256) external pure {}
}
