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
ACTOR_ID="${ACTOR_ID:-583231}"

# Must match the defaults baked into test/fixtures/load-fixture.mjs, because the registry pins
# the attestation source and the fixtures sign proofs that claim to come from it.
ATTESTATION_REPO_ID="${ATTESTATION_REPO_ID:-900100200}"
JOB_WORKFLOW_REF="${JOB_WORKFLOW_REF:-freecodexyz/market/.github/workflows/register-rik.yml@refs/heads/main}"

export PRIVATE_KEY
export NO_COLOR=1

fail() {
  echo "smoke: $1" >&2
  exit 1
}

require() {
  [ "$1" = "$2" ] || fail "expected $3 to be $2, got $1"
}

# Runs a command that must fail, and must mention `pattern` when it does.
refuses() {
  local pattern="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    fail "expected '$*' to be refused, but it succeeded"
  fi
  printf '%s' "$out" | grep -q "$pattern" || fail "expected refusal to mention '$pattern', got: $out"
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

# Doppler creates the Uniswap V4 pool and stores its fee beneficiaries in the initializer, and the
# launcher refuses a market that has not registered the splitter as one.
INITIALIZER=$(forge create --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --json \
  test/mocks/MockDopplerHookInitializer.sol:MockDopplerHookInitializer \
  | ruby -rjson -e 'puts JSON.parse(STDIN.read)["deployedTo"]')

# The chain guard is what separates a testnet run from a mainnet one, so verify that it refuses
# rather than assuming it does.
echo "==> a deploy aimed at the wrong chain is refused"
refuses "Base (8453) was expected" ./bin/market deploy --rpc-url "$RPC_URL" --verifier "$VERIFIER" \
  --airlock "$AIRLOCK" --rik-owner "$WALLET" --splitter-owner "$WALLET" --chain-id 8453 \
  --attestation-repo-id "$ATTESTATION_REPO_ID" --job-workflow-ref "$JOB_WORKFLOW_REF"

echo "==> so is one pinned through the environment"
( export MARKET_CHAIN_ID=84532
  refuses "Base Sepolia (84532) was expected" ./bin/market deploy --rpc-url "$RPC_URL" \
    --verifier "$VERIFIER" --airlock "$AIRLOCK" --rik-owner "$WALLET" --splitter-owner "$WALLET" \
    --attestation-repo-id "$ATTESTATION_REPO_ID" --job-workflow-ref "$JOB_WORKFLOW_REF" )

[ -f .market.yml ] && fail "a refused deploy must not have recorded anything"

echo "==> market deploy, with the chain pinned to the one actually there"
./bin/market deploy --rpc-url "$RPC_URL" --verifier "$VERIFIER" --airlock "$AIRLOCK" \
  --rik-owner "$WALLET" --splitter-owner "$WALLET" --chain-id "$chain_id" \
  --attestation-repo-id "$ATTESTATION_REPO_ID" --job-workflow-ref "$JOB_WORKFLOW_REF"

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

echo "==> the registry pins the attestation source"
require "$(cast call "$RIK" "attestationRepoId()(uint64)" --rpc-url "$RPC_URL" | cut -d' ' -f1)" \
  "$ATTESTATION_REPO_ID" "the pinned attestation repository"

echo "==> registering $REPO_ID from a real signed proof"
# The fixture is assembled into a compact JWS and then taken apart by the same script the
# attestation workflow uses, so the workflow's decoding is exercised here rather than only in CI.
read -r JWT KID MODULUS EXPONENT <<<"$(
  node test/fixtures/load-fixture.mjs test/fixtures/sample-jwt.json "$REPO_ID" "$OWNER_ID" "$ACTOR_ID" "$WALLET" \
    | sed 's/^0x//' | xxd -r -p | ruby -rjson -e '
      f = JSON.parse(STDIN.read)
      signature = [f["signature"].sub(/\A0x/, "")].pack("H*")
      jwt = [f["headerB64"], f["payloadB64"], [signature].pack("m0").tr("+/", "-_").delete("=")].join(".")
      puts [jwt, f["kid"], f["modulus"], f["exponent"]].join(" ")
    '
)"

DECODED="$(node .github/scripts/decode-jwt.mjs "$JWT")"
KID_TEXT="$(printf '%s\n' "$DECODED" | sed -n '1p')"
HEADER="$(printf '%s\n' "$DECODED" | sed -n '2p')"
PAYLOAD="$(printf '%s\n' "$DECODED" | sed -n '3p')"
SIG="$(printf '%s\n' "$DECODED" | sed -n '4p')"

# The fixtures address keys by a padded-ASCII kid, while the live verifier keys them by
# `keccak256(kid)`. Only the workflow computes that hash, so the kid used here comes from the
# fixture and what is checked is that the decoder read the header correctly.
require "$KID_TEXT" "kid-001" "the kid the decoder read from the header"

cast send "$VERIFIER" "addKey(bytes32,bytes,bytes)" "$KID" "$MODULUS" "$EXPONENT" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$RIK" "register(bytes32,bytes,bytes,bytes,uint256,uint256,uint256,address)" \
  "$KID" "$HEADER" "$PAYLOAD" "$SIG" "$REPO_ID" "$OWNER_ID" "$ACTOR_ID" "$WALLET" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null

require "$(cast call "$RIK" "ownerOf(uint256)(address)" "$REPO_ID" --rpc-url "$RPC_URL")" \
  "$WALLET" "the key holder"

echo "==> the contract and the fixture agree on the audience encoding"
audience="$(cast call "$RIK" "audienceOf(address,uint256,uint256)(string)" \
  "$WALLET" "$REPO_ID" "$OWNER_ID" --rpc-url "$RPC_URL" | sed 's/^"//; s/"$//')"
require "$audience" "$(printf '%s:%s:%s' "$(printf '%s' "$WALLET" | tr '[:upper:]' '[:lower:]')" "$REPO_ID" "$OWNER_ID")" \
  "the audience encoding"

echo "==> the stored record decodes correctly"
record="$(cast call "$RIK" "repoOf(uint256)((uint64,uint64,uint64,uint64))" "$REPO_ID" --rpc-url "$RPC_URL")"
# cast annotates large numbers as `1296269 [1.296e6]`, so only the leading token is the value.
require "$(printf '%s' "$record" | tr -d '()' | cut -d, -f1 | awk '{print $1}')" \
  "$REPO_ID" "the recorded repository id"
require "$(printf '%s' "$record" | tr -d '()' | cut -d, -f3 | awk '{print $1}')" \
  "$ACTOR_ID" "the recorded claimant"

echo "==> market rik show"
# Captured rather than piped: `grep -q` closes the pipe on its first match, and under `pipefail`
# the resulting SIGPIPE would look like a failing command.
shown="$(./bin/market rik show "$REPO_ID")"
printf '%s' "$shown" | grep -q "claimed by" || fail "rik show must report the claimant"
printf '%s\n' "$shown"

echo "==> launching a market"
cast send "$LAUNCHER" \
  "launch(uint256,(uint256,uint256,address,address,bytes,address,bytes,address,bytes,address,bytes,address,bytes32))" \
  "$REPO_ID" \
  "(1000000000000000000000000,500000000000000000000000,0x4200000000000000000000000000000000000006,0x0000000000000000000000000000000000070E30,0x1234,0x0000000000000000000000000000000000090C00,0x5678,$INITIALIZER,0xabcd,0x0000000000000000000000000000000000111111,0xdcba,0x0000000000000000000000000000000000222222,0x0000000000000000000000000000000000000000000000000000000000000001)" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null

echo "==> market market show"
./bin/market market show "$REPO_ID"

echo "==> the launcher registered the market against the initializer"
require "$(cast call "$SPLITTER" "initializerOf(address)(address)" "$ASSET" --rpc-url "$RPC_URL")" \
  "$(cast --to-checksum-address "$INITIALIZER")" "the recorded initializer"

echo "==> the splitter is a beneficiary of the pool it will collect from"
pool_id="$(cast call "$INITIALIZER" "poolIdOf(address)(bytes32)" "$ASSET" --rpc-url "$RPC_URL")"
shares="$(cast call "$INITIALIZER" "getShares(bytes32,address)(uint256)" "$pool_id" "$SPLITTER" \
  --rpc-url "$RPC_URL" | awk '{print $1}')"
[ "$shares" != "0" ] || fail "the splitter holds no shares in the launched pool"

echo "==> the launcher overrode the caller's integrator"
# The stand-in Airlock records what it was handed; field 12 of the struct is `integrator`.
seen=$(cast call "$AIRLOCK" \
  "lastParams()((uint256,uint256,address,address,bytes,address,bytes,address,bytes,address,bytes,address,bytes32))" \
  --rpc-url "$RPC_URL" | tr -d '\n' | grep -o '0x[0-9a-fA-F]\{40\}' | tail -2 | head -1)
require "$(cast --to-checksum-address "$seen")" "$(cast --to-checksum-address "$SPLITTER")" "the forwarded integrator"

echo "==> market royalty show"
./bin/market royalty show "$REPO_ID" "$ASSET"

echo "==> the recorded chain guards anything that spends gas"
( export MARKET_CHAIN_ID=8453
  refuses "Base (8453) was expected" ./bin/market royalty collect "$ASSET"
  # Reads are not gated: inspecting a deployment is harmless whatever chain you meant.
  ./bin/market royalty show "$REPO_ID" "$ASSET" >/dev/null || fail "a read should not be chain-gated" )

# Captured rather than piped throughout: `grep -q` closes the pipe on its first match, and under
# `pipefail` the resulting SIGPIPE looks like a failing command.
echo "==> MARKET_RPC_URL overrides the recorded endpoint"
( export MARKET_RPC_URL="http://127.0.0.1:1"
  offline="$(./bin/market status 2>&1 || true)"
  printf '%s' "$offline" | grep -q "unreachable" || fail "MARKET_RPC_URL was ignored" )

echo "==> the network is named, not just numbered"
shown="$(./bin/market status 2>&1)" || fail "status should work without the override"
printf '%s' "$shown" | grep -q "Anvil (31337)" || fail "status should name the chain"

echo "==> bad arguments are refused"
! ./bin/market rik show not-a-number 2>/dev/null || fail "accepted a non-numeric repository id"
! ./bin/market royalty show "$REPO_ID" 0xdeadbeef 2>/dev/null || fail "accepted a malformed address"
! ./bin/market bogus 2>/dev/null || fail "accepted an unknown command"

echo
echo "smoke: ok"
