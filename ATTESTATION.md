# Attestation

How a GitHub repository comes to be bound to a wallet, why it works that way, and what was tried
first. This is the design record for the proof model in [`src/RIK.sol`](src/RIK.sol).

## The problem

A `RIK` says "this wallet controls GitHub repository R". Minting one has to answer two questions at
once, and they are not the same question:

1. **Which repository is this?** — must be unforgeable.
2. **Does the person asking control it?** — must be unforgeable.

The first is easy, because GitHub sets `repository_id` in an Actions OIDC token from the repository
the workflow actually ran in. The second is the whole problem.

## What we had, and why it was replaced

The first implementation made the user add a `workflow_dispatch` workflow to their **own**
repository. Dispatching it requires write access, so the resulting token answered both questions at
once: `repository_id` was theirs, and only somebody with write access could have started the run.

It is sound, and it is a bad experience. The user has to commit a workflow file to a repository they
may not want to touch, work out the audience encoding, and then get a transaction on chain.

The `identity` repository solved the same shape of problem for user accounts without any of that: you
open an issue on **its** repository, and its own pinned workflow mints your key. Nothing is installed,
nothing is committed, and a registrar key pays the gas. This document is about getting a repository
key to that same standard.

## The one degree of freedom

Move attestation into this repository and the OIDC token changes meaning completely. Now
`repository_id` is *this* repository, `actor_id` is whoever opened the issue, and nothing in the
token says anything about the repository being claimed.

Every claim in an Actions OIDC token is set by GitHub except one. `aud` is chosen by the workflow at
the moment it requests the token, and it is an arbitrary string. That is the only channel through
which a reviewed workflow can say something to the chain, and the chain will believe it exactly as
far as it trusts the workflow that produced it.

So the audience carries the claim being made:

```
aud = "<wallet>:<repositoryId>:<ownerId>"
```

and `RIK` pins the rest of the token to make sure that string came from code that has been reviewed:

| Claim | Checked against | Stops |
| --- | --- | --- |
| `aud` | the wallet, repository and owner being registered | redirecting a proof to another wallet or repository |
| `actor_id` | the GitHub account being credited | crediting the claim to somebody else |
| `repository_id` | `attestationRepoId` | invoking the workflow as a reusable workflow from elsewhere |
| `job_workflow_ref` | `jobWorkflowRef` | rewriting the attestation workflow without an owner transaction |
| `event_name` | `issues` | using a trigger that runs with different context |

The contract cannot check "does this account control that repository". It checks that the answer
came from the pinned workflow, and the workflow does the checking. That trade is the same one
`identity` makes when it trusts `register.yml` to read a wallet out of an issue title — it is just
carrying more weight here, which is why the check itself is written down below rather than left to
whatever the workflow happens to do.

## Proving control

The workflow has to establish that the issue opener controls the claimed repository, using only what
a workflow running in *this* repository can see. Three ways work, in this order.

### 1. Owner — the repository belongs to the account asking

`GET /repos/{owner}/{repo}` is public and returns `owner.id` and `owner.type`. If `owner.type` is
`User` and `owner.id` equals the token's `actor_id`, the asker owns the repository. Nothing to
install, nothing to configure, nothing to touch. This covers most individual developers, and it is
the case that should feel like magic.

### 2. Admin — a GitHub App confirms the asker's permission

`GET /repos/{owner}/{repo}/collaborators/{username}/permission` returns a user's role on a
repository, and it needs only **`Metadata: read`** — the least a GitHub App can ask for. With the app
installed, the workflow can confirm the asker holds `admin` on the repository.

This is the answer for organizations. Installing the app is a one-time action by somebody who
already has org-owner or repo-admin rights, so the installation is itself evidence, and afterwards
every repository in scope registers with nothing but an issue. It is also the only tier that works
for **private** repositories, because the other two read public data.

### 3. Topic — an admin endorses the request in the open

Repository **topics require admin permission** to set, and they are public. So an admin can endorse a
specific request by adding a one-off topic:

```
fcf-<first 20 hex characters of sha256(actorId | repositoryId | wallet)>
```

The workflow computes the expected topic and looks for it. Because the topic commits to the asker
*and* the wallet, its presence is an admin saying "this account, this wallet, this repository". It
can be removed the moment registration completes.

Topics are constrained to lowercase letters, numbers and hyphens, at most 50 characters, at most 20
per repository, which is why the challenge is a truncated hash rather than the values themselves.

This is the fallback for an organization that will not install anything. It is a settings toggle
rather than a commit, and it leaves no artifact behind.

## Options that were considered and rejected

- **A file in the repository** — `.well-known/fcf.txt` or similar. Works, requires write access, and
  is exactly the "commit something to your own repository" friction this design exists to remove.
- **Public organization membership** — `GET /orgs/{org}/public_members` is public, but membership is
  opt-in and says nothing about permission on a specific repository. An outside collaborator can have
  admin without being a member; a public member can have no access at all.
- **Organization owners from public data** — not exposed. There is no public endpoint that answers
  "who administers this organization", which is the reason tiers 2 and 3 exist at all.
- **A machine user added as a collaborator** — works, and is what a GitHub App does properly. Apps
  are scoped per repository, ask for one permission, and are auditable in org settings.
- **Claim-and-challenge with a dispute window** — let anyone claim a repository and let the real
  owner override during a window. Pushes the whole problem into arbitration, needs governance, and
  adds far more unaudited contract surface than the thing it replaces.
- **A backend that signs attestations** — the smallest change and the worst one. It replaces a proof
  anybody can verify with a key somebody has to trust.

## What this costs

The honest summary of what moved:

- **The registry gained an owner.** `attestationRepoId` and `jobWorkflowRef` have to be settable,
  because rotating the workflow is a normal operation. That owner can therefore point the registry at
  a workflow it controls and mint any repository's key. It is the most powerful role in the system
  and should be a multisig or a timelock, never a hot key. `identity` has the same property; it
  matters more here because these keys carry royalties.
- **The workflow became load-bearing.** It is pinned by `job_workflow_ref`, so changing it requires an
  owner transaction, and it should be reviewed like contract code.
- **Registration is still once, forever, and the key is still transferable.** Nothing about the
  market half changed.
