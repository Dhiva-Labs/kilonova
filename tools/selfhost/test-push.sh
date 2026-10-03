#!/usr/bin/env bash
# End-to-end test of payment pushes on a private regtest chain:
# registers a wallet with push-register's script, pays it, mines one block,
# and checks that ntfy got a push on the wallet's topic (and on a bound
# UnifiedPush topic) that names no amount, address or transaction id.
#
#   tools/selfhost/test-push.sh       (needs docker, curl, jq)
#
# Runs as its own compose project, kn-push, on ports 29181, 29183, 29443,
# 29480 and 29490 of 127.0.0.1, and removes it afterwards (set
# KN_PUSH_KEEP=1 to keep it running; KN_PUSH_TOPIC_FILE=<path> also writes
# the topic there, for core/kn-sync/tests/selfhost_push.rs).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export KN_UID KN_GID
KN_UID="$(id -u)"
KN_GID="$(id -g)"
dc() { docker compose -p kn-push -f "$here/test/compose.yaml" "$@"; }
cleanup() {
  [[ -n "${KN_PUSH_KEEP:-}" ]] || dc down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
rpc() { # port method [params]
  curl -sf "http://127.0.0.1:$1/json_rpc" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"$2\",\"params\":${3:-{\}}}"
}
lws() { curl -sf "http://127.0.0.1:29443/$1" -d "$2"; }
try_for() { # seconds command...: whether the command succeeded in time
  local deadline=$((SECONDS + $1))
  shift
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || return 1
    sleep 1
  done
}
wait_for() { # seconds description command...
  local seconds=$1 what=$2
  shift 2
  try_for "$seconds" "$@" || fail "timed out waiting for $what"
}
messages() { # topic: the ntfy messages cached for it, one JSON per line
  curl -sf "http://127.0.0.1:29480/$1/json?poll=1&since=all" | jq -c 'select(.event == "message")'
}
has_message() { [[ -n "$(messages "$1")" ]]; }

echo "== Starting kn-push"
dc up -d --build
wait_for 60 monerod rpc 29181 get_info
wait_for 60 wallet-rpc rpc 29183 get_version
wait_for 60 ntfy curl -sf http://127.0.0.1:29480/v1/health

echo "== Wallets"
rpc 29183 create_wallet '{"filename":"watched","language":"English"}' >/dev/null
watched=$(rpc 29183 get_address | jq -r .result.address)
view_key=$(rpc 29183 query_key '{"key_type":"view_key"}' | jq -r .result.key)
rpc 29183 close_wallet >/dev/null
rpc 29183 create_wallet '{"filename":"miner","language":"English"}' >/dev/null
miner=$(rpc 29183 get_address | jq -r .result.address)
rpc 29181 generateblocks "{\"amount_of_blocks\":80,\"wallet_address\":\"$miner\"}" >/dev/null

echo "== Light wallet server account"
login="{\"address\":\"$watched\",\"view_key\":\"$view_key\",\"create_account\":true,\"generated_locally\":true}"
wait_for 60 "lws login" lws login "$login"
scanned() {
  local info
  info=$(lws get_address_info "{\"address\":\"$watched\",\"view_key\":\"$view_key\"}")
  [[ $(jq .scanned_block_height <<<"$info") -ge 80 ]]
}
wait_for 120 "lws to scan" scanned

echo "== push-register"
out=$(dc run --rm -T push-register "$watched")
code=$(grep -m1 '^kilonova-push:' <<<"$out") || fail "no code printed: $out"
topic=$(sed -n 's/.*topic=\(kn[0-9a-f]*\).*/\1/p' <<<"$code")
[[ ${#topic} -eq 34 ]] || fail "bad topic in $code"
[[ $code == *"server=http%3A%2F%2F127.0.0.1%3A29480"* ]] || fail "no server in $code"
echo "$code"
[[ -z "${KN_PUSH_TOPIC_FILE:-}" ]] || printf '%s\n' "$topic" >"$KN_PUSH_TOPIC_FILE"
# A phone's UnifiedPush topic, bound the way Kilonova binds it.
curl -sf -X POST "http://127.0.0.1:29490/bind/$topic" -d upKnPushTest1 ||
  fail "bind refused"
curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:29490/bind/kn00000000000000000000000000000000" -d upX |
  grep -q 404 || fail "bind accepted an unknown token"

echo "== Paying the wallet"
wait_for 60 "miner balance" sh -c \
  "curl -sf http://127.0.0.1:29183/json_rpc -d '{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"get_balance\"}' | jq -e '.result.unlocked_balance > 0'"
amount=1234567890123
tx=$(rpc 29183 transfer "{\"destinations\":[{\"amount\":$amount,\"address\":\"$watched\"}]}")
tx_hash=$(jq -r .result.tx_hash <<<"$tx")
[[ $tx_hash != null ]] || fail "transfer failed: $tx"
if try_for 20 has_message "$topic"; then
  echo "pushed while the payment was in the pool"
fi
rpc 29181 generateblocks "{\"amount_of_blocks\":1,\"wallet_address\":\"$miner\"}" >/dev/null
wait_for 60 "push after one block" has_message "$topic"
wait_for 30 "push on the bound topic" has_message upKnPushTest1

echo "== Checking what the pushes say"
all="$(messages "$topic")
$(messages upKnPushTest1)"
echo "$all"
xmr="1.234567890123"
for secret in "$amount" "$xmr" "$watched" "$miner" "$tx_hash" "$view_key"; do
  if grep -qiF -- "$secret" <<<"$all"; then
    fail "a push contains $secret"
  fi
done
bodies=$(jq -r .message <<<"$all" | sort -u)
[[ $bodies == "$topic" ]] || fail "unexpected push body: $bodies"

echo "== Removing"
dc run --rm -T push-register --remove "$watched" >/dev/null
curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:29490/bind/$topic" -d upX | grep -q 404 ||
  fail "token still valid after --remove"

echo "== Push test passed"
