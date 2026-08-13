// test/mocks/MockDopplerHookInitializer.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDopplerHookInitializer, PoolKey} from "../../src/IDopplerHookInitializer.sol";
import {RIKRoyaltySplitter} from "../../src/RIKRoyaltySplitter.sol";

/**
 * @dev Stands in for a Doppler pool initializer.
 *
 * `collectFees` pays the caller, and only in proportion to shares fixed when the pool was created.
 * A mock that transferred its balance to any caller would exercise semantics Doppler does not have,
 * so the cumulative-fee bookkeeping, the per-beneficiary high-water marks and the release step are
 * taken from `whetstoneresearch/doppler/src/base/FeesManager.sol`.
 */
contract MockDopplerHookInitializer is IDopplerHookInitializer {
    uint256 internal constant WAD = 1e18;

    mapping(address asset => PoolKey key) internal _poolKey;
    mapping(address asset => bool created) internal _created;
    /// @dev The real contract keeps the same mapping as `getPoolKey[poolId]`.
    mapping(bytes32 poolId => PoolKey key) internal _keyById;

    mapping(bytes32 poolId => mapping(address beneficiary => uint256 shares)) internal _shares;
    mapping(bytes32 poolId => uint256 cumulated) internal _cumulated0;
    mapping(bytes32 poolId => uint256 cumulated) internal _cumulated1;
    mapping(bytes32 poolId => mapping(address beneficiary => uint256 last)) internal _lastCumulated0;
    mapping(bytes32 poolId => mapping(address beneficiary => uint256 last)) internal _lastCumulated1;

    /// @dev Fees the pool has earned but not yet harvested into cumulative accounting.
    mapping(bytes32 poolId => uint256 pending) internal _pending0;
    mapping(bytes32 poolId => uint256 pending) internal _pending1;

    uint256 public collectCount;

    // --- test setup ---------------------------------------------------------

    /// @dev Records the pool key for `asset`, sorting the pair the way Uniswap V4 requires.
    function createPool(address asset, address numeraire, uint24 fee, int24 tickSpacing) public virtual {
        (address currency0, address currency1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        _poolKey[asset] = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: address(this)
        });
        _created[asset] = true;
        _keyById[poolIdOf(asset)] = _poolKey[asset];
    }

    /// @dev Registers a beneficiary, as `_storeBeneficiaries` does when a pool is created.
    function setShares(address asset, address beneficiary, uint256 shares) public virtual {
        _shares[poolIdOf(asset)][beneficiary] = shares;
    }

    /// @dev Credits fees the pool has earned. The tokens must already be held by this contract, the
    ///      way real fees are held by the initializer until a beneficiary collects.
    function accrue(address asset, uint256 amount0, uint256 amount1) public virtual {
        bytes32 poolId = poolIdOf(asset);
        _pending0[poolId] += amount0;
        _pending1[poolId] += amount1;
    }

    function poolIdOf(address asset) public view virtual returns (bytes32) {
        return keccak256(abi.encode(_poolKey[asset]));
    }

    function cumulatedFees(address asset) external view returns (uint256, uint256) {
        bytes32 poolId = poolIdOf(asset);
        return (_cumulated0[poolId], _cumulated1[poolId]);
    }

    // --- the Doppler surface ------------------------------------------------

    /// @inheritdoc IDopplerHookInitializer
    function getState(address asset)
        external
        view
        virtual
        returns (address, uint256, address, bytes memory, uint8, PoolKey memory, int24)
    {
        return (_poolKey[asset].currency1, 0, address(0), "", _created[asset] ? 2 : 0, _poolKey[asset], int24(0));
    }

    /// @inheritdoc IDopplerHookInitializer
    function getShares(bytes32 poolId, address beneficiary) external view virtual returns (uint256) {
        return _shares[poolId][beneficiary];
    }

    /**
     * @inheritdoc IDopplerHookInitializer
     *
     * @dev Mirrors `FeesManager.collectFees`: harvest into cumulative accounting, then release only
     *      the caller's share. An address with no shares receives nothing, however much the pool has
     *      earned.
     */
    function collectFees(bytes32 poolId) external virtual returns (uint128 fees0, uint128 fees1) {
        collectCount++;

        fees0 = uint128(_pending0[poolId]);
        fees1 = uint128(_pending1[poolId]);
        _pending0[poolId] = 0;
        _pending1[poolId] = 0;

        _cumulated0[poolId] += fees0;
        _cumulated1[poolId] += fees1;

        _releaseFees(poolId, msg.sender);
    }

    /// @dev `FeesManager._releaseFees`, including the per-beneficiary high-water marks that make a
    ///      second collection with no new fees pay nothing.
    function _releaseFees(bytes32 poolId, address beneficiary) internal virtual {
        uint256 shares = _shares[poolId][beneficiary];
        if (shares == 0) return;

        PoolKey memory key = _keyOf(poolId);

        uint256 delta0 = _cumulated0[poolId] - _lastCumulated0[poolId][beneficiary];
        uint256 amount0 = delta0 * shares / WAD;
        _lastCumulated0[poolId][beneficiary] = _cumulated0[poolId];
        if (amount0 > 0) _transfer(key.currency0, beneficiary, amount0);

        uint256 delta1 = _cumulated1[poolId] - _lastCumulated1[poolId][beneficiary];
        uint256 amount1 = delta1 * shares / WAD;
        _lastCumulated1[poolId][beneficiary] = _cumulated1[poolId];
        if (amount1 > 0) _transfer(key.currency1, beneficiary, amount1);
    }

    function _transfer(address token, address to, uint256 amount) internal virtual {
        require(IERC20(token).transfer(to, amount), "MockInitializer: transfer failed");
    }

    function _keyOf(bytes32 poolId) internal view virtual returns (PoolKey memory) {
        return _keyById[poolId];
    }
}

/// @dev Reports a pool but pays nothing, as a pool that has earned nothing does.
contract SilentInitializer is MockDopplerHookInitializer {
    function collectFees(bytes32) external pure override returns (uint128, uint128) {
        return (0, 0);
    }
}

/// @dev Takes tokens out of the collector instead of paying it.
contract DrainingInitializer is MockDopplerHookInitializer {
    uint256 private immutable _amount;

    constructor(uint256 amount_) {
        _amount = amount_;
    }

    function collectFees(bytes32 poolId) external override returns (uint128, uint128) {
        PoolKey memory key = _keyOf(poolId);
        MockBurnable(key.currency1).burn(msg.sender, _amount);
        return (0, 0);
    }
}

/// @dev Calls back into the splitter while it is collecting.
contract ReenteringInitializer is MockDopplerHookInitializer {
    RIKRoyaltySplitter private _splitter;
    address private _asset;

    function arm(RIKRoyaltySplitter splitter_, address asset_) external {
        _splitter = splitter_;
        _asset = asset_;
    }

    function collectFees(bytes32) external override returns (uint128, uint128) {
        _splitter.collectPoolFees(_asset);
        return (0, 0);
    }
}

interface MockBurnable {
    function burn(address from, uint256 amount) external;
}
