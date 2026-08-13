---
name: Register a repository
about: Bind a GitHub repository to a wallet and mint its Repository Identity Key
title: "owner/repo 0xYourWalletAddress"
labels: ["registration"]
---

Replace the title above with the repository you want to register and the wallet that should hold its
key, separated by a space. The body is ignored — only the title matters.

```
octocat/Hello-World 0x1111111111111111111111111111111111111111
```

You do not need any ETH, and you do not need to commit anything to the repository. Opening this
issue is the whole flow: a workflow here checks that you control the repository, requests a signed
proof from GitHub, and a relayer pays for the transaction.

**Control is established in whichever of these applies first:**

- **You own it.** Automatic for a repository owned by your own account.
- **The fcf GitHub App is installed on it.** One `Metadata: read` permission, installed once by an
  organisation owner. Required for private repositories.
- **An admin added the challenge topic.** If neither of the above applies, the workflow will comment
  with a one-off topic to add to the repository. Adding a topic needs admin permission, which is the
  point, and it can be removed as soon as registration completes.

The result is posted back as a comment on this issue.
