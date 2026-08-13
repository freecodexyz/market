// test/fixtures/decode-token-uri.mjs
//
// Decodes a `data:application/json;base64,...` token URI and prints the JSON it carries, hex-encoded
// so `vm.ffi` returns it as bytes.
//
// `JSON.parse` here is the point: it fails loudly on malformed output, which substring assertions in
// Solidity would happily accept. The re-serialised object is then readable with `vm.parseJson*`.
//
// Usage: node test/fixtures/decode-token-uri.mjs <dataUri>

const PREFIX = "data:application/json;base64,";

const uri = process.argv[2] ?? "";
if (!uri.startsWith(PREFIX)) {
  throw new Error(`expected a ${PREFIX} URI, got: ${uri.slice(0, 64)}`);
}

const parsed = JSON.parse(Buffer.from(uri.slice(PREFIX.length), "base64").toString("utf8"));

// Flatten `attributes` into `trait_<slug>` keys so a test can read one without walking an array
// through `vm.parseJson`. Slugged to lower snake case because `vm.parseJsonString` cannot address a
// key containing spaces with dot notation.
const flat = { ...parsed };
for (const attribute of parsed.attributes ?? []) {
  const slug = attribute.trait_type.trim().replace(/\s+/g, "_").toLowerCase();
  flat[`trait_${slug}`] = String(attribute.value);
}
delete flat.attributes;

process.stdout.write(`0x${Buffer.from(JSON.stringify(flat)).toString("hex")}`);
