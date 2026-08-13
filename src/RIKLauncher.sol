// src/RIKLauncher.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAirlock} from "./IAirlock.sol";
import {IRIKRoyaltySplitter} from "./IRIKRoyaltySplitter.sol";

/**
 * @title RIKLauncher
 * @notice Creates the one token market a GitHub repository is allowed, on behalf of its key holder.
 *
 * @dev This contract adds exactly three things to a direct Doppler Airlock call, and nothing else:
 *
 *      - Authorization. Only the current holder of the repository's {RIK} may launch its market.
 *      - Exclusivity. A repository gets one market, forever. The splitter's reverse mapping from an
 *        asset back to a repository is only meaningful because of that.
 *      - Fee routing. `integrator` is overwritten with the splitter address, so the market's fees
 *        land somewhere the repository's key holder can actually claim them from.
 *
 *      Everything else in {IAirlock-CreateParams} is forwarded verbatim and is the caller's problem.
 *      Validating supply, curves or migration targets here would duplicate the Airlock's own checks
 *      and grow a surface this contract does not need.
 */
contract RIKLauncher is Context, ReentrancyGuardTransient {
    /**
     * @dev Placeholder written into {marketOf} while the Airlock is creating a market.
     *
     * Non-zero, so it satisfies the duplicate check, and not an address the Airlock can ever return
     * as an asset: nothing is deployable at a precompile.
     */
    address private constant _LAUNCHING = address(1);

    IAirlock private immutable _airlock;
    IERC721 private immutable _registry;
    IRIKRoyaltySplitter private immutable _splitter;

    mapping(uint256 githubRepoId => address asset) private _marketOf;

    /**
     * @dev Emitted once per repository, when its market is created.
     *
     * `pool` is reported for convenience; the splitter reaches it through the asset, not through
     * this event.
     */
    event MarketLaunched(uint256 indexed githubRepoId, address indexed asset, address indexed launcher, address pool);

    error InvalidWiring();
    error NotRepositoryKeyHolder(uint256 githubRepoId, address account);
    error MarketAlreadyLaunched(uint256 githubRepoId, address asset);
    error MarketCreationFailed(uint256 githubRepoId);

    /**
     * @dev Wires the launcher to the Airlock it creates markets through, the {RIK} registry it
     *      authorizes against, and the splitter that will receive every market's fees.
     *
     * All three are immutable. The splitter is deployed at a precomputed address so the two
     * contracts can point at each other without either being reconfigurable afterwards, and a zero
     * address is rejected here because there is no way to correct one later.
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
    // The asset is only known once the Airlock has answered, so recording it necessarily happens
    // after an external call. What that write must not be able to do is create a second market for
    // the repository, and the reservation above closes that independently of `nonReentrant`.
    // slither-disable-next-line reentrancy-no-eth
    function launch(uint256 githubRepoId, IAirlock.CreateParams calldata params)
        external
        virtual
        nonReentrant
        returns (address asset)
    {
        address caller = _msgSender();
        // `ownerOf` reverts for a repository that was never registered, which is the check wanted
        // here: no key, no market.
        if (_registry.ownerOf(githubRepoId) != caller) revert NotRepositoryKeyHolder(githubRepoId, caller);

        address existing = _marketOf[githubRepoId];
        if (existing != address(0)) revert MarketAlreadyLaunched(githubRepoId, existing);

        // Claim the slot before handing control to the Airlock. `nonReentrant` already stops a
        // nested launch, but one market per repository is the invariant the splitter's reverse
        // mapping rests on, so it is worth holding independently of any single mechanism: with the
        // slot taken, a reentrant call for this repository fails its own duplicate check. The write
        // is only observable inside this transaction, and it is rolled back if the Airlock reverts.
        _marketOf[githubRepoId] = _LAUNCHING;

        address pool;
        (asset, pool) = _create(params);
        if (asset == address(0) || asset == _LAUNCHING) revert MarketCreationFailed(githubRepoId);

        _marketOf[githubRepoId] = asset;

        emit MarketLaunched(githubRepoId, asset, caller, pool);

        _splitter.registerMarket(asset, githubRepoId);
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
     * Overwriting rather than checking is deliberate. A caller-chosen integrator would send every
     * trading fee to an address the splitter cannot collect from, which fails silently: the market
     * works, and the repository simply never earns anything.
     */
    function _create(IAirlock.CreateParams calldata params) internal virtual returns (address asset, address pool) {
        IAirlock.CreateParams memory forced = params;
        forced.integrator = address(_splitter);

        // Governance, timelock and migration pool are the Airlock's business, not this contract's;
        // the caller reads them from the Airlock's own events.
        // slither-disable-next-line unused-return
        (asset, pool,,,) = _airlock.create(forced);
    }
}
