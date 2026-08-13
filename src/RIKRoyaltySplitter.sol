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
import {IDopplerHookInitializer, PoolKey} from "./IDopplerHookInitializer.sol";
import {IRIKRoyaltySplitter} from "./IRIKRoyaltySplitter.sol";

/**
 * @title RIKRoyaltySplitter
 * @notice Accrues a repository's market fees and pays them to whoever currently holds its {RIK}.
 *
 * @dev # Fee collection
 *
 *      Doppler holds a pool's fees in its initializer and distributes them by share. `collectFees`
 *      harvests the outstanding amount and releases only the caller's portion, to a beneficiary
 *      registered when the pool was created. This contract must therefore make the call itself, and
 *      {RIKLauncher} rejects a launch that has not registered it as a beneficiary.
 *
 *      Uniswap V4 is a singleton, so there is no pool contract. A pool is a {PoolKey} and its id is
 *      the hash of that key; both are read from the initializer using the asset.
 *
 *      # Attribution
 *
 *      Each accrual must determine which repository earned it. That is the asset, registered by the
 *      launcher and mapped to exactly one repository. A caller cannot name the repository being
 *      credited.
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

    /**
     * @dev A launched market. `initializer` is recorded rather than accepted per call, so a caller
     *      cannot point fee collection at a contract of their own choosing.
     */
    struct Market {
        uint256 githubRepoId;
        address initializer;
    }

    mapping(uint256 githubRepoId => mapping(address token => uint256 amount)) private _claimable;
    mapping(address asset => Market market) private _markets;

    event MarketRegistered(uint256 indexed githubRepoId, address indexed asset, address indexed initializer);
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
    error UnknownMarket(address asset);
    error InvalidInitializer();
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
    function registerMarket(address asset, address initializer, uint256 githubRepoId) external virtual onlyLauncher {
        _registerMarket(asset, initializer, githubRepoId);
    }

    /**
     * @dev Collects the outstanding fees of `asset`'s market and credits them to its repository.
     *
     * Permissionless. Calling it for another repository confers no benefit on the caller, and an
     * asset the launcher did not register is rejected.
     *
     * The pool id is read from the initializer rather than supplied by the caller, and the
     * initializer is the one recorded at launch, so collection cannot be aimed elsewhere.
     *
     * Requirements:
     *
     * - `asset` must be a registered market.
     *
     * Emits a {FeesAccrued} event per token that actually arrived.
     */
    // Buckets are necessarily credited after the initializer is called, because the amount credited
    // is the difference that call made. `nonReentrant` makes that ordering safe;
    // `test_CollectPoolFeesRejectsReentrancy` covers it.
    // slither-disable-next-line reentrancy-benign
    function collectPoolFees(address asset) external virtual nonReentrant returns (uint256 amount0, uint256 amount1) {
        Market memory market = _markets[asset];
        if (market.githubRepoId == 0) revert UnknownMarket(asset);

        IDopplerHookInitializer initializer = IDopplerHookInitializer(market.initializer);
        // Only `poolKey` is needed; the remaining members of Doppler's `PoolState` describe the
        // sale rather than the pool's identity.
        // slither-disable-next-line unused-return
        (,,,,, PoolKey memory poolKey,) = initializer.getState(asset);

        address token0 = poolKey.currency0;
        address token1 = poolKey.currency1;

        uint256 before0 = IERC20(token0).balanceOf(address(this));
        uint256 before1 = IERC20(token1).balanceOf(address(this));

        // The return value reports what was harvested into the pool's cumulative accounting, which
        // is not the amount released to this contract, so the balance delta is measured instead.
        // slither-disable-next-line unused-return
        initializer.collectFees(poolIdOf(poolKey));

        // Measured rather than reported, so that a misreporting initializer or a fee-on-transfer
        // token cannot create a claim this contract cannot pay. The subtraction is left checked: a
        // call that removed tokens instead of paying them would otherwise underflow to a very large
        // credit and break solvency for every other repository.
        amount0 = IERC20(token0).balanceOf(address(this)) - before0;
        amount1 = IERC20(token1).balanceOf(address(this)) - before1;

        _accrue(market.githubRepoId, token0, amount0);
        _accrue(market.githubRepoId, token1, amount1);
    }

    /**
     * @dev Returns the Uniswap V4 pool id of `poolKey`.
     *
     * `PoolIdLibrary.toId` hashes the five words of the struct, which is what `abi.encode` produces
     * for a {PoolKey} of five static fields.
     */
    function poolIdOf(PoolKey memory poolKey) public pure virtual returns (bytes32) {
        return keccak256(abi.encode(poolKey));
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
        return _markets[asset].githubRepoId;
    }

    /**
     * @dev Returns the Doppler initializer `asset`'s fees are collected from, or the zero address
     *      when it is not a registered market.
     */
    function initializerOf(address asset) public view virtual returns (address) {
        return _markets[asset].initializer;
    }

    /**
     * @dev Single mutation choke point for the market registry.
     *
     * Emits a {MarketRegistered} event.
     */
    function _registerMarket(address asset, address initializer, uint256 githubRepoId) internal virtual {
        if (githubRepoId == 0) revert InvalidGithubRepoId(githubRepoId);
        // A zero asset would make an unregistered market look registered. A malfunctioning Airlock
        // could return one to the launcher.
        if (asset == address(0)) revert InvalidAsset();
        // A zero initializer would make every collection revert, stranding the repository's fees.
        if (initializer == address(0)) revert InvalidInitializer();

        uint256 existing = _markets[asset].githubRepoId;
        if (existing != 0) revert MarketAlreadyRegistered(asset, existing);

        _markets[asset] = Market({githubRepoId: githubRepoId, initializer: initializer});
        emit MarketRegistered(githubRepoId, asset, initializer);
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
}
