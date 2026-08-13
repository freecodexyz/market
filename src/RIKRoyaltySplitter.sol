// src/RIKRoyaltySplitter.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAirlock} from "./IAirlock.sol";
import {IMulticurvePool} from "./IMulticurvePool.sol";
import {IRIKRoyaltySplitter} from "./IRIKRoyaltySplitter.sol";

/**
 * @title RIKRoyaltySplitter
 * @notice Accrues a repository's market fees and pays them to whoever currently holds its {RIK}.
 *
 * @dev # Attribution
 *
 *      Each accrual must determine which repository earned it. That is derived from the pool: one
 *      side of the pair is a market asset registered by the launcher, and that asset maps to exactly
 *      one repository. A caller cannot name the repository being credited.
 *
 *      The previously deployed splitter exposed `pull(repoId, token)`, which took the repository id
 *      as an argument. Because the Airlock aggregates integrator fees per integrator rather than per
 *      market, that allowed any caller to route every repository's fees into their own bucket. It is
 *      deliberately absent here and must not be reintroduced.
 *
 *      # Solvency
 *
 *      Accrual is measured as the change in this contract's balance across the collect call, so a
 *      bucket can only be created by tokens that arrived. The invariant is that the sum of all
 *      buckets in a token never exceeds this contract's balance of that token, which keeps {claim}
 *      payable and prevents one repository being paid from another's earnings.
 *
 *      # Integrator fees
 *
 *      Fees the Airlock owes this contract as an integrator are aggregated across all markets and
 *      cannot be attributed to a repository on-chain. {collectIntegratorFees} is therefore
 *      owner-gated and pays from the Airlock directly to a recipient. It does not touch this
 *      contract's balance and so cannot reach a repository's bucket.
 */
contract RIKRoyaltySplitter is IRIKRoyaltySplitter, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC721 private immutable _registry;
    IAirlock private immutable _airlock;
    address private immutable _launcher;

    mapping(uint256 githubRepoId => mapping(address token => uint256 amount)) private _claimable;
    mapping(address asset => uint256 githubRepoId) private _repoIdOf;

    event MarketRegistered(uint256 indexed githubRepoId, address indexed asset);
    event FeesAccrued(uint256 indexed githubRepoId, address indexed token, uint256 amount);
    event FeesClaimed(uint256 indexed githubRepoId, address indexed token, address indexed to, uint256 amount);
    event IntegratorFeesCollected(address indexed token, address indexed to, uint256 amount);

    error InvalidWiring();
    error InvalidRecipient();
    error InvalidAsset();
    error CallerIsNotLauncher(address account);
    error NotRepositoryKeyHolder(uint256 githubRepoId, address account);
    error NothingToClaim(uint256 githubRepoId, address token);
    error NoIntegratorFees(address token);
    error UnknownPool(address pool);
    error AmbiguousPool(address pool);
    error MarketAlreadyRegistered(address asset, uint256 githubRepoId);
    error InvalidGithubRepoId(uint256 githubRepoId);

    /**
     * @dev Restricts a call to the launcher this splitter was deployed against.
     */
    modifier onlyLauncher() {
        address caller = _msgSender();
        if (caller != _launcher) revert CallerIsNotLauncher(caller);
        _;
    }

    /**
     * @dev Wires the splitter to the {RIK} registry it pays out against, the Airlock it collects
     *      integrator fees from, and the launcher allowed to register markets. All three are
     *      immutable; `initialOwner` holds no authority over repository buckets.
     *
     * Requirements:
     *
     * - None of `registry_`, `airlock_` or `launcher_` may be the zero address. A zero launcher
     *   fails silently: no market could be registered, so every pool would resolve as unknown and
     *   no repository would be paid.
     * - `initialOwner` must not be the zero address, enforced by {Ownable}.
     */
    constructor(IERC721 registry_, IAirlock airlock_, address launcher_, address initialOwner) Ownable(initialOwner) {
        if (address(registry_) == address(0) || address(airlock_) == address(0) || launcher_ == address(0)) {
            revert InvalidWiring();
        }

        _registry = registry_;
        _airlock = airlock_;
        _launcher = launcher_;
    }

    /**
     * @inheritdoc IRIKRoyaltySplitter
     *
     * @dev Requirements:
     *
     * - The caller must be the launcher.
     * - `githubRepoId` must be non-zero, because zero is the unregistered sentinel.
     * - `asset` must not already belong to a repository.
     *
     * Emits a {MarketRegistered} event.
     */
    function registerMarket(address asset, uint256 githubRepoId) external virtual onlyLauncher {
        _registerMarket(asset, githubRepoId);
    }

    /**
     * @dev Collects `pool`'s accrued fees and credits them to the repository that owns it.
     *
     * Permissionless. Calling it for another repository confers no benefit on the caller.
     *
     * Requirements:
     *
     * - Exactly one side of `pool` must be a registered market asset.
     *
     * Emits a {FeesAccrued} event per token that actually arrived.
     */
    // Buckets are necessarily credited after the pool is called, because the amount credited is the
    // difference that call made. `nonReentrant` makes that ordering safe;
    // `test_CollectPoolFeesRejectsReentrancy` covers it.
    // slither-disable-next-line reentrancy-benign
    function collectPoolFees(IMulticurvePool pool)
        external
        virtual
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        address token0 = pool.token0();
        address token1 = pool.token1();
        uint256 githubRepoId = _repoIdOfPair(address(pool), token0, token1);

        uint256 before0 = IERC20(token0).balanceOf(address(this));
        uint256 before1 = IERC20(token1).balanceOf(address(this));

        pool.collectFees();

        // Measured rather than taken from the pool's return value, so that a misreporting pool or a
        // fee-on-transfer token cannot create a claim this contract cannot pay. The subtraction is
        // left checked: a pool that removed tokens instead of paying them would otherwise underflow
        // to a very large credit and break solvency for every other repository.
        amount0 = IERC20(token0).balanceOf(address(this)) - before0;
        amount1 = IERC20(token1).balanceOf(address(this)) - before1;

        _accrue(githubRepoId, token0, amount0);
        _accrue(githubRepoId, token1, amount1);
    }

    /**
     * @dev Pays `githubRepoId`'s entire `token` bucket out to `to`.
     *
     * Requirements:
     *
     * - The caller must currently hold the repository's key.
     * - `to` must not be the zero address.
     * - The bucket must be non-empty.
     *
     * Emits a {FeesClaimed} event.
     */
    function claim(uint256 githubRepoId, address token, address to)
        external
        virtual
        nonReentrant
        returns (uint256 amount)
    {
        // Not every ERC20 reverts on a transfer to the zero address, and a bucket can only be
        // emptied once, so an unchecked recipient would permanently destroy a repository's earnings.
        // A separate recipient is otherwise intentional: it lets a holder route around a token that
        // has blacklisted their own address.
        if (to == address(0)) revert InvalidRecipient();

        address caller = _msgSender();
        if (_registry.ownerOf(githubRepoId) != caller) revert NotRepositoryKeyHolder(githubRepoId, caller);

        amount = _claimable[githubRepoId][token];
        if (amount == 0) revert NothingToClaim(githubRepoId, token);
        _claimable[githubRepoId][token] = 0;

        emit FeesClaimed(githubRepoId, token, to, amount);

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @dev Pays the Airlock's accrued integrator fees in `token` out to `to`.
     *
     * These belong to the protocol rather than to any one repository, because the Airlock aggregates
     * them per integrator. The transfer happens inside the Airlock, from its balance to `to`, so
     * this call can never reduce a repository's bucket.
     *
     * Requirements:
     *
     * - The caller must be the contract owner.
     * - `to` must not be the zero address.
     * - The Airlock must owe a non-zero amount in `token`.
     *
     * Emits an {IntegratorFeesCollected} event.
     */
    function collectIntegratorFees(address token, address to)
        external
        virtual
        onlyOwner
        nonReentrant
        returns (uint256 amount)
    {
        if (to == address(0)) revert InvalidRecipient();

        amount = _airlock.getIntegratorFees(address(this), token);
        if (amount == 0) revert NoIntegratorFees(token);

        emit IntegratorFeesCollected(token, to, amount);

        _airlock.collectIntegratorFees(to, token, amount);
    }

    /**
     * @dev Returns the {RIK} registry payouts are authorized against.
     */
    function registry() public view virtual returns (IERC721) {
        return _registry;
    }

    /**
     * @dev Returns the Doppler Airlock integrator fees are collected from.
     */
    function airlock() public view virtual returns (IAirlock) {
        return _airlock;
    }

    /**
     * @dev Returns the launcher allowed to register markets.
     */
    function launcher() public view virtual returns (address) {
        return _launcher;
    }

    /**
     * @dev Returns what `githubRepoId` can currently withdraw in `token`.
     */
    function claimable(uint256 githubRepoId, address token) public view virtual returns (uint256) {
        return _claimable[githubRepoId][token];
    }

    /**
     * @dev Returns the repository `asset` belongs to, or zero when it is not a registered market.
     */
    function repoIdOf(address asset) public view virtual returns (uint256) {
        return _repoIdOf[asset];
    }

    /**
     * @dev Single mutation choke point for the asset-to-repository mapping.
     *
     * Emits a {MarketRegistered} event.
     */
    function _registerMarket(address asset, uint256 githubRepoId) internal virtual {
        if (githubRepoId == 0) revert InvalidGithubRepoId(githubRepoId);
        // A zero asset would make any pool with the zero address on one side resolve to a
        // repository. A malfunctioning Airlock could return one to the launcher.
        if (asset == address(0)) revert InvalidAsset();

        uint256 existing = _repoIdOf[asset];
        if (existing != 0) revert MarketAlreadyRegistered(asset, existing);

        _repoIdOf[asset] = githubRepoId;
        emit MarketRegistered(githubRepoId, asset);
    }

    /**
     * @dev Single mutation choke point for repository buckets. A zero `amount` is a no-op, so a
     *      pool that owed nothing in one of its tokens does not emit a meaningless event.
     *
     * Emits a {FeesAccrued} event.
     */
    function _accrue(uint256 githubRepoId, address token, uint256 amount) internal virtual {
        // The comparison is against a measured balance delta rather than a balance, and only
        // determines whether to skip a no-op write and its event.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return;

        _claimable[githubRepoId][token] += amount;
        emit FeesAccrued(githubRepoId, token, amount);
    }

    /**
     * @dev Resolves the repository a pool belongs to from its pair.
     *
     * Exactly one side must be a registered market asset. Two registered sides cannot be resolved,
     * and selecting one would credit the wrong repository, so it reverts. This also covers a pool
     * reporting the same token on both sides, which would otherwise credit a single balance delta
     * to two buckets.
     */
    function _repoIdOfPair(address pool, address token0, address token1) internal view virtual returns (uint256) {
        uint256 repoId0 = _repoIdOf[token0];
        uint256 repoId1 = _repoIdOf[token1];

        if (repoId0 != 0 && repoId1 != 0) revert AmbiguousPool(pool);
        if (repoId0 == 0 && repoId1 == 0) revert UnknownPool(pool);

        return repoId0 == 0 ? repoId1 : repoId0;
    }
}
