#!/usr/bin/env bash
#
# End-to-end exercise of bin/market against a local anvil.
#
# The Foundry suite proves the contracts. This proves the operator path: that the deploy scripts
# wire the two halves of the market to each other on a real chain, that the CLI reads back what it
# wrote, and that a registration made from a genuinely signed OIDC proof shows up the way the tool
# claims it does. None of that is reachable from `forge test`.
#
# Start a node first, in another terminal:
#
#   anvil --silent
#
# then run this. It only ever talks to RPC_URL, which defaults to a local anvil, and it signs with
# anvil's well-known first account. Do not point it at a real network.

set -euo pipefail

cd "$(dirname "$0")"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# anvil's first account. A published test key, deliberately: nothing here should ever be run
# against a chain where a key matters.
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

REPO_ID="${REPO_ID:-1296269}"
OWNER_ID="${OWNER_ID:-583231}"

export PRIVATE_KEY
export NO_COLOR=1

fail() {
  echo "smoke: $1" >&2
  exit 1
}

require() {
  [ "$1" = "$2" ] || fail "expected $3 to be $2, got $1"
}

chain_id=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null) || fail "no node at $RPC_URL; start anvil first"
[ "$chain_id" = "31337" ] || fail "refusing to run against chain $chain_id; this is for a local anvil only"

WALLET=$(cast wallet address --private-key "$PRIVATE_KEY")

# The registry is deployed here for the test only; a real deployment points at the live verifier
# that the identity repository owns and keeps in sync.
# --constructor-args is variadic, so it has to come last or it swallows the flags after it.
echo "==> deploying a local verifier and a stand-in Airlock"
VERIFIER=$(forge create --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --json \
  src/GithubOidcVerifier.sol:GithubOidcVerifier \
  --constructor-args "$WALLET" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["deployedTo"]')

ASSET="0x000000000000000000000000000000000000dEaD"
AIRLOCK=$(forge create --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --json \
  test/mocks/MockAirlock.sol:MockAirlock \
  --constructor-args "$ASSET" "0x000000000000000000000000000000000000bEEF" \
  | ruby -rjson -e 'puts JSON.parse(STDIN.read)["deployedTo"]')

echo "==> market deploy"
./bin/market deploy --rpc-url "$RPC_URL" --verifier "$VERIFIER" --airlock "$AIRLOCK" --splitter-owner "$WALLET"

RIK=$(ruby -ryaml -e 'puts YAML.safe_load_file(".market.yml")["rik"]')
LAUNCHER=$(ruby -ryaml -e 'puts YAML.safe_load_file(".market.yml")["launcher"]')
SPLITTER=$(ruby -ryaml -e 'puts YAML.safe_load_file(".market.yml")["splitter"]')

echo "==> market status"
./bin/market status

echo "==> the deploy script closed the launcher/splitter circle"
require "$(cast call "$LAUNCHER" "splitter()(address)" --rpc-url "$RPC_URL")" \
  "$(cast --to-checksum-address "$SPLITTER")" "launcher.splitter()"
require "$(cast call "$SPLITTER" "launcher()(address)" --rpc-url "$RPC_URL")" \
  "$(cast --to-checksum-address "$LAUNCHER")" "splitter.launcher()"

echo "==> registering $REPO_ID from a real signed proof"
read -r KID HEADER PAYLOAD SIG MODULUS EXPONENT <<<"$(
  node test/fixtures/load-fixture.mjs test/fixtures/sample-jwt.json "$REPO_ID" "$OWNER_ID" "$WALLET" \
    | sed 's/^0x//' | xxd -r -p | ruby -rjson -e '
      f = JSON.parse(STDIN.read)
      hex = ->(s) { "0x" + s.unpack1("H*") }
      puts [f["kid"], hex[f["headerB64"]], hex[f["payloadB64"]], f["signature"], f["modulus"], f["exponent"]].join(" ")
    '
)"

cast send "$VERIFIER" "addKey(bytes32,bytes,bytes)" "$KID" "$MODULUS" "$EXPONENT" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$RIK" "register(bytes32,bytes,bytes,bytes,uint256,uint256,address)" \
  "$KID" "$HEADER" "$PAYLOAD" "$SIG" "$REPO_ID" "$OWNER_ID" "$WALLET" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null

require "$(cast call "$RIK" "ownerOf(uint256)(address)" "$REPO_ID" --rpc-url "$RPC_URL")" \
  "$WALLET" "the key holder"

echo "==> market rik show"
./bin/market rik show "$REPO_ID"

echo "==> launching a market"
cast send "$LAUNCHER" \
  "launch(uint256,(uint256,uint256,address,address,bytes,address,bytes,address,bytes,address,bytes,address,bytes32))" \
  "$REPO_ID" \
  "(1000000000000000000000000,500000000000000000000000,0x4200000000000000000000000000000000000006,0x0000000000000000000000000000000000070E30,0x1234,0x0000000000000000000000000000000000090C00,0x5678,0x000000000000000000000000000000000000b001,0xabcd,0x0000000000000000000000000000000000111111,0xdcba,0x0000000000000000000000000000000000222222,0x0000000000000000000000000000000000000000000000000000000000000001)" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null

echo "==> market market show"
./bin/market market show "$REPO_ID"

echo "==> the launcher overrode the caller's integrator"
# The stand-in Airlock records what it was handed; field 12 of the struct is `integrator`.
seen=$(cast call "$AIRLOCK" \
  "lastParams()((uint256,uint256,address,address,bytes,address,bytes,address,bytes,address,bytes,address,bytes32))" \
  --rpc-url "$RPC_URL" | tr -d '\n' | grep -o '0x[0-9a-fA-F]\{40\}' | tail -2 | head -1)
require "$(cast --to-checksum-address "$seen")" "$(cast --to-checksum-address "$SPLITTER")" "the forwarded integrator"

echo "==> market royalty show"
./bin/market royalty show "$REPO_ID" "$ASSET"

echo "==> bad arguments are refused"
! ./bin/market rik show not-a-number 2>/dev/null || fail "accepted a non-numeric repository id"
! ./bin/market royalty show "$REPO_ID" 0xdeadbeef 2>/dev/null || fail "accepted a malformed address"
! ./bin/market bogus 2>/dev/null || fail "accepted an unknown command"

echo
echo "smoke: ok"
