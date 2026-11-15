#!/usr/bin/env bash
# Self-test of tools/bao/homelab-bao against a stub `bao` (test/stub-bao): canary values in every position must never reach stdout, stderr,
# the arguments of any call, or a file left behind; the probe command sees the variables and nothing else of the store.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
t=$(mktemp -d "${TMPDIR:-/tmp}/test-hbao.XXXXXX")
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/state" "$t/home" "$t/tmp"
# canaries are built at run time (no literal that looks like a credential in this file)
Q=$(printf 'q%.0s' 1 2 3 4 5 6 7 8)
C1="canary-one-$Q"
C2="canary-two-$Q"
C3="canary-three-$Q"
CT="canary-entered-$Q"
export STUB_DIR=$t/state STUB_TOKEN_SUFFIX="canary-bao-session-$Q"
export HOMELAB_BAO_TEST=1 HOMELAB_BAO_BIN=$HERE/test/stub-bao HOMELAB_BAO_ADDR=https://bao.example.invalid HOMELAB_BAO_HOME=$t/home/cache TMPDIR=$t/tmp
H=$HERE/homelab-bao
hb() { rc=0; out=$("$H" "$@" 2>&1 </dev/null) || rc=$?; }
reqs() { cat "$t/state/requests.log" 2>/dev/null || true; }
seed() { # seed <entry> <field> <value>: an entry of the stub store (value from the environment of this one python process)
  SV=$3 python3 - "$t/state/state.json" "$1" "$2" <<'PYX'
import json, os, sys
p, entry, field = sys.argv[1:]
try:
    s = json.load(open(p))
except OSError:
    s = {"tk": None, "ttl": 3600, "revoked": False, "kv": {}, "versions": {}}
s["kv"].setdefault("agents/pi/" + entry, {})[field] = os.environ["SV"]
json.dump(s, open(p, "w"))
PYX
}
nottty() { python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }
leftovers() { [[ -z $(ls -A "$t/tmp") ]]; }

seed ghcr GHCR_PULL_TOKEN "$C1"
seed door-scan DOOR_SCAN_TARGET "$C2"
seed door-scan DOOR_SCAN_SSH_KEY "$C3"
seed wiki-pi WIKI_TOKEN "$C1"

# ---- no login: every reading mode says so and reads nothing else
for m in status names "run ghcr -- true" "check ghcr"; do
  # shellcheck disable=SC2086
  hb $m
  [[ $rc != 0 && $out == *'FAIL login needed'* ]] && ok "no login: '$m' prints FAIL login needed" || bad "no login $m: rc=$rc $out"
done

# ---- login
hb login
[[ $rc == 0 && $out == *'OK login ttl=3600s'* && $out != *"$STUB_TOKEN_SUFFIX"* ]] && ok "login: OK with the time to live, no token in the output" || bad "login: rc=$rc $out"
[[ $(stat -f %Lp "$HOMELAB_BAO_HOME/token" 2>/dev/null || stat -c %a "$HOMELAB_BAO_HOME/token") == 600 && $(stat -f %Lp "$HOMELAB_BAO_HOME" 2>/dev/null || stat -c %a "$HOMELAB_BAO_HOME") == 700 ]] && ok "the token file is 0600 in a 0700 directory" || bad "token modes"
STUB_LOGIN_FAIL=1 hb login
[[ $rc != 0 && $out == *'FAIL login did not complete'* ]] && ok "a login that does not complete: FAIL, the old token file stays valid" || bad "login fail: rc=$rc $out"

# ---- status, names, check
hb status
[[ $rc == 0 && $out == 'OK status policies=agents-read,apps-create,default ttl=3600s renewable=true' ]] && ok "status: the three policies and the time left, no token" || bad "status: rc=$rc $out"
python3 - "$t/state/state.json" <<'PYX'
import json, sys
s = json.load(open(sys.argv[1]))
s["ttl"] = 600
json.dump(s, open(sys.argv[1], "w"))
PYX
hb status
[[ $rc == 0 && $out == *'ttl=3600s'* && $(reqs) == *RENEW* ]] && ok "status renews a token with less than 15 minutes left" || bad "renew: rc=$rc $out"
hb names
[[ $rc == 0 && $out == $'door-scan\nghcr\nwiki-pi' ]] && ok "names: the entry names only" || bad "names: rc=$rc $out"
hb check door-scan
[[ $rc == 0 && $out == 'OK check door-scan fields=DOOR_SCAN_SSH_KEY,DOOR_SCAN_TARGET version=1' && $out != *"$C2"* && $out != *"$C3"* ]] && ok "check: field names and the version, no value" || bad "check: rc=$rc $out"
hb check 'Bad Name'
[[ $rc != 0 && $out == *'FAIL entry'* ]] && ok "check: an entry name outside the pattern is refused" || bad "check name: $out"

# ---- run: the probe sees the variables, nothing else; no canary in output, argv, files
cat >"$t/probe.sh" <<'PROBE'
#!/bin/sh
# prints lengths and presence only
printf 'ghcr=%s ' "$(printf '%s' "$GHCR_PULL_TOKEN" | wc -c | tr -d ' ')"
printf 'target=%s ' "$(printf '%s' "$DOOR_SCAN_TARGET" | wc -c | tr -d ' ')"
printf 'baovars=%s ' "$(env | grep -c '^BAO_' || true)"
printf 'wiki=%s\n' "$(printf '%s' "${WIKI_TOKEN-}" | wc -c | tr -d ' ')"
PROBE
chmod +x "$t/probe.sh"
hb run ghcr,door-scan -- "$t/probe.sh"
[[ $rc == 0 && $out == "ghcr=${#C1} target=${#C2} baovars=0 wiki=0" ]] && ok "run: the probe sees the variables of its entries only, no BAO_ variable, no other entry" || bad "run: rc=$rc $out"
hb run wiki-pi -- "$t/probe.sh"
[[ $out == *"wiki=${#C1}"* ]] && ok "run: an entry's own field (the wiki key) reaches the command" || bad "run wiki: $out"
# a command whose stdout shows the value proves nothing is filtered by the helper itself; the helper prints nothing of its own
hb run ghcr -- true
[[ $rc == 0 && -z $out ]] && ok "run: the helper adds no output of its own" || bad "run quiet: rc=$rc $out"
hb run ghcr,missing -- true
[[ $rc != 0 && $out != OK* ]] && ok "run: an entry that cannot be read runs nothing" || bad "run missing: rc=$rc $out"
for f in BASH_ENV PATH LD_PRELOAD git-token GIT_ASKPASS BAO_TOKEN; do
  seed danger "$f" "$C1"
  rm -f "$t/ran"
  hb run danger -- touch "$t/ran"
  [[ $rc != 0 && $out == "FAIL field $f" && ! -e $t/ran ]] && ok "run: field '$f' is refused (FAIL field), nothing executes" || bad "danger $f: rc=$rc $out"
  python3 - "$t/state/state.json" <<'PYX'
import json, sys
s = json.load(open(sys.argv[1]))
s["kv"].pop("agents/pi/danger")
json.dump(s, open(sys.argv[1], "w"))
PYX
done
# no canary anywhere
hb check ghcr
for c in "$C1" "$C2" "$C3" "$STUB_TOKEN_SUFFIX"; do
  if grep -rqF -- "$c" "$t/state/argv.log" "$t/tmp" "$t/home" 2>/dev/null; then
    case $c in "$STUB_TOKEN_SUFFIX") [[ $(grep -rlF -- "$c" "$t/home" "$t/tmp" "$t/state/argv.log" 2>/dev/null | tr '\n' ' ') == "$t/home/cache/token " ]] || bad "a canary outside the token file ($c)" ;; *) bad "a value in a call's arguments or a leftover file ($c)" ;; esac
  fi
done
ok "no value in the arguments of any bao call, no temp file left; the session token only in its own 0600 file"
leftovers && ok "no temp directory left after run, check and login" || bad "temp left"

# ---- put-generated: path rules, dry-run, create only
before=$(reqs | wc -l | tr -d ' ')
for badapp in '../platform' 'Foo' 'a/b' 'agents' ''; do
  hb put-generated "$badapp" value k
  [[ $rc != 0 && $out == "FAIL app $badapp" ]] && ok "put-generated app '$badapp': FAIL app, no request" || bad "put app '$badapp': rc=$rc $out"
done
hb put-generated canary 'a/b' k
[[ $rc != 0 && $out == 'FAIL name a/b' ]] && ok "put-generated name 'a/b': FAIL name" || bad "put name: $out"
[[ $(reqs | wc -l | tr -d ' ') == "$before" ]] && ok "refused paths sent no request" || bad "request sent for a bad path"
hb put-generated --dry-run canary value value
[[ $rc == 0 && $out == 'PLAN create secret/apps/canary/value keys=1' && $(reqs | wc -l | tr -d ' ') == "$before" ]] && leftovers && ok "put-generated --dry-run: PLAN create … keys=1, the request log is unchanged, no temp file" || bad "dry-run: rc=$rc $out"
hb put-generated canary value value other
[[ $rc == 0 && $out == 'OK put secret/apps/canary/value keys=2' ]] && ok "put-generated: created with two random values" || bad "put: rc=$rc $out"
python3 - "$t/state/state.json" <<'PYX' >"$t/put.chk"
import json, re, sys
s = json.load(open(sys.argv[1]))
d = s["kv"]["apps/canary/value"]
print(sorted(d), all(re.fullmatch(r"[0-9a-f]{64}", v) for v in d.values()), len(set(d.values())))
PYX
[[ $(cat "$t/put.chk") == "['other', 'value'] True 2" ]] && ok "the stored values are 32 random bytes in hex, different per key" || bad "stored values: $(cat "$t/put.chk")"
hb put-generated canary value value
[[ $rc != 0 && $out == 'FAIL exists or denied' ]] && ok "a second write of the same path: FAIL exists or denied" || bad "second put: rc=$rc $out"
[[ $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versions"]["apps/canary/value"])' "$t/state/state.json") == 1 ]] && ok "the stored version is unchanged" || bad "version changed"
grep -qE '^write secret/data/apps/canary/value @' "$t/state/argv.log" && ! grep -qE 'canary-|[0-9a-f]{64}' <(grep '^write' "$t/state/argv.log" | sed 's#@[^ ]*#@FILE#') && ok "the write names a file, no value in its arguments" || bad "write argv"
leftovers && ok "no temp file left after the writes" || bad "temp left after put"

# ---- put-entered
hb put-entered canary typed key
[[ $rc != 0 ]] && ok "put-entered with extra keys: usage FAIL" || bad "entered usage"
rc=0
out=$(nottty "$H" put-entered canary typed key 2>&1 <<<"$CT") || rc=$?
[[ $rc != 0 && $out == 'FAIL terminal needed' ]] && ok "put-entered without a terminal (a pipe, no controlling terminal): FAIL terminal needed" || bad "terminal: rc=$rc $out"
! grep -q 'apps/canary/typed' "$t/state/requests.log" && ok "nothing was written without a terminal" || bad "written without terminal"
printf '%s\n' "$CT" >"$t/tty.in"
hb put-entered --dry-run canary typed key
[[ $rc == 0 && $out == 'PLAN create secret/apps/canary/typed keys=1' ]] && ok "put-entered --dry-run reads nothing and prints PLAN" || bad "entered dry-run: $out"
HOMELAB_BAO_TTY=$t/tty.in hb put-entered canary typed key
[[ $rc == 0 && $out == 'OK put secret/apps/canary/typed keys=1' && $out != *"$CT"* ]] && ok "put-entered: the typed value is stored, never printed" || bad "entered: rc=$rc $out"
[[ $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kv"]["apps/canary/typed"]["key"])' "$t/state/state.json") == "$CT" ]] && ok "the stored value equals the typed one" || bad "entered value"
grep -qF -- "$CT" "$t/state/argv.log" && bad "entered value in argv" || ok "the entered value is in no call's arguments"
leftovers && ok "no temp file left after put-entered" || bad "temp left after entered"

# ---- version pin, logout, static rules
STUB_VERSION='OpenBao v2.6.0 (x)' hb status
[[ $rc != 0 && $out == *'FAIL bao 2.7.2 is required'* ]] && ok "another bao version: FAIL (pinned)" || bad "version: rc=$rc $out"
hb logout
[[ $rc == 0 && $out == 'OK logout' && ! -e $HOMELAB_BAO_HOME/token && $(reqs) == *REVOKE* ]] && ok "logout revokes the token and removes the file" || bad "logout: rc=$rc $out"
hb status
[[ $rc != 0 && $out == *'FAIL login needed'* ]] && ok "after logout every mode needs a login again" || bad "after logout: $out"
if grep -nE 'set -x|printenv|cat[[:space:]].*\.env|source[[:space:]].*\.env|\. [^ ]*\.env' "$H" >/dev/null; then bad "tracing, printenv or a .env read in the helper"; else ok "no tracing, no printenv, no .env read"; fi
grep -qE '^umask 077' "$H" && ok "umask 077 at the top" || bad "umask"

[[ $fails -eq 0 ]] && echo "test-homelab-bao OK" || { echo "test-homelab-bao: $fails failure(s)"; exit 1; }
