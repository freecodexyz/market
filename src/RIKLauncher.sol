// src/RIKLauncher.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAirlock} from "./IAirlock.sol";
import {IDopplerHookInitializer, PoolKey} from "./IDopplerHookInitializer.sol";
import {IRIKRoyaltySplitter} from "./IRIKRoyaltySplitter.sol";

/**
 * @title RIKLauncher
 * @notice Creates the one token market a GitHub repository is allowed, on behalf of its key holder.
 *
 * @dev This contract adds three things to a direct Doppler Airlock call:
 *
 *      - Authorization: only the current holder of the repository's {RIK} may launch its market.
 *      - Exclusivity: a repository gets one market. The splitter's mapping from an asset back to a
 *        repository depends on this.
 *      - Fee routing: `integrator` is overwritten with the splitter address so the market's fees
 *        are collectable by the repository's key holder.
 *
 *      Every other field of {IAirlock-CreateParams} is forwarded unchanged. Validating supply,
 *      curves or migration targets here would duplicate the Airlock's own checks.
 */
contract RIKLauncher is Context, ReentrancyGuardTransient {
    /**
     * @dev Placeholder written into {marketOf} while the Airlock is creating a market.
     *
     * Non-zero so that it satisfies the duplicate check, and not an address the Airlock can return
     * as an asset, since no contract can be deployed at a precompile address.
     */
    address private constant _LAUNCHING = address(1);

    IAirlock private immutable _airlock;
    IERC721 private immutable _registry;
    IRIKRoyaltySplitter private immutable _splitter;

    mapping(uint256 githubRepoId => address asset) private _marketOf;

    /**
     * @dev Emitted once per repository, when its market is created.
     *
     * `pool` is whatever the Airlock returned from `poolInitializer.initialize`. Uniswap V4 pools
     * have no address, so `DopplerHookInitializer` returns the asset there and the two are equal for
     * a V4 launch. The pool is identified by the key held in the initializer, not by this field.
     */
    event MarketLaunched(uint256 indexed githubRepoId, address indexed asset, address indexed launcher, address pool);

    error InvalidWiring();
    error NotRepositoryKeyHolder(uint256 githubRepoId, address account);
    error MarketAlreadyLaunched(uint256 githubRepoId, address asset);
    error MarketCreationFailed(uint256 githubRepoId);
    error NativeNumeraireUnsupported();
    error SplitterNotBeneficiary(uint256 githubRepoId, address initializer);

    /**
     * @dev Wires the launcher to the Airlock it creates markets through, the {RIK} registry it
     *      authorizes against, and the splitter that will receive every market's fees.
     *
     * All three are immutable. The splitter is deployed at a precomputed address so the two
     * contracts can reference each other while remaining non-reconfigurable. A zero address is
     * rejected here because it cannot be corrected afterwards.
     *
     * Requirements:
     *
     * - None of `airlock_`, `registry_` or `splitter_` may be the zero address.
     */
    constructor(IAirlock airlock_, IERC721 registry_, IRIKRoyaltySplitter splitter_) {
        if (address(airlock_) == address(0) || address(registry_) == address(0) || address(splitter_) == address(0)) {
            revert InvalidWiring();
        }

        _airlock = airlock_;
        _registry = registry_;
        _splitter = splitter_;
    }

    /**
     * @dev Creates the market for `githubRepoId` and registers it with the splitter.
     *
     * Requirements:
     *
     * - `githubRepoId` must be registered in {registry}, and the caller must currently hold its key.
     * - `githubRepoId` must not already have a market.
     * - The Airlock must return a non-zero asset.
     *
     * Emits a {MarketLaunched} event.
     */
    // The asset is only known after the Airlock returns, so recording it necessarily happens after
    // an external call. The reservation below prevents that write from creating a second market for
    // the repository, independently of `nonReentrant`.
    // slither-disable-next-line reentrancy-no-eth
    function launch(uint256 githubRepoId, IAirlock.CreateParams calldata params)
        external
        virtual
        nonReentrant
        returns (address asset)
    {
        address caller = _msgSender();
        // `ownerOf` reverts for an unregistered repository, which is the required behaviour.
        if (_registry.ownerOf(githubRepoId) != caller) revert NotRepositoryKeyHolder(githubRepoId, caller);

        address existing = _marketOf[githubRepoId];
        if (existing != address(0)) revert MarketAlreadyLaunched(githubRepoId, existing);

        // Fees are released as ERC20 transfers and repository buckets are denominated in ERC20
        // balances. A native numeraire would be released as value the splitter cannot receive.
        if (params.numeraire == address(0)) revert NativeNumeraireUnsupported();

        // Reserve the slot before handing control to the Airlock. `nonReentrant` already prevents a
        // nested launch; this makes one-market-per-repository hold independently of that guard,
        // because a reentrant call for this repository fails its own duplicate check. The write is
        // observable only within this transaction and is reverted if the Airlock reverts.
        _marketOf[githubRepoId] = _LAUNCHING;

        address pool;
        (asset, pool) = _create(params);
        if (asset == address(0) || asset == _LAUNCHING) revert MarketCreationFailed(githubRepoId);

        _marketOf[githubRepoId] = asset;

        // Doppler fixes a pool's beneficiaries at creation and releases fees only to an address
        // holding shares. A market created without the splitter registered cannot be corrected
        // afterwards and would accrue nothing for the repository, so it is rejected here.
        address initializer = params.poolInitializer;
        if (!_splitterIsBeneficiary(initializer, asset)) revert SplitterNotBeneficiary(githubRepoId, initializer);

        emit MarketLaunched(githubRepoId, asset, caller, pool);

        _splitter.registerMarket(asset, initializer, githubRepoId);
    }

    /**
     * @dev Returns whether the splitter holds a non-zero share of `asset`'s pool.
     *
     * The pool id is derived from the key the initializer recorded for the asset, so this reads
     * Doppler's own state rather than trusting anything the caller supplied.
     */
    function _splitterIsBeneficiary(address initializer, address asset) internal view virtual returns (bool) {
        // Only `poolKey` is needed; the remaining members of Doppler's `PoolState` describe the
        // sale rather than the pool's identity.
        // slither-disable-next-line unused-return
        (,,,,, PoolKey memory poolKey,) = IDopplerHookInitializer(initializer).getState(asset);
        bytes32 poolId = keccak256(abi.encode(poolKey));

        return IDopplerHookInitializer(initializer).getShares(poolId, address(_splitter)) != 0;
    }

    /**
     * @dev Returns the Doppler Airlock markets are created through.
     */
    function airlock() public view virtual returns (IAirlock) {
        return _airlock;
    }

    /**
     * @dev Returns the {RIK} registry launches are authorized against.
     */
    function registry() public view virtual returns (IERC721) {
        return _registry;
    }

    /**
     * @dev Returns the splitter every launched market's fees are routed to.
     */
    function splitter() public view virtual returns (IRIKRoyaltySplitter) {
        return _splitter;
    }

    /**
     * @dev Returns the market asset of `githubRepoId`, or the zero address when it has none.
     */
    function marketOf(uint256 githubRepoId) public view virtual returns (address) {
        return _marketOf[githubRepoId];
    }

    /**
     * @dev Forwards `params` to the Airlock with the integrator forced to the splitter.
     *
     * Overwritten rather than validated. A caller-chosen integrator would route trading fees to an
     * address the splitter cannot collect from, which fails silently: the market functions and the
     * repository earns nothing.
     */
    function _create(IAirlock.CreateParams calldata params) internal virtual returns (address asset, address pool) {
        IAirlock.CreateParams memory forced = params;
        forced.integrator = address(_splitter);

        // Governance, timelock and migration pool are not used here; callers read them from the
        // Airlock's own events.
        // slither-disable-next-line unused-return
        (asset, pool,,,) = _airlock.create(forced);
    }
}
