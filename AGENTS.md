# AGENTS.md

## Role

You are editing a Solidity smart-contract repository. Optimize for auditability, semantic consistency, and small override surfaces. Write code in the OpenZeppelin v5 style: private state, explicit invariants, custom errors, narrow interfaces, and tests that prove behavior.

## Scope

These rules apply to Solidity contracts, libraries, interfaces, scripts, and tests. When a deeper directory has its own `AGENTS.md`, follow the closest file for that subtree.

## Project Overview

- Project name: write it as `market` in prose and commands.
- Purpose: EVM contracts that bind a GitHub repository to a wallet address using a GitHub Actions OIDC proof, and let whoever holds that binding launch a token market for the repository and collect its trading fees.
- Repository shape: a single Foundry project at the repository root.
- Stack: Foundry, Solidity `^0.8.24`, OpenZeppelin Contracts and `forge-std` as git submodules under `lib/`.
- Core contract: `RIK`, an ERC-721 "Repository Identity Key" whose token id is the GitHub repository's numeric id.
- Satellite contracts: `RIKLauncher` creates one Doppler market per repository, `RIKRoyaltySplitter` accrues that market's fees to whoever currently holds the repository's RIK.
- JWT verification is not implemented here. It is delegated to the already-deployed `GithubOidcVerifier` from the `identity` repository through the `IJwtVerifier` boundary.
- `foundry.toml` sets `ffi = true` because the tests sign JWT fixtures through a Node generator.
- `foundry.toml` enables the optimizer with `via_ir = true`. Both are load-bearing: the legacy pipeline runs out of stack while building the metadata JSON, so turning via-ir off breaks the build rather than merely changing output.

## Commands

| Purpose | Command |
| --- | --- |
| Initialize submodules | `git submodule update --init --recursive` |
| Format check | `forge fmt --check` |
| Lint | `forge lint --deny warnings` |
| Build with sizes | `forge build --sizes` |
| Tests | `forge test -vvv` |
| Deep fuzz and invariant soak | `FOUNDRY_PROFILE=deep forge test` |
| Static analysis | `slither .` then `forge clean` |
| Gas report | `forge test --gas-report` |
| Regenerate one fixture by hand | `node test/fixtures/load-fixture.mjs test/fixtures/sample-jwt.json` |
| Exercise the operator path | `anvil --silent` in one terminal, then `./smoke-test.sh` |
| Check tooling and deployment | `./bin/market doctor` |
| Deploy the three contracts | `./bin/market deploy --rpc-url …` |
| Inspect a deployment | `./bin/market status` |
| Inspect one repository | `./bin/market rik show <repoId>` |

## Repository Structure

- `src/RIK.sol`: the repository identity ERC-721, its claim checks, and on-chain metadata.
- `src/RIKLauncher.sol`: one-market-per-repository launch path into the Doppler Airlock.
- `src/RIKRoyaltySplitter.sol`: per-repository fee accrual and payout to the current RIK holder.
- `src/IAirlock.sol`: the Doppler Airlock boundary, both creation and integrator fees.
- `src/IMulticurvePool.sol`: the Doppler pool boundary the splitter collects fees through.
- `src/IRIKRoyaltySplitter.sol`: the single call the launcher makes into the splitter, declared apart so the two can be wired to each other without importing each other.
- `src/ClaimMatcher.sol`: the claim matcher `RIK` links against. Same semantics as `JsonClaim`, with the scan unrolled.
- `src/GithubOidcVerifier.sol`, `src/IJwtVerifier.sol`, `src/JsonClaim.sol`: verbatim copies of the deployed `identity` sources. Vendored, not authored here.
- `test/OidcFixture.sol`: shared loader for generated OIDC fixtures.
- `test/MarketFixture.sol`: the whole system, wired the way the deploy script wires it.
- `test/fixtures/load-fixture.mjs`: deterministic JWT generator invoked through `vm.ffi`.
- `test/fixtures/*.json`: one file per scenario; negative cases are data, not code.
- `test/mocks/`: the external protocol surface the launcher and splitter talk to, plus `Adversarial.sol`, which is the hostile version of all of it.
- `test/*.invariant.t.sol`: stateful campaigns. The registry, the splitter's solvency, and the whole system end to end.
- `test/RIKSecurity.t.sol`, `test/MarketSecurity.t.sol`: adversarial unit coverage — hostile receivers, verifiers, tokens and Airlocks.
- `SECURITY.md`: the threat model, what is assumed honest, and the static-analysis triage.
- `slither.config.json`: what static analysis looks at and which findings are accepted.
- `bin/market`: deployment and operations CLI. Ruby 3.2, standard library only, no bundler.
- `tools/market/`: its implementation. Deliberately not under `lib/`, which Foundry owns.
- `smoke-test.sh`: end-to-end exercise of the deploy scripts and the CLI against a local anvil.
- `script/`: Foundry deploy scripts.
- `lib/`: git submodules. Do not edit directly.

## Architecture Boundaries

- `RIK.tokenIdOf(githubRepoId)` is intentionally identity mapping; the token id is the GitHub repository id. GitHub account ids and repository ids share a numeric range, so never mix the two id spaces in one ERC-721, and never treat a `RIK` id as a `UIK` id.
- Registration must verify all four claims together: `aud`, `repository_id`, `repository_owner_id`, and `event_name`. Dropping any one of them reintroduces impersonation.
- `event_name` must equal `workflow_dispatch`. That is the whole proof of control: dispatching a workflow requires write access to the repository. Events such as `issues`, `issue_comment`, `watch`, `fork` and `pull_request` also run in the repository's own context — so they also carry its `repository_id` — while letting any account trigger them. Accepting one of those would let a stranger mint a repository's RIK to their own wallet. This is the one place this implementation deliberately departs from the previously deployed `RIK`.
- Unlike `UIK`, there is no `job_workflow_ref` pin. The registration workflow lives in the user's own repository, so there is no single reviewed file to pin; `workflow_dispatch` is what carries the authorization instead.
- Preserve the issuer string exactly: `https://token.actions.githubusercontent.com`. It is checked inside the vendored verifier, not here.
- `aud` is compared against `Strings.toHexString` of the wallet, so the registration workflow must request a lowercase hex address as the audience.
- `register` is intentionally permissionless. The proof names its own beneficiary through `aud`, so whoever submits it pays the gas without being able to redirect the identity. Never add an access check that ties the mint to `msg.sender`.
- `src/GithubOidcVerifier.sol`, `src/IJwtVerifier.sol` and `src/JsonClaim.sol` are byte-for-byte copies of the `identity` repository's deployed sources. They are vendored so the suite can run a local verifier and so `RIK` compiles against the same library. Do not edit them here; fix them upstream and re-copy. `market` points `RIK` at the live verifier instance rather than deploying its own.
- `ClaimMatcher` and `JsonClaim` are the same matcher, and both are sound only because a JSON encoder escapes `"` inside string values. Any change to the matching strategy must preserve that, and must keep the injection regression tests passing.
- `RIK` links against `ClaimMatcher`, never `JsonClaim`. Both are `internal` libraries, so exactly one is inlined into `RIK`'s bytecode: choosing the unrolled one does not widen the deployed surface, it only decides which implementation ships. `JsonClaim` stays because the vendored verifier beside it must keep compiling to the deployed bytecode.
- `ClaimMatcher.indexOf` and `JsonClaim.indexOf` are inline assembly comparing a masked 32-byte word per position. They deliberately read up to 31 bytes past the end of both arrays and mask them off, and never write; do not add the `memory-safe` annotation on the strength of that. `ClaimMatcher` additionally tests four candidate positions per loop iteration, which makes the stride boundary and the one-to-three position tail the fragile part. Verify any edit differentially against both `JsonClaim` and the naive byte-at-a-time search before trusting it.
- `RIK._audienceOf` is a hand-written hex encoder standing in for `Strings.toHexString(uint160(wallet), 20)`, which costs roughly twice as much on the hot path. Unlike the matchers it allocates properly and is genuinely `memory-safe`. It is worth keeping only while it stays cheaper than `Strings`; `test/GasRegression.t.sol` asserts exactly that, and if it ever fails the right fix is to delete the encoder, not to maintain it.
- Roughly two thirds of a registration is RSA verification inside the vendored verifier. That is not this repository's to optimize, and forking it to try would trade a live, key-holding contract for a few percent.
- `foundry.toml` pins `evm_version`. Left unset it tracks the newest fork the toolchain knows about, which is ahead of what Base has activated and would emit opcodes that do not exist there.
- `foundry.toml` also pins `solc`. A deployment has to be reproducible from source years later, and an unpinned compiler quietly moves with the toolchain.
- Every static-analysis finding is either fixed or accepted in place with a `slither-disable-next-line` and a reason beside the code, mirrored in `SECURITY.md`. `slither .` must stay at zero findings, so a new one is a decision somebody has to make rather than noise to scroll past.
- Running slither leaves the Foundry cache without test artifacts, because it builds with `--skip ./test/**`. Run `forge clean` afterwards, or keep the two in separate CI jobs as they are now.
- The verifier owner key is the highest-value secret in the system. It can add an arbitrary signing key, and therefore mint trust in a forged JWT for any repository. It lives in the `identity` repository and is not `market`'s to hold.
- `RIK` is transferable, and that is load-bearing rather than incidental: royalties follow the current holder, so the key has to be tradeable.
- `RIK` mints once per repository, forever. There is no rebinding path and there must never be one, because re-registration would let a repository owner yank the key back from someone who bought it. Wallet rotation is a transfer.
- `RIK` mints with `_safeMint`, not `_mint`. The key is transferable and carries a market's royalties, so minting one into a contract that cannot move an ERC-721 would strand a repository permanently, while a reverted registration costs nothing but a re-run. The receiver hook this introduces is the only place a registration can be re-entered, and it runs after every state change, so a nested registration of the same repository hits {AlreadyRegistered}. Registering a *different* repository from inside the hook is legitimate and must keep working, which is why there is deliberately no reentrancy guard on `register`.
- Every immutable wiring address is rejected if zero, in all three contracts. None of them can be reconfigured, so a typo is otherwise only discovered when the first registration, launch or payout fails — and a zero launcher on the splitter fails silently rather than loudly.
- `RIKLauncher.launch` reserves a repository's market slot with a placeholder *before* calling the Airlock. `nonReentrant` already prevents a nested launch; the reservation makes one-market-per-repository hold even if that guard were ever removed, because a reentrant call fails its own duplicate check.
- Payout recipients are rejected if zero. Not every ERC20 reverts on a transfer to the zero address, and a bucket empties exactly once, so an unchecked recipient is a one-shot way to burn a repository's earnings.
- `RIK` metadata interpolates numeric ids only, never a repository name or owner login. That is what keeps the JSON injection-free without a charset validator; adding any attacker-controlled string to it reintroduces the problem `UIK._requireRenderableLogin` exists to solve.
- Metadata is served on-chain so that what a client displays rests on the same guarantees as the binding. Do not introduce an HTTP `_baseURI()`. It is immutable once minted, which is why this contract does not implement ERC-4906.
- `RIKLauncher` overwrites `CreateParams.integrator` with the splitter address. A caller-chosen integrator would send every trading fee somewhere the splitter cannot see, silently breaking payouts for that repository. Do not relax this to a check the caller can satisfy with their own address.
- One market per repository, enforced in the launcher. The splitter's `repoOf` reverse mapping assumes it.
- The splitter derives a repository id from the pool's tokens, never from a caller argument. An accrual function taking a caller-supplied repository id would let anyone route another repository's fees into their own bucket; that is why the aggregate `pull(repoId, token)` of the previously deployed splitter is absent here.
- A pool with a registered asset on both sides is ambiguous, so it is rejected rather than resolved arbitrarily.
- Accrual is measured as a balance delta across the collect call. Never credit an amount reported by the pool: a lying or fee-on-transfer token would otherwise create claims the contract cannot pay.
- `collectIntegratorFees` is owner-gated and pays out of the Airlock directly to the recipient. It must never move tokens the splitter already holds, because those are repository buckets. The invariant is that the sum of `claimable` never exceeds the splitter's balance of that token.
- Integrator fees are aggregated per integrator by the Airlock, so they cannot be attributed to a repository on-chain. Do not add an accrual path that pretends otherwise.
- `bin/market` depends on nothing but Ruby's standard library, forge, cast and gh. Do not add a Gemfile; a contracts repository should not require a second package manager to deploy.
- The helper never writes a private key to `.market.yml`. Keys come from the environment or a no-echo prompt on each run, which is what keeps that file safe to leave in a working tree.
- `Shell` always passes an argv array, never a command string, so a configured value can never become shell syntax. Keep it that way.
- The splitter owner is a required deploy argument rather than a default. It is the one account that can move value the contract did not earn for a repository, so which key holds it should be a decision printed in the plan, not a side effect of whoever signed.
- `smoke-test.sh` refuses to run against anything but chain 31337. The launcher and splitter can only be wired through a predicted CREATE address, and a wrong prediction produces contracts that deploy fine and then send every fee to an address with no code; `forge test` cannot see that, so it is checked on a real chain instead.
- There is no key-sync secret in this repository, and there should not be. The verifier and the owner key that can add signing keys to it live in `identity`. `market` holds only a registrar key, which pays gas and nothing else.

## Solidity code rules

Use named imports only. Do not use wildcard imports. Prefix interfaces with `I`. Mark contracts `abstract` when they are not deployable as-is.

```solidity
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVault {
    function totalAssets() external view returns (uint256);
}

abstract contract BaseVault is IVault {
    // Not deployable without a concrete asset/accounting implementation.
}
```

Keep every state variable `private` and underscore-prefixed. Expose reads through `public view virtual` getters. Do not make storage public just to get an auto-generated getter. Changes to state must go through functions that enforce events and invariants.

```solidity
mapping(address account => uint256 balance) private _balances;
uint256 private _totalSupply;

function balanceOf(address account) public view virtual returns (uint256) {
    return _balances[account];
}

function totalSupply() public view virtual returns (uint256) {
    return _totalSupply;
}
```

Use one mutation choke point per state concept. Public/external functions and convenience internals validate inputs, resolve `_msgSender()`, then delegate to one `internal virtual` function that performs the actual state change. Thin aliases are not virtual; override the underlying choke point instead.

```solidity
function transfer(address to, uint256 value) public virtual returns (bool) {
    address owner = _msgSender();
    _transfer(owner, to, value);
    return true;
}

function _transfer(address from, address to, uint256 value) internal {
    if (from == address(0)) revert ERC20InvalidSender(address(0));
    if (to == address(0)) revert ERC20InvalidReceiver(address(0));
    _update(from, to, value);
}

function _update(address from, address to, uint256 value) internal virtual {
    // All balance and supply mutation for this concept happens here.
}
```

In reusable contracts, do not read `msg.sender` or `msg.data` directly. Inherit/use `Context` and call `_msgSender()` and `_msgData()` so meta-transaction variants can override semantics.

```solidity
function deposit(uint256 assets) external virtual {
    address caller = _msgSender();
    _deposit(caller, caller, assets);
}
```

Use custom errors, not revert strings, for domain failures. Prefer ERC-6093 names for token errors such as `ERC20InvalidSender`, `ERC20InsufficientBalance`, and `ERC20InvalidSpender`. Revert on failure; do not return `false` unless an external standard forces the signature.

```solidity
error VaultZeroAssets();
error VaultUnauthorizedAccount(address account);

function _deposit(address caller, address receiver, uint256 assets) internal virtual {
    if (assets == 0) revert VaultZeroAssets();
    if (receiver == address(0)) revert ERC721InvalidReceiver(address(0));

    // Do not write: require(assets != 0, "zero assets");
}
```

Use `address(0)` deliberately. In token update choke points it is the sentinel for mint and burn, and standard `Transfer` events must encode mint/burn through zero-address endpoints. Boundary wrappers such as `_mint` and `_burn` still validate invalid zero-address usage.

```solidity
function _mint(address to, uint256 value) internal {
    if (to == address(0)) revert ERC20InvalidReceiver(address(0));
    _update(address(0), to, value);
}

function _burn(address from, uint256 value) internal {
    if (from == address(0)) revert ERC20InvalidSender(address(0));
    _update(from, address(0), value);
}
```

Emit events immediately after the state mutation they describe. New events should be past-tense, e.g. `OwnershipTransferred`, `TokensBurned`, `RoleGranted`. Index address, account, and role fields that off-chain systems filter on; leave amounts unindexed unless there is a clear indexing reason.

```solidity
event DepositCompleted(address indexed caller, address indexed receiver, uint256 assets);

function _deposit(address caller, address receiver, uint256 assets) internal virtual {
    _totalAssets += assets;
    emit DepositCompleted(caller, receiver, assets);
}
```

Cache storage reads when the value is used more than once. Every `unchecked` block must be locally justified by a preceding check or an adjacent comment proving overflow or underflow impossible.

```solidity
uint256 fromBalance = _balances[from];
if (fromBalance < value) {
    revert ERC20InsufficientBalance(from, fromBalance, value);
}
unchecked {
    // Safe because value <= fromBalance was checked above.
    _balances[from] = fromBalance - value;
}
```

Treat `type(uint256).max` allowance as infinite and do not decrement it. Use the overloaded-internal pattern for event escape hatches: the simple overload is non-virtual and delegates to the full virtual overload with explicit behavior flags such as `emitEvent`.

```solidity
function _approve(address owner, address spender, uint256 value) internal {
    _approve(owner, spender, value, true);
}

function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
    _allowances[owner][spender] = value;
    if (emitEvent) emit Approval(owner, spender, value);
}

function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
    uint256 currentAllowance = allowance(owner, spender);
    if (currentAllowance < type(uint256).max) {
        if (currentAllowance < value) {
            revert ERC20InsufficientAllowance(spender, currentAllowance, value);
        }
        unchecked {
            // Safe because currentAllowance >= value was checked above.
            _approve(owner, spender, currentAllowance - value, false);
        }
    }
}
```

Use `SafeERC20` for every external ERC20 interaction. Do not call `transfer`, `transferFrom`, or `approve` raw on token contracts. Use `safeTransfer`, `safeTransferFrom`, `forceApprove`, `safeIncreaseAllowance`, and `safeDecreaseAllowance` as appropriate. Use `Address` helpers for low-level value transfers and function calls.

```solidity
using SafeERC20 for IERC20;

function pull(IERC20 token, address from, uint256 amount) external {
    token.safeTransferFrom(from, address(this), amount);
}

function sweepNative(address payable to, uint256 amount) external onlyOwner {
    Address.sendValue(to, amount);
}
```

For contracts with authority over funds, ownership, upgrades, or roles, prefer two-step ownership transfer or explicit `AccessControl` roles. Do not introduce single-step owner handoff for production authority paths.

```solidity
contract ManagedVault is Ownable2Step, AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    function harvest() external onlyRole(KEEPER_ROLE) {
        _harvest();
    }
}
```

For upgradeable contracts, use ERC-7201-style namespaced storage structs. Do not add top-level state variables to proxy implementations. Use `initializer`/`reinitializer`, `__Module_init` and `__Module_init_unchained`, and disable initializers on the implementation contract.

```solidity
/// @custom:storage-location erc7201:myapp.storage.Vault
struct VaultStorage {
    uint256 _totalAssets;
    mapping(address account => uint256 shares) _shares;
}

bytes32 private constant VaultStorageLocation =
    0x0f4c8d1c0d5bb98f9f2f2a5c6d97d65b1b18143a6b7397d2f5f7b6f0e6f9b500;

function _getVaultStorage() private pure returns (VaultStorage storage $) {
    assembly {
        $.slot := VaultStorageLocation
    }
}
```

## NatSpec

Every public, external, and `internal virtual` function must explain behavior. Use `@inheritdoc` when implementing an interface without semantic changes. Add `Requirements:` and `Emits:` blocks when a function has preconditions or events. If an alias should not be overridden, say which function should be overridden instead.

```solidity
/**
 * @dev Moves `assets` from `caller` into the vault and credits `receiver`.
 *
 * Requirements:
 *
 * - `assets` must be non-zero.
 * - `receiver` must not be the zero address.
 *
 * Emits a {DepositCompleted} event.
 */
function _deposit(address caller, address receiver, uint256 assets) internal virtual;

/// @inheritdoc IERC20
function balanceOf(address account) public view virtual returns (uint256);
```

## Tests

Add or update tests with every behavior change. Cover normal paths, reverts, event emission, and edge cases. Use fuzz tests for math-heavy code and invariant tests for state machines. Every bug fix must include a regression test that fails without the fix. Do not weaken tests to make a patch pass.

```solidity
function testFuzz_DepositCreditsReceiver(uint256 assets) public {
    assets = bound(assets, 1, type(uint128).max);
    vault.deposit(assets, receiver);
    assertEq(vault.balanceOf(receiver), assets);
}

function invariant_TotalSupplyEqualsAccountedBalances() public view {
    assertEq(vault.totalSupply(), handler.accountedBalances());
}
```

Keep tests deterministic and local. Do not reach GitHub, an RPC endpoint, or any other network from a test. The only external process a test may use is `test/fixtures/load-fixture.mjs` through `vm.ffi`.

Every claim check in `RIK` must have a negative test proving that removing it would allow impersonation, and the injection regressions must stay green.

Four stateful invariants are load-bearing and must keep passing. Do not weaken a handler to make one green; a handler that stops reaching a path silently makes its invariant vacuous, which is why every campaign asserts its own call counters in `afterInvariant`.

- **Conservation.** For every token, what the splitter still owes plus what it has already paid equals what it was ever credited. This is the difference between an accounting bug and stolen royalties.
- **Solvency.** The sum of every `claimable` bucket never exceeds the contract's balance of that token.
- **Exclusivity and attribution.** A repository's market address never changes, and it always maps back to that repository.
- **Registration is once, forever.** A registered repository always has a holder, its record never changes, and no proof ever mints a key it does not attest.

New assembly, new external calls, and new arithmetic on value all need fuzz coverage rather than a single example. Prefer a differential test against an obviously-correct reference when replacing something that already works; `ClaimMatcher` and `RIK._audienceOf` both exist only because they are faster, and both are held to the implementations they replaced.

Scale a fuzzer with an explicit `forge-config: deep.fuzz.runs` annotation when it is cheap enough to soak hard. Tests driven through `vm.ffi` shell out to Node on every run, so they stay bounded even under the deep profile.

## Boundaries

- Never edit, print, copy, infer, or commit real secrets: `.env`, `.env.*`, `PRIVATE_KEY`, GitHub tokens, RPC credentials, or wallet data. The RSA key in `test/fixtures/load-fixture.mjs` is a committed test-only key and is not a secret.
- Do not deploy, broadcast transactions, or call live RPCs unless the user explicitly asks.
- Do not change the GitHub OIDC issuer, workflow permissions, or deployed contract addresses without explicit approval.
- Do not edit generated or dependency directories: `cache/`, `out/`, `broadcast/`, or `lib/`.
- Never replace Foundry with another contract toolchain without explicit user approval.

## Do not

Do not use wildcard imports, public state variables, raw `msg.sender` in reusable code, `require(..., "string")` for domain errors, raw ERC20 calls, unexplained `unchecked`, pre-mutation events, single-step ownership transfer for production authority, top-level storage in upgradeable implementations, or multiple override points for the same state transition.
