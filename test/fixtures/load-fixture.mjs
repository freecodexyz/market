// test/fixtures/load-fixture.mjs
//
// Deterministic GitHub Actions OIDC JWT generator for the Foundry test suite. Invoked through
// `vm.ffi`, it signs a realistic token payload with a throwaway RSA key and prints the pieces the
// contracts need, hex-encoded so `vm.ffi` returns them as bytes.
//
// Usage: node test/fixtures/load-fixture.mjs <fixture.json> [repoId] [ownerId] [wallet]
//
// Every field of the payload is driven by the fixture file so negative cases stay data rather than
// code. See test/fixtures/*.json.

import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";

// Test-only key. It signs nothing outside this repository's test suite and is committed on purpose
// so fixtures are reproducible without a key-generation step.
const TEST_RSA_PRIVATE_KEY = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCN8nAo79olM8K+
SLbu/Oz0EwBgPdY+KxfAuAdbDF4EHpcViRUv50bzQT0pw/b1iiTC/qu4dziFx97Y
t0+5vDiEjxzYMZRH8WxtEFBHeXGpM47DAG6rMAYoXhMhnoVTEkz/3r2802OYSino
sI2Mxpje7vmnI2SefbOAkiOemxvYM/XGeH/Cb6W8i8+pTjZYRZbjDd8Lr2XzUZEj
j0ep1NYeBbmQZ/r4BtXuXU75xD9I7/+ar4qEGr92Oj9+9yqsxaRLNjtA84AMMkPg
b+gHnZn0wnQwVMXS5TF7+WhUt4Pkuv+DllkGewkqztugOoQCU4kivbiYhk4RBMqo
4se2H44VAgMBAAECggEAM65CQdVaElNvIwKsgATcbN0CNQgumcHsywD1xKOTE2Lj
1TZs3V0SSvzEvREZODrMuaYpdWcK0EJ+E19iiphJ55GHifs7JppyxJ6869j+lgEs
iDj/EhrREx91Tbc+iYlPOZWqdTZtu4O9EHg/gTLJc9mEUeMj/kR792K9z0Bf+e4e
R9qFE5pi2i6JueqrubKitDwSwHG3ZMHQU3HLLEF3O3szdUphoiXfga08xFGJlRIS
0L21N4CRG5gw8W2/0ZorzZcntuFztJgOSemofPDcFQC1qXnqbVdzA4da2gRr/3JD
aIAwC+AXLGg4OBOdFCec5HSb6yW7KKU3qKu83f0l3QKBgQDCB5Zk91Zpv6E+9NQo
EE35ZGiIUx/C9lp3Oi8aoDLizmkNKM87yU110ZdB22qomsgsvHIXMEhZof7xkNbG
giaE9ByBCyLaNofA0Z7lZLGs0F4t3CW6H7kTwPrzQ3sin3loaptnn2UlvAE6ssO4
T4FRaVuaIQN42r1bnA9eZYGMuwKBgQC7SG265eIoks3gnnT+4Z8OK4V+7UyCHuix
COgHNRPSGxx/QKne7GHq/amwtJUG+N/o5Xc0QCMHZzENecEmJnV6xg7o05SPaTNO
MoiAMG5H88Vfvk6RZkUDjWn/rfLVdwN7lKqOkXk505icYtmFPrTlNUurm1wZPUUq
r/a5jv6LbwKBgGSK2fvnzvdtPXkKFQXNrRoWVbSOnl7AmZA+rjn12Wh93SHci8ZH
QcRTnzWZJWPJEQFdhSFO+662qw0yKJkkyCEM/dhAlQbOSvo3pUbpLsiGEMdi1Inl
9lmuHlwAE8aVLKxW0cCYcCllip2IFLNlP3WYSsdLZCkz7/uQmsYng0IRAoGBAKd/
0dQUgj7zfXplfhHvzIep2Q16QrEl38tmQc8gY4fIg6Y0OTmNhM3c7QWDnL3NnMT5
ZbGvoySd4DtDJ8JtJykVNoR5pybUWfSYMYkkx51GosJMvIxCQXs54RGxi7vrY4wF
nL1B0oArhRRpPE51lOhi0Di9DJPuPow9MJcpEvO1AoGAbMzqkcS8DWi/+Au7VaWU
psaokuxFg/HS48h+5Z6YvbrYXsVpeJJB5qwu/xD87SXFeyIjdYf+jEKsyjagnX7t
qbO/aPxqAc88n99z57EKjB73Hk2+Yrg6jk97fW4RYf2AjQzTWZF9Ak5SI0ZUzmCS
nKG27ed/zJnymS277DA7Jcc=
-----END PRIVATE KEY-----`;

const DEFAULT_ISS = "https://token.actions.githubusercontent.com";
const DEFAULT_SLUG = "octocat/Hello-World";

function b64url(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function b64urlToHex(value) {
  return `0x${Buffer.from(value, "base64url").toString("hex")}`;
}

function bytes32Ascii(value) {
  return `0x${Buffer.concat([Buffer.from(value), Buffer.alloc(32)]).subarray(0, 32).toString("hex")}`;
}

const fixture = JSON.parse(readFileSync(process.argv[2], "utf8"));

const repoId = String(process.argv[3] ?? fixture.repoId);
const ownerId = String(process.argv[4] ?? fixture.ownerId);
const wallet = String(process.argv[5] ?? fixture.wallet).toLowerCase();

const iss = fixture.iss ?? DEFAULT_ISS;
const exp = fixture.exp ?? 4102444800;
const nbf = fixture.nbf ?? 0;
// `workflow_dispatch` is the only trigger that requires write access to the repository, which is
// what RIK reduces its whole proof of control to.
const eventName = fixture.eventName ?? "workflow_dispatch";
const slug = fixture.slug ?? DEFAULT_SLUG;
const jobWorkflowRef = fixture.jobWorkflowRef ?? `${slug}/.github/workflows/register-rik.yml@refs/heads/main`;
const kidText = fixture.kidText ?? "kid-001";
const kid = fixture.kid ?? bytes32Ascii(kidText);
// Distinguishes two tokens carrying identical claims, so a test can prove a second valid proof is
// still rejected rather than merely a replayed one.
const jti = fixture.jti ?? "00000000-0000-0000-0000-000000000000";

// Attacker-controlled free text. GitHub copies the workflow name into the token verbatim, so this
// is the natural place to attempt claim injection. A JSON encoder escapes the quotes, which is
// exactly what the JsonClaim matcher relies on.
const workflowName = fixture.workflowName ?? "Register Repository";

const privateKey = createPrivateKey(TEST_RSA_PRIVATE_KEY);
const publicJwk = createPublicKey(privateKey).export({ format: "jwk" });

const headerB64 = b64url({ alg: "RS256", typ: "JWT", kid: kidText });

// Mirrors the claim set and ordering of a real GitHub Actions OIDC token for a `workflow_dispatch`
// run.
const payload = {
  jti,
  sub: `repo:${slug}:ref:refs/heads/main`,
  aud: wallet,
  ref: "refs/heads/main",
  sha: "0000000000000000000000000000000000000000",
  repository: slug,
  repository_owner: slug.split("/")[0],
  repository_owner_id: ownerId,
  run_id: "1",
  run_number: "1",
  run_attempt: "1",
  repository_visibility: "public",
  repository_id: repoId,
  actor_id: ownerId,
  actor: slug.split("/")[0],
  workflow: workflowName,
  head_ref: "",
  base_ref: "",
  event_name: eventName,
  ref_protected: "false",
  ref_type: "branch",
  workflow_ref: jobWorkflowRef,
  job_workflow_ref: jobWorkflowRef,
  runner_environment: "github-hosted",
  iss,
};
if (!fixture.omitExp) payload.exp = exp;
if (!fixture.omitNbf) payload.nbf = nbf;
payload.iat = nbf;

const payloadB64 = b64url(payload);
const signature = sign("RSA-SHA256", Buffer.from(`${headerB64}.${payloadB64}`), privateKey);

const output = JSON.stringify({
  kid,
  headerB64,
  payloadB64,
  signature: `0x${signature.toString("hex")}`,
  modulus: b64urlToHex(publicJwk.n),
  exponent: b64urlToHex(publicJwk.e),
  wallet,
  iss,
  // Emitted as decimal strings rather than JSON numbers: a repository id at the uint64 boundary
  // does not survive a round trip through a double.
  repoId,
  ownerId,
  eventName,
  jobWorkflowRef,
  exp,
  nbf,
});

process.stdout.write(`0x${Buffer.from(output).toString("hex")}`);
