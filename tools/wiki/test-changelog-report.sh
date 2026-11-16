#!/usr/bin/env bash
# Self-test of tools/wiki/changelog-report.sh against stub curl and ssh (test/): a missing entry, a 12-hex run, URL userinfo, a store value in a
# page, canaries in every position, and a run without GH_TOKEN reading anonymously.
set -euo pipefail
AT=@ # an at sign is written through a variable: this tree holds no e-mail-shaped literal
cd "$(dirname "$0")"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
t=$(mktemp -d "${TMPDIR:-/tmp}/test-clr.XXXXXX")
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/state" "$t/bin" "$t/tmp"
Q=$(printf 'q%.0s' 1 2 3 4 5 6)
W_TOK="canary-wiki-$Q"
G_TOK="canary-github-$Q"
STORE="canary-store-value-$Q"
TEXT="canary-page-text-$Q"
KEYB=$(printf 'canary-ssh-key-%s' "$Q" | base64 | tr -d '\n')
cp test/stub-curl "$t/bin/curl"
cp test/stub-ssh "$t/bin/ssh"
export STUB_DIR=$t/state STUB_GH=$G_TOK STUB_WIKI=$W_TOK STUB_STORE_VALUES=$STORE TMPDIR=$t/tmp PATH="$t/bin:$PATH"
export HOMELAB_REPORT_TEST=1 REPORT_GH_API=https://github.example.invalid REPORT_WIKI_URL=https://wiki.example.invalid
export WIKI_TOKEN=$W_TOK DOOR_SCAN_SSH_KEY=$KEYB DOOR_SCAN_TARGET=owner${AT}scan.example.invalid DOOR_SCAN_KNOWN_HOST='scan.example.invalid ssh-ed25519 AAAA'
R=$PWD/changelog-report.sh
SHA40=$(printf 'a%.0s' $(seq 40))
mkstate() { # mkstate <pulls json> <changelog docs json> [<operations docs json>]
  python3 - "$t/state/state.json" "$1" "$2" "${3:-[]}" <<'PYX'
import json, sys
p, pulls, ch, ops = sys.argv[1:]
json.dump({"pulls": json.loads(pulls), "collections": {"c1": {"name": "Changelog", "docs": json.loads(ch)}, "c2": {"name": "Operations", "docs": json.loads(ops)}}}, open(p, "w"))
PYX
  : >"$t/state/requests.log"
  : >"$t/state/argv.log"
  rm -f "$t/state/ssh-argv.log"
}
pr() { printf '{"number":%s,"title":"%s","merged_at":"%s"}' "$1" "$2" "$3"; }
doc() { printf '{"id":"%s","title":"%s","text":%s,"updatedAt":"%s"}' "$1" "$2" "$(printf '%s' "$3" | jq -Rs .)" "${4:-2026-11-16T10:00:00Z}"; }
run() { rc=0; out=$("$R" "$@" 2>&1 </dev/null) || rc=$?; }

P1=$(pr 97 "Add the agent tools" 2026-11-16T09:00:00Z)
P2=$(pr 98 "Change the route" 2026-11-17T09:00:00Z)
P3=$(pr 99 "Bump an image" 2026-11-18T09:00:00Z)
OLD=$(pr 90 "Old change" 2026-11-01T09:00:00Z)
UNMERGED='{"number":95,"title":"Closed without merge","merged_at":null}'
E1=$(doc d1 "2026-11-16 homelab#97: Add the agent tools" "merge $SHA40 checks OK")
E2=$(doc d2 "2026-11-17 homelab#98: Change the route" "see PR 98")
E3=$(doc d3 "2026-11-18 homelab#99: Bump an image" "verified")

# ---- all present: OK, the old and the unmerged PR do not count
mkstate "[$P1,$P2,$P3,$OLD,$UNMERGED]" "[$E1,$E2,$E3]"
run --since 2026-11-15
[[ $rc == 0 && $out == 'OK changelog prs=3 entries=3 missing=0' ]] && ok "every merged PR since the date has its entry: OK changelog prs=3 entries=3 missing=0 (an older and an unmerged PR are ignored)" || bad "all present: rc=$rc $out"
# ---- one missing
mkstate "[$P1,$P2,$P3]" "[$E1,$E2]"
run --since 2026-11-15
[[ $rc == 1 && $out == *'MISSING homelab#99 Bump an image'* && $out == *'FAIL changelog prs=3 entries=2 missing=1'* && $out != OK* ]] && ok "three PRs, two entries: MISSING homelab#<n> for the third, exit 1" || bad "missing: rc=$rc $out"
# ---- fingerprint and userinfo
mkstate "[$P1]" "[$(doc d1 '2026-11-16 homelab#97: Add the agent tools' 'checked fp 0123456789ab done')]"
run --since 2026-11-15
[[ $rc == 1 && $out == *'FAIL entry d1 fingerprint'* && $out != *0123456789ab* ]] && ok "a standalone run of exactly 12 hex characters: FAIL entry <doc id> fingerprint (not printed)" || bad "fingerprint: rc=$rc $out"
mkstate "[$P1]" "[$(doc d1 '2026-11-16 homelab#97: Add the agent tools' "clone https://user:pw${AT}host.example/x.git")]"
run --since 2026-11-15
[[ $rc == 1 && $out == *'FAIL entry d1 userinfo'* && $out != *'user:pw'* ]] && ok "a URL with user information: FAIL entry <doc id> userinfo" || bad "userinfo: rc=$rc $out"
mkstate "[$P1]" "[$(doc d1 '2026-11-16 homelab#97: Add the agent tools' 'checked fp 0123456789AB done')]"
run --since 2026-11-15
[[ $rc == 1 && $out == *'FAIL entry d1 fingerprint'* ]] && ok "an uppercase 12-hex run is a fingerprint too" || bad "uppercase fp: rc=$rc $out"
mkstate "[$P1]" "[$(doc d1 '2026-11-16 homelab#97: Add the agent tools' "clone https://someuser${AT}host.example/x.git")]"
run --since 2026-11-15
[[ $rc == 1 && $out == *'FAIL entry d1 userinfo'* && $out != *someuser* ]] && ok "a URL with a user name only is user information too" || bad "username only: rc=$rc $out"
mkstate "[$P1]" "[$(doc d1 '2026-11-16 homelab#97: ABCDEF012345 tools' 'clean text')]"
run --since 2026-11-15
[[ $rc == 1 && $out == *'FAIL entry d1 fingerprint'* ]] && ok "a 12-hex run in the page title is found" || bad "title fp: rc=$rc $out"
mkstate "[$P1]" "[$(doc d1 "2026-11-16 homelab#97: $STORE" 'clean text')]"
run --since 2026-11-15 --scan
[[ $rc == 1 && $out == *'FAIL scan wiki/d1 keys='* && $out != *"$STORE"* ]] && ok "a store value in a page title: found by --scan (title and body are sent)" || bad "title scan: rc=$rc $out"
mkstate "[$P1]" "[$E1]"
run --since 2026-11-15
[[ $rc == 0 ]] && ok "a 40-hex merge commit and a short word are not fingerprints" || bad "40 hex flagged: $out"
# ---- --scan: clean pages, a store value in a Changelog page and in an Operations page
mkstate "[$P1]" "[$E1]" "[$(doc o1 'Routes' 'names only')]"
run --since 2026-11-15 --scan
[[ $rc == 0 && $out == 'OK changelog prs=1 entries=1 missing=0' && $(wc -l <"$t/state/ssh-argv.log" | tr -d ' ') == 2 ]] && ok "--scan sends the changed Changelog and Operations pages to the owner's host (2 calls) and prints OK" || bad "scan clean: rc=$rc $out"
mkstate "[$P1]" "[$(doc d1 '2026-11-16 homelab#97: Add the agent tools' "leaked $STORE here")]" "[$(doc o1 'Routes' 'names only')]"
run --since 2026-11-15 --scan
[[ $rc == 1 && $out == *'FAIL scan wiki/d1 keys=openbao:secret/apps/canary/value:value'* && $out != *"$STORE"* ]] && ok "a store value in a page: FAIL scan wiki/<doc id> keys=… (no value)" || bad "scan value: rc=$rc $out"
mkstate "[$P1]" "[$E1]" "[$(doc o1 'Routes' "leaked $STORE here")]"
run --since 2026-11-15 --scan
[[ $rc == 1 && $out == *'FAIL scan wiki/o1 keys='* ]] && ok "the same in an Operations page" || bad "scan ops: rc=$rc $out"
mkstate "[$P1]" "[$(doc d1 '2026-11-16 homelab#97: Add the agent tools' 'old page' '2026-11-01T10:00:00Z')]" "[]"
run --since 2026-11-15 --scan
[[ $rc == 0 && ! -s $t/state/ssh-argv.log ]] && ok "--scan only sends pages changed since the date" || bad "scan since: rc=$rc $out"
mkstate "[$P1]" "[$E1]"
unset DOOR_SCAN_SSH_KEY
run --since 2026-11-15 --scan
[[ $rc != 0 && $out == *'scan host: the door-scan entry is not in the environment'* ]] && ok "--scan without the door-scan entry: FAIL" || bad "scan no entry: rc=$rc $out"
export DOOR_SCAN_SSH_KEY=$KEYB
# ---- --from-pr: the window is a PR number, not a day (a PR merged earlier on the first day has no entry and is not in the window)
PRE=$(pr 95 "Merged before the changelog" 2026-11-16T08:00:00Z)
mkstate "[$PRE,$P1,$P2,$P3]" "[$E1,$E2,$E3]"
run --since 2026-11-16
[[ $rc == 1 && $out == *'MISSING homelab#95 '* ]] && ok "fail-before: the date window of the first day reports the earlier PR as MISSING" || bad "date window: rc=$rc $out"
run --from-pr 97
[[ $rc == 0 && $out == 'OK changelog prs=3 entries=3 missing=0' ]] && ok "--from-pr 97: only PR 97 and later count: OK changelog prs=3 entries=3 missing=0" || bad "from-pr ok: rc=$rc $out"
mkstate "[$PRE,$P1,$P2,$P3]" "[$E1,$E3]"
run --from-pr 97
[[ $rc == 1 && $out == *'MISSING homelab#98 Change the route'* && $out != *'homelab#95'* && $out == *'FAIL changelog prs=3 entries=2 missing=1'* ]] && ok "--from-pr: a missing entry in the window is MISSING, exit 1" || bad "from-pr missing: rc=$rc $out"
run --from-pr 500
[[ $rc == 1 && $out == *'no merged pull request from #500'* ]] && ok "--from-pr beyond the last PR: FAIL" || bad "from-pr none: rc=$rc $out"
run --from-pr 97 --since 2026-11-16
[[ $rc != 0 && $out == *'usage'* ]] && ok "--from-pr with --since: usage FAIL" || bad "both: rc=$rc $out"
for args in "--from-pr 97 --since" "--since 2026-11-16 --from-pr" "--from-pr" "--since" "--from-pr 97 --from-pr 98" "--since 2026-11-16 --since 2026-11-17" "--from-pr  --scan" "--since '' --from-pr 97"; do
  eval "run $args"
  [[ $rc != 0 && $out == *'usage'* && $out != OK* ]] && ok "selector with a missing, empty or repeated value or both selectors ($args): usage FAIL" || bad "selector '$args': rc=$rc $out"
done
run --from-pr 9x
[[ $rc != 0 && $out == *'usage'* ]] && ok "a malformed PR number: usage FAIL" || bad "from-pr malformed: rc=$rc $out"
mkstate "[$PRE,$P1]" "[$E1]" "[$(doc o1 'Routes' "leaked $STORE here" 2026-11-16T12:00:00Z)]"
run --from-pr 97 --scan
[[ $rc == 1 && $out == *'FAIL scan wiki/o1 keys='* ]] && ok "--from-pr --scan: pages changed since the first PR's day are scanned" || bad "from-pr scan: rc=$rc $out"
# ---- anonymous GitHub read, with token
mkstate "[$P1]" "[$E1]"
run --since 2026-11-15
grep -q '^github .*auth=no$' "$t/state/requests.log" && ! grep -q 'auth=wrong' "$t/state/requests.log" && ok "without GH_TOKEN the public repository is read anonymously" || bad "anonymous read: $(cat "$t/state/requests.log")"
GH_TOKEN=$G_TOK run --since 2026-11-15
grep -q '^github .*auth=yes$' "$t/state/requests.log" && ok "with GH_TOKEN the token is sent" || bad "token read"
# ---- usage, missing key, missing collection
run
[[ $rc != 0 && $out == *'usage'* ]] && ok "no --since: usage FAIL" || bad "usage: $out"
run --since 2026-13-45x
[[ $rc != 0 && $out == *'usage'* ]] && ok "a malformed date: usage FAIL" || bad "date: $out"
rc=0
out=$(env -u WIKI_TOKEN "$R" --since 2026-11-15 2>&1 </dev/null) || rc=$?
[[ $rc != 0 && $out == *'WIKI_TOKEN is not in the environment'* ]] && ok "no WIKI_TOKEN is a FAIL" || bad "no key: rc=$rc $out"
python3 - "$t/state/state.json" <<'PYX'
import json, sys
s = json.load(open(sys.argv[1]))
s["collections"].pop("c1")
json.dump(s, open(sys.argv[1], "w"))
PYX
run --since 2026-11-15
[[ $rc != 0 && $out == *'the collection Changelog does not exist'* ]] && ok "no Changelog collection: FAIL" || bad "no collection: rc=$rc $out"
# ---- canaries: key, token, page text, ssh key in no output, argv, log or temp file
mkstate "[$P1]" "[$(doc d1 '2026-11-16 homelab#97: Add the agent tools' "$TEXT")]" "[$(doc o1 'Routes' "$TEXT")]"
GH_TOKEN=$G_TOK run --since 2026-11-15 --scan
for c in "$W_TOK" "$G_TOK" "$TEXT" "$KEYB" "$(printf 'canary-ssh-key-%s' "$Q")"; do
  if [[ $out == *"$c"* ]] || grep -qF -- "$c" "$t/state/argv.log" "$t/state/ssh-argv.log" "$t/state/requests.log" 2>/dev/null || grep -rqF -- "$c" "$t/tmp" 2>/dev/null; then bad "a canary reached the output, an argument list, the request log or a temp file ($c)"; fi
done
ok "no key, token, page text or ssh key in the output, any call's arguments, the logs or a temp file"
grep -q -- '-K -' "$t/state/argv.log" && ! grep -qE 'Bearer|Authorization' "$t/state/argv.log" && ok "curl takes its configuration on stdin (no header in argv)" || bad "curl argv"
[[ -z $(ls -A "$t/tmp") ]] && ok "no temp directory left" || bad "temp left"
if grep -nE 'set -x|printenv' "$R" >/dev/null; then bad "tracing or printenv"; else ok "no tracing, no printenv"; fi

[[ $fails -eq 0 ]] && echo "test-changelog-report OK" || { echo "test-changelog-report: $fails failure(s)"; exit 1; }
