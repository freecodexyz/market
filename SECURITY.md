# Security Policy

## Reporting a vulnerability

**Email <paoloanzn@gmail.com>. Do not open an issue, a pull request, or a discussion.**

Never disclose a vulnerability publicly before it has been fixed. That includes this repository's issue tracker, pull requests, forks, commit messages, and anywhere else public — social media, chat groups, write-ups, and conference talks included.

A public report on this codebase is not a disclosure of a theoretical weakness. `RIK` binds real GitHub repositories to real wallets, and those keys carry a market's royalties. Anything that lets a repository's key be minted to an address its owner does not control, or lets one repository be paid out of another's earnings, is directly exploitable the moment it is known.

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
- **The deployed `GithubOidcVerifier` and the key that owns it.** That key can add an arbitrary signing key and therefore mint trust in a forged JWT for any repository, which makes it the highest-value secret in the system. It lives in the `identity` repository and is not `market`'s to hold. `test_VerifierIsTheRootOfTrust` states this as an executable fact rather than leaving it implied.
- **The JSON encoder that produced the payload.** The claim matcher searches for an exact byte run and is only sound because `"` is escaped inside values. `test_UnescapedQuoteInARawPayloadWouldForgeTheEventClaim` shows precisely what breaks without that.
- **The configured Doppler Airlock.** It is immutable in both the launcher and the splitter, so a malicious one is a deployment error rather than an attack. The launcher still refuses a zero or sentinel asset from it.

### Assumed hostile

- **Everyone submitting a registration.** `register` is permissionless by design; the proof names its own beneficiary through `aud`.
- **Every GitHub account that can interact with a repository.** Opening an issue, commenting, forking, watching and opening a pull request all run a workflow in the repository's own context, so they all carry its `repository_id`. Pinning `event_name` to `workflow_dispatch` is what reduces registration to "had write access".
- **Every wallet a key is minted to.** `_safeMint` hands control to a contract receiver, so a registration can be re-entered exactly there. Re-entering for the same repository is refused; re-entering for another one is legitimate and stays allowed.
- **Every pool and every token the splitter touches.** Pools may lie, pay nothing, take tokens, or call back in. Accrual is a measured balance delta, subtraction is checked, and the collect path is guarded.
- **The splitter owner.** It can sweep the Airlock's unattributable integrator fees and nothing else. It cannot reach a repository bucket, and `test_CollectIntegratorFeesCannotTouchRepositoryBuckets` and the system invariants hold it to that.

### Out of scope

- **The RSA private key in `test/fixtures/load-fixture.mjs`.** Committed on purpose so the JWT fixtures are reproducible. It signs nothing outside this repository's test suite and is not a secret.
- **Anyone being able to pay for someone else's registration.** That is the point of a permissionless `register`; the proof still binds only to the wallet it names.
- **A repository owner choosing a wallet they do not control.** The audience is chosen by whoever dispatched the workflow. The contracts cannot know better.
- **GitHub itself** — the OIDC issuer, the JWKS endpoint, the Actions platform. Report those to [GitHub's program](https://bounty.github.com).

## Scope

Covered by this policy:

- `src/RIK.sol`, `src/RIKLauncher.sol`, `src/RIKRoyaltySplitter.sol`, `src/ClaimMatcher.sol` — the contracts authored here
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

Note that slither builds with `--skip ./test/**`, which leaves the Foundry cache without test artifacts. Run `forge clean` before `forge test` afterwards, or run the two in separate jobs as CI does.

## Supported versions

The `main` branch and whatever is currently deployed. There are no maintained release branches.
