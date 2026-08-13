// .github/scripts/decode-jwt.mjs
//
// Splits a compact JWS and prints the four values `RIK.register` needs, one per line:
//
//   kid            the raw `kid` string from the header, which the contract keys on as keccak256
//   headerB64      hex of the base64url header *text*
//   payloadB64     hex of the base64url payload *text*
//   signature      hex of the decoded signature bytes
//
// The header and payload are passed to the contract as their base64url text because the signed
// digest is `sha256(headerB64 || "." || payloadB64)`. Only the signature is decoded.
//
// Usage: node .github/scripts/decode-jwt.mjs <jwt>
//
// `Buffer.from(value, "base64url")` accepts the unpadded segments a JWS uses. Shell base64 decoders
// require padding and reject them, which is why this is a script rather than a pipeline.

const token = process.argv[2] ?? "";
const segments = token.split(".");

if (segments.length !== 3 || segments.some((segment) => segment.length === 0)) {
  console.error("decode-jwt: expected a compact JWS with three non-empty segments");
  process.exit(1);
}

const [headerB64, payloadB64, signatureB64] = segments;

let header;
try {
  header = JSON.parse(Buffer.from(headerB64, "base64url").toString("utf8"));
} catch {
  console.error("decode-jwt: header is not valid JSON");
  process.exit(1);
}

if (typeof header.kid !== "string" || header.kid.length === 0) {
  console.error("decode-jwt: header carries no kid");
  process.exit(1);
}

const hex = (value) => `0x${Buffer.from(value).toString("hex")}`;

process.stdout.write(
  [header.kid, hex(headerB64), hex(payloadB64), hex(Buffer.from(signatureB64, "base64url"))].join("\n") + "\n",
);
