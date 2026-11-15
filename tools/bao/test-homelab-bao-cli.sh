#!/usr/bin/env bash
# The helper against the REAL bao binary and a stand-in for the route's API: the HTTP requests the CLI sends must be exactly the allowed API
# paths (explicit KV v2 data and metadata paths, the own-token calls), never a system path. Skipped when bao 2.7.2 is not installed.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
if [[ $(bao version 2>/dev/null || true) != "OpenBao v2.7.2 "* ]]; then echo "skip real bao 2.7.2 not installed"; exit 0; fi
t=$(mktemp -d "${TMPDIR:-/tmp}/test-hbao-cli.XXXXXX")
trap '[[ -z ${PID:-} ]] || kill "$PID" 2>/dev/null || true; rm -rf "$t"' EXIT
Q=$(printf 'q%.0s' 1 2 3 4 5 6)
SESSION="canary-session-$Q"
export STUB_API_TOKEN=$SESSION STUB_FIELD=GHCR_PULL_TOKEN
python3 test/stub-bao-api "$t/requests.log" >"$t/port" &
PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $t/port ]] && break; sleep 0.3; done
port=$(head -1 "$t/port")
mkdir -p "$t/home/cache" "$t/tmp"
chmod 700 "$t/home/cache"
printf '%s' "$SESSION" >"$t/home/cache/token"
chmod 600 "$t/home/cache/token"
export HOMELAB_BAO_TEST=1 HOMELAB_BAO_ADDR="http://127.0.0.1:$port" HOMELAB_BAO_HOME=$t/home/cache TMPDIR=$t/tmp
H=$HERE/homelab-bao
hb() { rc=0; out=$("$H" "$@" 2>&1 </dev/null) || rc=$?; }

hb status
[[ $rc == 0 && $out == 'OK status policies=agents-read,apps-create,default ttl=3600s renewable=true' ]] && ok "status through the real CLI" || bad "status: rc=$rc $out"
hb names
[[ $rc == 0 && $out == $'door-scan\nghcr' ]] && ok "names: the real CLI lists the entries (GET with list=true on the metadata path)" || bad "names: rc=$rc $out"
hb check ghcr
[[ $rc == 0 && $out == 'OK check ghcr fields=GHCR_PULL_TOKEN version=3' ]] && ok "check: the real CLI reads the data path, fields and version" || bad "check: rc=$rc $out"
rc=0
out=$("$H" run ghcr -- sh -c "printf '%s' \"\${GHCR_PULL_TOKEN-}\" | wc -c | tr -d ' '" 2>&1 </dev/null) || rc=$?
[[ $rc == 0 && $out == 12 ]] && ok "run: the field reaches the command through the real CLI" || bad "run: rc=$rc $out"
hb put-generated cli-app value key
[[ $rc == 0 && $out == 'OK put secret/apps/cli-app/value keys=1' ]] && ok "put-generated through the real CLI" || bad "put: rc=$rc $out"
hb put-generated cli-app value key
[[ $rc != 0 && $out == 'FAIL exists or denied' ]] && ok "a second write: FAIL exists or denied" || bad "put again: rc=$rc $out"
hb logout
[[ $rc == 0 ]] && ok "logout through the real CLI" || bad "logout: rc=$rc $out"

if grep -E ' /v1/sys/' "$t/requests.log" >/dev/null; then bad "a system path was requested: $(grep -E ' /v1/sys/' "$t/requests.log" | head -2 | tr '\n' ' ')"; else ok "no request to a system path (no mount preflight, no health call)"; fi
bad_req=$(grep -vE '^(GET|PUT|POST) /v1/(auth/token/(lookup-self|renew-self|revoke-self)|secret/metadata/agents/pi(\?list=true)?|secret/data/agents/pi/[a-z0-9-]+|secret/data/apps/[a-z0-9-]+/[a-z0-9-]+)$' "$t/requests.log" || true)
[[ -z $bad_req ]] && ok "every request is one of the paths the route lets through ($(wc -l <"$t/requests.log" | tr -d ' ') requests)" || bad "a request outside the allowlist: $bad_req"
grep -q '^GET /v1/secret/data/agents/pi/ghcr$' "$t/requests.log" && grep -q '^GET /v1/secret/metadata/agents/pi?list=true$' "$t/requests.log" && ok "reads use the explicit KV v2 data and metadata paths" || bad "explicit paths missing: $(cat "$t/requests.log")"

[[ $fails -eq 0 ]] && echo "test-homelab-bao-cli OK" || { echo "test-homelab-bao-cli: $fails failure(s)"; exit 1; }
