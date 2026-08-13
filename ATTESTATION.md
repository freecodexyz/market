# Attestation

How a GitHub repository is bound to a wallet, why the model is shaped this way, and which
alternatives were rejected. This is the design record for the proof model in
[`src/RIK.sol`](src/RIK.sol).

## The problem

A `RIK` asserts that a wallet controls GitHub repository R. Minting one requires answering two
separate questions, both unforgeably:

1. **Which repository is this?**
2. **Does the requester control it?**

The first is straightforward: GitHub sets `repository_id` in an Actions OIDC token from the
repository the workflow ran in. The second is the difficult one.

## The previous model

The first implementation required the user to add a `workflow_dispatch` workflow to their own
repository. Dispatching it requires write access, so the resulting token answered both questions at
once: `repository_id` was theirs, and only an account with write access could have started the run.

The model is sound but imposes significant friction. The user must commit a workflow file to the
repository, construct the audience encoding correctly, and submit a transaction.

The `identity` repository solves the equivalent problem for user accounts without any of that: the
user opens an issue on `identity` itself, and its pinned workflow mints the key. Nothing is
installed, nothing is committed, and a registrar key pays the gas. This document covers applying the
same approach to repository keys.

## The available degree of freedom

Moving attestation into this repository changes what the OIDC token describes. `repository_id` now
identifies this repository, `actor_id` identifies the account that opened the issue, and no claim
describes the repository being claimed.

Every claim in an Actions OIDC token is set by GitHub except `aud`, which the workflow supplies when
it requests the token and which may be an arbitrary string. It is therefore the only field through
which a reviewed workflow can pass data to the chain, and the chain trusts it exactly as far as it
trusts the workflow that produced it.

The audience therefore carries the claim:

```
aud = "<wallet>:<repositoryId>:<ownerId>"
```

`RIK` pins the remaining claims to establish that the string was produced by reviewed code:

| Claim | Checked against | Prevents |
| --- | --- | --- |
| `aud` | the wallet, repository and owner being registered | redirecting a proof to another wallet or repository |
| `actor_id` | the GitHub account being credited | crediting the claim to a different account |
| `repository_id` | `attestationRepoId` | invoking the workflow as a reusable workflow from elsewhere |
| `job_workflow_ref` | `jobWorkflowRef` | modifying the attestation workflow without an owner transaction |
| `event_name` | `issues` | using a trigger that runs with different context |

The contract cannot evaluate whether an account controls a repository. It verifies that the answer
came from the pinned workflow, and the workflow performs the check. This is the same trade `identity`
makes when it trusts `register.yml` to read a wallet from an issue title, with more weight on the
workflow, which is why the check is specified below rather than left to the implementation.

## Establishing control

The workflow must establish that the issue opener controls the claimed repository, using only what a
workflow running in this repository can observe. Three mechanisms are used, in order.

### 1. Owner — the repository belongs to the requesting account

`GET /repos/{owner}/{repo}` is public and returns `owner.id` and `owner.type`. If `owner.type` is
`User` and `owner.id` equals the token's `actor_id`, the requester owns the repository. This requires
no installation or configuration and covers most individual accounts.

### 2. Admin — a GitHub App confirms the requester's permission

`GET /repos/{owner}/{repo}/collaborators/{username}/permission` returns a user's role on a
repository and requires only **`Metadata: read`**, the minimum permission a GitHub App can request.
With the app installed, the workflow can confirm the requester holds `admin`.

This is the mechanism for organisations. Installing the app is a one-time action by an account with
org-owner or repo-admin rights, so the installation is itself evidence of control, and subsequent
registrations require only an issue. It is also the only mechanism that works for **private**
repositories, since the other two read public data.

### 3. Topic — an admin endorses the request publicly

Repository **topics require admin permission** to set and are publicly readable. An admin can
therefore endorse a specific request by adding a one-off topic:

```
fcf-<first 20 hex characters of sha256(actorId | repositoryId | wallet)>
```

The workflow computes the expected topic and checks for it. Because the topic commits to both the
requester and the wallet, its presence constitutes an admin approving that account, wallet and
repository. It can be removed once registration completes.

Topics are limited to lowercase letters, numbers and hyphens, at most 50 characters and at most 20
per repository, which is why the challenge is a truncated hash rather than the values themselves.

This is the fallback for organisations that will not install an app. It requires a settings change
rather than a commit and leaves no artifact in the repository.

## Rejected alternatives

- **A file in the repository** — `.well-known/fcf.txt` or similar. Works and requires write access,
  but reintroduces the commit-to-your-own-repository friction this design removes.
- **Public organisation membership** — `GET /orgs/{org}/public_members` is public, but membership is
  opt-in and does not imply permission on a specific repository. An outside collaborator can hold
  admin without being a member, and a public member may have no access.
- **Organisation owners from public data** — not exposed. There is no public endpoint that lists who
  administers an organisation, which is why mechanisms 2 and 3 are required.
- **A machine user added as a collaborator** — functionally equivalent to a GitHub App, but apps are
  scoped per repository, request a single permission, and are auditable in organisation settings.
- **Claim-and-challenge with a dispute window** — allow any claim and let the owner override during a
  window. This moves the problem into arbitration, requires governance, and adds more unaudited
  contract surface than it removes.
- **A backend that signs attestations** — the smallest change, but it replaces a publicly verifiable
  proof with a key that must be trusted.

## Consequences

- **The registry gained an owner.** `attestationRepoId` and `jobWorkflowRef` must be settable,
  because rotating the workflow is a routine operation. That owner can therefore point the registry
  at a workflow it controls and mint any repository's key. It is the highest-privilege role in the
  system and should be a multisig or timelock rather than a hot key. `identity` has the same
  property; the impact is larger here because these keys carry royalties.
- **The workflow is load-bearing.** It is pinned by `job_workflow_ref`, so changing it requires an
  owner transaction, and it should be reviewed to the same standard as contract code.
- **Registration remains once-only and the key remains transferable.** The market half is unchanged.
