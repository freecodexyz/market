# Security Policy

## Reporting a vulnerability

**Email <paoloanzn@gmail.com>. Do not open an issue, a pull request, or a discussion.**

Never disclose a vulnerability publicly before it has been fixed. That includes this repository's issue tracker, pull requests, forks, commit messages, and anywhere else public — social media, chat groups, write-ups, and conference talks included.

`RIK` binds GitHub repositories to wallets, and those keys carry a market's royalties. Anything that allows a repository's key to be minted to an address its owner does not control, or allows one repository to be paid from another's earnings, is directly exploitable once known.

You will get a reply confirming receipt. Please allow time for a fix before considering any further disclosure, and coordinate the timing in that thread.

## What to include

Whatever you have. The more of this the better:

- the contract and file, and the commit or deployed address it applies to
- what an attacker gains, and what they need in order to do it
- the smallest reproduction you can manage, ideally a failing Foundry test
- the chain and transaction hash, if you observed it against a live deployment

## Threat model

What the contracts are built to withstand, and what they are not.

### Assumed honest

- **The GitHub Actions OIDC issuer.** Tokens are taken to be unforgeable and their claims to be set by GitHub, not by the workflow. `repository_id` and `event_name` in particular.
- **The deployed `GithubOidcVerifier` and the key that owns it.** That key can add an arbitrary signing key and therefore mint trust in a forged JWT for any repository, which makes it the highest-value secret in the system. It lives in the `identity` repository and is not `market`'s to hold. `test_VerifierIsTheRootOfTrust` asserts this explicitly.
- **The pinned attestation workflow.** `RIK` cannot see GitHub permissions, so `.github/workflows/register-rik.yml` is what decides whether a claimant controls a repository, and the contract believes its answer. It is pinned by `job_workflow_ref`, so changing it requires an owner transaction, and it should be reviewed like contract code. See ATTESTATION.md.
- **The `RIK` owner.** It can repoint the attestation source at a workflow it controls and therefore mint any repository's key. This is the most powerful role in the system and belongs behind a multisig or a timelock. The deploy script hands ownership over as a two-step transfer and leaves it pending on purpose, so completing it is a deliberate act.
- **The JSON encoder that produced the payload.** The claim matcher searches for an exact byte run and is only sound because `"` is escaped inside values. `test_UnescapedQuoteInARawPayloadWouldForgeTheEventClaim` demonstrates the failure when that does not hold.
- **The configured Doppler Airlock.** It is immutable in both the launcher and the splitter, so a malicious one is a deployment error rather than an attack. The launcher still refuses a zero or sentinel asset from it.

### Assumed hostile

- **Everyone submitting a registration.** `register` is permissionless by design; the proof names its own beneficiary through `aud`.
- **Everyone who opens an issue here.** Registration is intentionally open. A proof binds only to the repository the workflow was able to verify, and only to the wallet named in the title.
- **Every wallet a key is minted to.** `_safeMint` hands control to a contract receiver, so a registration can be re-entered exactly there. Re-entering for the same repository is refused; re-entering for another one is legitimate and stays allowed.
- **Every pool and every token the splitter touches.** Pools may lie, pay nothing, take tokens, or call back in. Accrual is a measured balance delta, subtraction is checked, and the collect path is guarded.
- **The splitter owner.** It can sweep the Airlock's unattributable integrator fees and nothing else. It cannot reach a repository bucket, and `test_CollectIntegratorFeesCannotTouchRepositoryBuckets` and the system invariants hold it to that.

### Out of scope

- **The RSA private key in `test/fixtures/load-fixture.mjs`.** Committed intentionally so the JWT fixtures are reproducible. It signs nothing outside this repository's test suite and is not a secret.
- **Anyone paying for another account's registration.** This is intended behaviour for a permissionless `register`; the proof binds only to the wallet it names.
- **A repository owner choosing a wallet they do not control.** The wallet comes from the issue title, so it is chosen by the claimant through GitHub and is publicly attributable. The contracts cannot know better.
- **An admin registering a repository to their own wallet rather than the organisation's.** Any account holding `admin` at the time of the claim can make it. The claimant is recorded on-chain, so the decision is auditable.
- **GitHub itself** — the OIDC issuer, the JWKS endpoint, the Actions platform. Report those to [GitHub's program](https://bounty.github.com).

## Scope

Covered by this policy:

- `src/RIK.sol`, `src/RIKLauncher.sol`, `src/RIKRoyaltySplitter.sol`, `src/ClaimMatcher.sol` — the contracts authored here
- `.github/workflows/register-rik.yml` — the attestation workflow pinned on-chain, including anything that lets a claimant be credited with a repository they do not control, changes which wallet or repository a proof ends up naming, or exposes `FCF_REGISTRAR_PRIVATE_KEY` or `FCF_APP_PRIVATE_KEY`
- `.github/scripts/app-token.mjs` — anything that mints an installation token for a repository the app is not installed on
- `script/` — anything that misdirects a deployment, in particular the predicted-address wiring between the launcher and the splitter
- `bin/market` and `tools/` — anything that leaks a key or misdirects an operation

Vendored from `identity` and reported there instead: `src/GithubOidcVerifier.sol`, `src/IJwtVerifier.sol`, `src/JsonClaim.sol`. They are byte-identical copies of deployed sources and must not be edited here.

## How this is checked

| | |
| --- | --- |
| Unit, fuzz and adversarial tests | `forge test` |
| Stateful invariants | `test/*.invariant.t.sol` |
| Long soak | `FOUNDRY_PROFILE=deep forge test` |
| Linter | `forge lint` |
| Static analysis | `slither .` |

`slither.config.json` filters the vendored sources, which are reviewed upstream, and disables two style detectors (`assembly`, `cyclomatic-complexity`) that fire on the hand-written scan in `ClaimMatcher` and the hex encoder in `RIK`. Both are deliberate and are held to a differential suite instead.

Everything else slither reports is accepted in place with a `slither-disable-next-line` and a reason next to the code:

| Finding | Where | Why it is accepted |
| --- | --- | --- |
| `reentrancy-no-eth` | `RIKLauncher.launch` | The asset is only known after the Airlock answers, so recording it is necessarily post-call. What that write must not do is create a second market, and the slot is reserved *before* the call so exclusivity holds independently of `nonReentrant`. |
| `reentrancy-benign` | `RIKRoyaltySplitter.collectPoolFees` | The amount to credit is the difference the call made, so crediting is necessarily post-call. Guarded, and the reentrancy is tested directly. |
| `unused-return` | `RIKLauncher._create` | Governance, timelock and migration pool are the Airlock's business; callers read them from its own events. |
| `incorrect-equality` | `RIKRoyaltySplitter._accrue` | The comparison is against a measured delta, not a balance, and only decides whether to skip a no-op write. |
| `unused-return` | `RIK._verifyClaims` | The last claim has no successor, so the cursor it returns has nothing to seed. |
| `unused-return` | `RIKLauncher._splitterIsBeneficiary`, `RIKRoyaltySplitter.collectPoolFees` | Only `poolKey` is read from Doppler's `getState`; the other members of `PoolState` describe the sale rather than the pool's identity. |
| `dead-code` | `RIK._addressText` | Retained as the readable reference `audienceOf` is fuzzed against. Nothing in `src/` calls it and solc drops it, so the deployed bytecode is byte-for-byte identical with and without it. |

Note that slither builds with `--skip ./test/**`, which leaves the Foundry cache without test artifacts. Run `forge clean` before `forge test` afterwards, or run the two in separate jobs as CI does.

## Doppler integration

The market half depends on contracts this project does not control, and the test suite exercises
mocks. The following were checked directly against the deployed contracts on Base Mainnet and
against [Doppler's source](https://github.com/whetstoneresearch/doppler):

| Interface | Checked against | Result |
| --- | --- | --- |
| `IAirlock.create` | `0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12` | selector `0x882db707` present; `CreateParams` field order matches; `integrator` is field 11 |
| `IAirlock.getIntegratorFees` / `collectIntegratorFees` | as above | selectors `0xe7f0d8f1` and `0x1285e1ce` present; live call returns |
| `IDopplerHookInitializer.getState` | `DopplerHookInitializer`, `RehypeDopplerHookInitializer` | selector `0x1bab58f5` present; the seven-element tuple decodes against the live contract |
| `IDopplerHookInitializer.getShares` | as above | selector `0x5ebb58fb` present |
| `IDopplerHookInitializer.collectFees` | as above | selector `0x817db73b` present; returns `(uint128, uint128)` |
| Pool id derivation | `Uniswap/v4-core` | `PoolIdLibrary.toId` is `keccak256(abi.encode(poolKey))` over five slots |

Two properties of Doppler's fee model are load-bearing and are covered by tests written against a
mock that reproduces `FeesManager` rather than approximating it:

- `collectFees` releases only the **caller's** share, so `RIKRoyaltySplitter` must make the call
  itself and must hold shares. `RIKLauncher` rejects a launch that has not registered it, because
  beneficiaries are fixed at pool creation and cannot be added afterwards.
- Releases are ERC20 transfers, so a native numeraire is rejected at launch.

## Supported versions

The `main` branch and whatever is currently deployed. There are no maintained release branches.
