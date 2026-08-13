// .github/scripts/app-token.mjs
//
// Mints a GitHub App installation token for one repository, so the attestation workflow can ask
// GitHub whether the issue opener holds `admin` on the repository being claimed.
//
// Usage: node .github/scripts/app-token.mjs <owner>/<repo>
//
// Reads APP_ID and APP_PRIVATE_KEY from the environment. Prints the token on success, and exits
// non-zero without printing anything when the app is not installed on that repository — which is
// the normal case, not an error, and is why the workflow falls through to the next tier.
//
// The app needs `Metadata: read` and nothing else. That is the least a GitHub App can be granted,
// and it is enough for `GET /repos/{owner}/{repo}/collaborators/{username}/permission`.

import { createSign } from "node:crypto";

const appId = process.env.APP_ID;
const privateKey = process.env.APP_PRIVATE_KEY;
const slug = process.argv[2] ?? "";

if (!appId || !privateKey || !/^[\w.-]+\/[\w.-]+$/.test(slug)) process.exit(1);

const API = "https://api.github.com";
const ACCEPT = { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };

function b64url(value) {
  return Buffer.from(value).toString("base64url");
}

// A short-lived assertion signed with the app's private key. GitHub caps the lifetime at 10
// minutes and rejects a future `iat`, so this backdates by a minute for clock drift.
function appJwt() {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = b64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: appId }));

  const signer = createSign("RSA-SHA256");
  signer.update(`${header}.${payload}`);
  return `${header}.${payload}.${signer.sign(privateKey, "base64url")}`;
}

async function main() {
  const jwt = appJwt();
  const auth = { Authorization: `Bearer ${jwt}`, ...ACCEPT };

  // Installed on this repository at all? An org can install the app on a subset of its
  // repositories, and a repository outside that subset is simply not provable this way.
  const installation = await fetch(`${API}/repos/${slug}/installation`, { headers: auth });
  if (!installation.ok) process.exit(1);

  const { id } = await installation.json();

  const token = await fetch(`${API}/app/installations/${id}/access_tokens`, {
    method: "POST",
    headers: auth,
  });
  if (!token.ok) process.exit(1);

  const { token: installationToken } = await token.json();
  if (!installationToken) process.exit(1);

  process.stdout.write(installationToken);
}

await main();
