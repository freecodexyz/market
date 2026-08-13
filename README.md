# market

EVM contracts that bind a GitHub repository to a wallet through a GitHub Actions OIDC proof, and let
whoever holds that binding launch a token market for the repository and collect its trading fees.

A repository's key is a **RIK**, an ERC-721 whose token id is the repository's numeric GitHub id.
Holding it means holding the repository's market and its royalties, and it is tradeable, so the
whole thing can change hands as one asset.

## Contracts

| Contract | What it is |
| --- | --- |
| [`src/RIK.sol`](src/RIK.sol) | Repository Identity Key. Verifies a GitHub Actions OIDC proof and mints one key per repository, forever. On-chain metadata. Its owner pins the attestation source and nothing else, which still makes it the most powerful role here. |
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

No commit to your own repository, no installation, and no ETH: a workflow here verifies that you
control the repository, requests a signed proof from GitHub, and a relayer submits the transaction.
The result is posted back as a comment on the issue.

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

The splitter is a conduit, so its central invariant is that outstanding buckets plus amounts already
paid equal the total ever credited, under any interleaving of collections, transfers, payouts and
owner sweeps. [SECURITY.md](SECURITY.md) records the threat model, what is assumed honest, and the
rationale for each accepted static-analysis finding.

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
./bin/market royalty collect <asset>         # permissionless: push fees into a repository's bucket
./bin/market royalty claim 1296269 <token>   # as the current key holder
```

The signing key is read from `MARKET_PRIVATE_KEY` or `PRIVATE_KEY`, or prompted for without echo. It
is never written to `.market.yml`.

## Choosing a network

`MARKET_RPC_URL` and `MARKET_CHAIN_ID` override the recorded endpoint and pin the chain, so
rehearsing on a testnet is a variable rather than an edit to the file that also records a live
deployment. `--rpc-url` and `--chain-id` do the same per command.

The chain id is a guard rather than a setting: an endpoint's chain cannot be chosen. Declaring it
makes acting on the wrong network an error. A deploy aimed at a chain that is not present is refused
before anything is broadcast, as is any command that spends gas. Reads are not gated.

```shell
export MARKET_RPC_URL=https://sepolia.base.org
export MARKET_CHAIN_ID=84532

./bin/market doctor          # names the network: "Base Sepolia (84532)"
./bin/market deploy --verifier … --airlock … --rik-owner … --splitter-owner …
```

**Base Sepolia needs its own verifier.** `market` never deploys one, and the `identity` instance it
normally points at is on Base Mainnet, so a testnet rehearsal has to stand one up first and mirror
GitHub's signing keys into it:

```shell
forge create --rpc-url "$MARKET_RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
  src/GithubOidcVerifier.sol:GithubOidcVerifier --constructor-args <owner>
# then sync GitHub's JWKS into it — see the identity repository's sync-github-keys.sh
```

`market deploy` rejects a verifier address with no code, so omitting this step fails immediately
rather than producing a registry that rejects every proof.

## Launching a market

`RIKLauncher.launch` forwards `CreateParams` to the Doppler Airlock unchanged except for
`integrator`, which it overwrites with the splitter. The caller supplies everything else, and two
fields decide whether the repository will ever be paid.

`poolInitializerData` is an ABI-encoded `InitData` for the chosen initializer:

```solidity
struct Curve { int24 tickLower; int24 tickUpper; uint16 numPositions; uint256 shares; }
struct BeneficiaryData { address beneficiary; uint96 shares; }

struct InitData {
    uint24 fee;
    int24 tickSpacing;
    int24 farTick;
    Curve[] curves;
    BeneficiaryData[] beneficiaries;
    address dopplerHook;
    bytes onInitializationDopplerHookCalldata;
    bytes graduationDopplerHookCalldata;
}
```

`beneficiaries` is the field that matters here. Doppler fixes it when the pool is created and there
is no way to add an entry afterwards, so a market launched without the splitter in the list would
accrue nothing for the repository, permanently. `RIKLauncher` therefore reads
`getShares(poolId, splitter)` after creation and reverts with `SplitterNotBeneficiary` if it is zero.

Doppler's own rules, enforced by `storeBeneficiaries`:

- addresses strictly ascending and unique, each with `shares > 0`
- shares denominated in WAD, summing to exactly `1e18`
- `airlock.owner()` must be included with at least `1e18 / 20` (5%)
- an empty array stores no beneficiaries at all, which this launcher rejects

So a minimal list has three entries — the Doppler protocol owner, the splitter, and whoever else the
launcher wants — sorted by address:

```solidity
address splitter = address(launcher.splitter());
address protocolOwner = Airlock(airlock).owner();

BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
// Sort ascending by address before encoding; the order is validated on-chain.
(beneficiaries[0], beneficiaries[1]) = protocolOwner < splitter
    ? (BeneficiaryData(protocolOwner, 0.05e18), BeneficiaryData(splitter, 0.95e18))
    : (BeneficiaryData(splitter, 0.95e18), BeneficiaryData(protocolOwner, 0.05e18));

params.poolInitializer = 0xbdf938149aC6a781f94FAa0Ed45E6a0e984c6544; // DopplerHookInitializer
params.poolInitializerData = abi.encode(InitData({ ..., beneficiaries: beneficiaries, ... }));
params.numeraire = <an ERC20>;                                       // not address(0)
```

`numeraire` must be an ERC20. Fees are released as ERC20 transfers, and the splitter cannot hold
native value, so `launch` rejects `address(0)` with `NativeNumeraireUnsupported`.

Note that `Airlock.create` returns the **asset** address in its `pool` slot for a V4 initializer,
because Uniswap V4 pools have no address. The pool is identified by the `PoolKey` the initializer
stores against the asset, which is what the splitter reads back when collecting.

## External addresses

The Doppler Airlock `--airlock` points at. It is immutable in both the launcher and the splitter, so
a wrong value cannot be corrected after deployment, and it fails quietly rather than loudly: markets
still launch, and the fees simply never arrive anywhere the splitter can collect them.

| Network | Airlock |
| --- | --- |
| Base Mainnet (8453) | `0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12` |
| Base Sepolia (84532) | `0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e` |

The pool initializer is chosen per launch through `CreateParams.poolInitializer`, not configured
here. On Base Mainnet the two that expose the fee interface this project collects through are
`DopplerHookInitializer` at `0xbdf938149ac6a781f94faa0ed45e6a0e984c6544` and
`RehypeDopplerHookInitializer` at `0xbd54a9e1d2249185a27af097abaa930631ec45c5`. A launch must
register the splitter as a fee beneficiary in `poolInitializerData`; `RIKLauncher` rejects one that
does not, because beneficiaries are fixed when the pool is created.

Source: [Doppler's contract addresses](https://docs.doppler.lol/resources/contract-addresses). Verify
before relying on either — Doppler redeploys, and this table can go stale:

```shell
cast code <airlock> --rpc-url "$MARKET_RPC_URL"                        # must not be 0x
cast call <airlock> "getIntegratorFees(address,address)(uint256)" \
  0x0000000000000000000000000000000000000001 <token> --rpc-url "$MARKET_RPC_URL"
```

The second call is the one that matters: it is the interface `RIKRoyaltySplitter` depends on, and an
address with code but a different ABI is the failure this catches.

## Notes for contributors

Read [AGENTS.md](AGENTS.md) before making changes. It records the decisions that are load-bearing:
why the event pin exists, why the key is transferable but registers only once, why the splitter never
accepts a repository id from its caller, and which files are vendored and must not be edited here.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
