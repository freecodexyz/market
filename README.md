# market

EVM contracts that bind a GitHub repository to a wallet through a GitHub Actions OIDC proof, and let
whoever holds that binding launch a token market for the repository and collect its trading fees.

A repository's key is a **RIK**, an ERC-721 whose token id is the repository's numeric GitHub id.
Holding it means holding the repository's market and its royalties, and it is tradeable, so the
whole thing can change hands as one asset.

## Contracts

| Contract | What it is |
| --- | --- |
| [`src/RIK.sol`](src/RIK.sol) | Repository Identity Key. Verifies a GitHub Actions OIDC proof and mints one key per repository, forever. On-chain metadata, no owner, no admin function. |
| [`src/RIKLauncher.sol`](src/RIKLauncher.sol) | Creates the one market a repository is allowed, on behalf of its key holder, through the Doppler Airlock. |
| [`src/RIKRoyaltySplitter.sol`](src/RIKRoyaltySplitter.sol) | Accrues that market's fees and pays them to whoever currently holds the key. |

`src/GithubOidcVerifier.sol`, `src/IJwtVerifier.sol` and `src/JsonClaim.sol` are verbatim copies of
the [`identity`](../identity) repository's deployed sources. This project does **not** deploy a
verifier; it points `RIK` at the live one, which is where GitHub's rotating signing keys are already
mirrored. They are vendored here so the test suite can run a verifier locally.

## Registering a repository

Open an issue here, titled with the repository and the wallet that should hold its key:

```
octocat/Hello-World 0x1111111111111111111111111111111111111111
```

That is the whole flow. You commit nothing to your own repository, install nothing, and need no ETH:
a workflow here checks that you control the repository, requests a signed proof from GitHub, and a
relayer pays for the transaction. The result is posted back as a comment.

## Proof model

Attestation happens in *this* repository, so the OIDC token's `repository_id` names this project and
`actor_id` names whoever opened the issue. Neither says anything about the repository being claimed.

Every claim in an Actions OIDC token is set by GitHub except one: **`aud` is an arbitrary string
chosen by the workflow**. It is therefore the only channel a reviewed workflow has to speak to the
chain, and it carries the whole claim — `"<wallet>:<repositoryId>:<ownerId>"`. The other four checks
exist to prove that string came from reviewed code: `repository_id` and `job_workflow_ref` pin the
attestation source, `event_name` pins the `issues` trigger, and `actor_id` names the account being
credited. Dropping any one of the five reintroduces impersonation, and every one has a negative test
that says so.

The contract cannot check "does this account control that repository", and does not try. The
workflow does, in three tiers: **you own it** (public data, automatic), **a GitHub App confirms you
hold `admin`** (one `Metadata: read` permission, and the only tier that works for private
repositories), or **an admin adds a one-off challenge topic** (topics require admin, and it can be
removed straight afterwards). [ATTESTATION.md](ATTESTATION.md) is the design record: why these
three, what was rejected, and what the model costs.

`register` is permissionless: the proof names its own beneficiary through `aud`, so a relayer can
pay the gas without being able to redirect the key.

## Assurance

| | |
| --- | --- |
| Unit, fuzz and adversarial tests | `forge test` |
| Stateful invariants | conservation, solvency, exclusivity, registration-is-once |
| Long soak | `FOUNDRY_PROFILE=deep forge test` |
| Linter | `forge lint --deny warnings` |
| Static analysis | `slither .`, at zero findings |
| Operator path | `./smoke-test.sh` against a local anvil |

The invariant campaigns are the part worth knowing about. The splitter is a conduit, so the property
that matters is that what it still owes plus what it has already paid equals what it was ever
credited — exactly, through any interleaving of collections, transfers, payouts and owner sweeps.
[SECURITY.md](SECURITY.md) records the threat model, what is assumed honest, and why each accepted
static-analysis finding is accepted.

## Commands

```shell
forge fmt --check
forge lint --deny warnings
forge build --sizes
forge test -vvv
forge test --gas-report

# The long version: many more fuzz inputs, much deeper invariant campaigns.
FOUNDRY_PROFILE=deep forge test

# Static analysis. Builds without test artifacts, so clean afterwards.
slither . && forge clean

# Operator path, against a local anvil started in another terminal.
anvil --silent
./smoke-test.sh
```

The CLI is Ruby 3.2, standard library only, no bundler:

```shell
./bin/market doctor                          # tooling, chain, recorded deployment
./bin/market deploy --rpc-url … --verifier … --airlock … --splitter-owner …
./bin/market status                          # verify the deployment against its own wiring
./bin/market configure                       # push variables and secrets through gh

./bin/market rik of octocat/Hello-World      # resolve a slug, then show its key
./bin/market rik show 1296269
./bin/market market show 1296269
./bin/market royalty show 1296269 <token>
./bin/market royalty collect <pool>          # permissionless: push fees into a repository's bucket
./bin/market royalty claim 1296269 <token>   # as the current key holder
```

The signing key is read from `MARKET_PRIVATE_KEY` or `PRIVATE_KEY`, or prompted for without echo. It
is never written to `.market.yml`.

## Notes for contributors

Read [AGENTS.md](AGENTS.md) before changing anything. It records the decisions that are load-bearing
rather than incidental — why the event pin exists, why the key is transferable but registers only
once, why the splitter never takes a repository id from its caller, and which files are vendored and
must not be edited here.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
