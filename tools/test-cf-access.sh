#!/usr/bin/env bash
# Self-test of tools/cf-access.sh against a stub curl (test/stub-curl, a tiny Cloudflare) and a local bare repository standing in for the
# fixed endpoint: creation, refusals, verification, removal order and confirm. Canaries (tokens, the login e-mail) must never reach stdout,
# stderr, curl's arguments or a file left behind.
set -euo pipefail
AT=@ # an at sign is written through a variable: this tree holds no e-mail-shaped literal
cd "$(dirname "$0")"
HERE=$PWD
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
t=$(mktemp -d "${TMPDIR:-/tmp}/test-cfa.XXXXXX")
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/state" "$t/bin" "$t/tmp"
Q=$(printf 'q%.0s' 1 2 3 4 5 6)
D_TOK="canary-dns-$Q"
A_TOK="canary-access-$Q"
MAIL="canary.owner-$Q${AT}example.invalid"
ACC=$(printf 'c%.0s' $(seq 32))
cp test/stub-curl "$t/bin/curl"
export STUB_DIR=$t/state STUB_DNS=$D_TOK STUB_ACCESS=$A_TOK TMPDIR=$t/tmp PATH="$t/bin:$PATH"
export HOMELAB_CF_TEST=1 CF_API_OVERRIDE=https://api.example.invalid/client/v4
export CLOUDFLARE_API_TOKEN=$D_TOK CLOUDFLARE_ACCESS_TOKEN=$A_TOK CLOUDFLARE_ACCESS_EMAIL=$MAIL CLOUDFLARE_ACCOUNT_ID=$ACC
# the fixed endpoint: a bare repository whose main holds one opted-in route for a host that must keep its application
mkdir -p "$t/src/apps/tools/shown" && cd "$t/src"
git init -q -b main .
cat >apps/tools/shown/route.yaml <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shown
  namespace: shown
  annotations:
    homelab.io/public-dns: "true"
spec:
  hostnames:
    - shown.chill-town.de
YAML
git add -A && git -c user.name=t -c user.email=t${AT}example.invalid commit -q -m "route" && git clone -q --bare . "$t/endpoint.git"
cd "$HERE"
export HOMELAB_CF_REPO=$t/endpoint.git
T=$HERE/cf-access.sh
state() { # state <json>
  printf '%s' "$1" >"$t/state/state.json"
  : >"$t/state/requests.log"
  : >"$t/state/argv.log"
}
run() { rc=0; out=$("$T" "$@" 2>&1 </dev/null) || rc=$?; }
reqs() { cat "$t/state/requests.log"; }
writes() { grep -cE '^(POST|PUT|DELETE) ' "$t/state/requests.log" || true; }
cname() { printf '{"id":"%s","type":"CNAME","name":"%s","content":"x.example.invalid"}' "$1" "$2"; }
txt() { printf '{"id":"%s","type":"TXT","name":"extdns-cname-%s","content":"\\"heritage=external-dns,external-dns/owner=%s,external-dns/resource=httproute/x/y\\""}' "$1" "$2" "$3"; }

# ---- host rules
state '{"apps":[],"records":[]}'
for h in '*.chill-town.de' 'chill-town.de' 'x.example.org' 'a.b.example.org' 'UP.chill-town.de' ''; do
  run "$h"
  [[ $rc != 0 && $out == FAIL* ]] && ok "host '$h' is refused" || bad "host '$h': rc=$rc $out"
done
[[ $(reqs | wc -l | tr -d ' ') == 0 ]] && ok "a refused host sends no request" || bad "request for a refused host"

# ---- create: dry-run, apply, shape of the body, idempotence
state '{"apps":[],"records":[]}'
run demo.chill-town.de --dry-run
[[ $rc == 0 && $out == *'PLAN create access application k3s-access-demo.chill-town.de'* && $(writes) == 0 ]] && ok "dry-run: PLAN, no write request" || bad "dry-run: rc=$rc $out"
run demo.chill-town.de
[[ $rc == 0 && $out == 'OK   access application k3s-access-demo.chill-town.de created id=aaaaaaaa-1111-2222-3333-444444444444' ]] && ok "create: OK with the application id" || bad "create: rc=$rc $out"
python3 - "$t/state/last_body.json" "$MAIL" <<'PYX' && ok "the body: self-hosted, name and domain of the host, one inline allow policy for the e-mail" || bad "body shape"
import json, sys
b = json.load(open(sys.argv[1]))
assert b["name"] == "k3s-access-demo.chill-town.de" and b["domain"] == "demo.chill-town.de" and b["type"] == "self_hosted"
p = b["policies"]
assert len(p) == 1 and p[0]["decision"] == "allow" and p[0]["include"] == [{"email": {"email": sys.argv[2]}}]
PYX
grep -q '^POST accounts/.*/access/apps via=access$' "$t/state/requests.log" && ok "the application is created with the Access token" || bad "token class of the create"
grep -q 'via=dns' "$t/state/requests.log" && ok "the DNS token is used only for the zone and record reads" || bad "dns token"
! grep -E '^(POST|DELETE) .*(dns_records) ' "$t/state/requests.log" | grep -q . && ok "creation writes no DNS record" || bad "dns write on create"
run demo.chill-town.de
[[ $rc == 0 && $out == 'SKIP access demo.chill-town.de exists (k3s-access-demo.chill-town.de) id=aaaaaaaa-1111-2222-3333-444444444444' && $(writes) == 1 ]] && ok "a second run is a SKIP (idempotent)" || bad "skip: rc=$rc $out"
run --verify demo.chill-town.de
[[ $rc == 0 && $out == 'OK   access demo.chill-town.de id=aaaaaaaa-1111-2222-3333-444444444444' ]] && ok "--verify: the application with the exact domain exists" || bad "verify: rc=$rc $out"
run --verify other.chill-town.de
[[ $rc != 0 && $out == *'FAIL access other.chill-town.de missing'* ]] && ok "--verify of a host without an application: FAIL" || bad "verify missing: $out"

# ---- existing host refused (record, other application exact, other application wildcard); nothing is written
state "{\"apps\":[],\"records\":[$(cname rec1 taken.chill-town.de)]}"
run taken.chill-town.de
[[ $rc != 0 && $out == *'FAIL access taken.chill-town.de exists'* && $(writes) == 0 ]] && ok "the zone holds a record for the host: FAIL access <host> exists, no write" || bad "record exists: rc=$rc $out"
state '{"apps":[{"id":"other-app","name":"somebody-else","domain":"clash.chill-town.de"}],"records":[]}'
run clash.chill-town.de
[[ $rc != 0 && $out == *'FAIL access clash.chill-town.de exists'* && $(writes) == 0 ]] && ok "another application covers the host exactly: FAIL, no write" || bad "other app exact: rc=$rc $out"
state '{"apps":[{"id":"wild-app","name":"somebody-else","domain":"*.chill-town.de"}],"records":[]}'
run fresh.chill-town.de
[[ $rc != 0 && $out == *'FAIL access fresh.chill-town.de exists'* && $(writes) == 0 ]] && ok "another application covers the host by wildcard: FAIL, no write" || bad "other app wildcard: rc=$rc $out"
state '{"apps":[{"id":"other-app","name":"somebody-else","domain":"deep.sub.chill-town.de"}],"records":[]}'
run deep.chill-town.de --dry-run
[[ $rc == 0 && $out == *PLAN* ]] && ok "an application for a different host does not block" || bad "unrelated app: rc=$rc $out"

# ---- removal: targets, route check, confirm, order, ownership
APPID=aaaaaaaa-1111-2222-3333-444444444444
state "{\"apps\":[{\"id\":\"$APPID\",\"name\":\"k3s-access-gone.chill-town.de\",\"domain\":\"gone.chill-town.de\"}],\"records\":[$(cname c1 gone.chill-town.de),$(txt t1 gone.chill-town.de k3s-homelab),$(txt t2 gone.chill-town.de somebody-else)]}"
run --remove gone.chill-town.de
[[ $rc != 0 && $out == *'needs --dry-run or --confirm'* && $(writes) == 0 ]] && ok "--remove without --dry-run or --confirm: refused" || bad "remove bare: rc=$rc $out"
run --remove gone.chill-town.de --dry-run
[[ $rc == 0 && $out == *'PLAN delete record gone.chill-town.de id=c1'* && $out == *'PLAN delete owner TXT extdns-cname-gone.chill-town.de id=t1'* && $out == *"PLAN delete access application k3s-access-gone.chill-town.de id=$APPID"* && $out == *"CONFIRM $APPID"* && $out == *'SKIP foreign TXT'* && $out != *' id=t2'* && $(writes) == 0 ]] && ok "removal dry-run: the three targets and the id to confirm, the foreign TXT is left alone, no write" || bad "remove dry-run: rc=$rc $out"
run --remove gone.chill-town.de --confirm wrong-id
[[ $rc != 0 && $out == *'FAIL access-remove gone.chill-town.de confirm'* && $(writes) == 0 ]] && ok "--confirm with another id: FAIL access-remove <host> confirm, nothing deleted" || bad "confirm: rc=$rc $out"
run --remove gone.chill-town.de --confirm "$APPID"
[[ $rc == 0 && $out == *'OK   record gone.chill-town.de deleted id=c1'* && $out == *'OK   owner TXT extdns-cname-gone.chill-town.de deleted id=t1'* && $out == *"OK   access application k3s-access-gone.chill-town.de deleted id=$APPID"* ]] && ok "removal with the printed id runs exactly the printed targets" || bad "remove: rc=$rc $out"
grep -E '^DELETE' "$t/state/requests.log" | sed 's/ via=.*//; s#/dns_records/.*#/dns_records#; s#/access/apps/.*#/access/apps#' | sed 's#accounts/[0-9a-f]*#accounts/ID#; s#zones/[0-9a-f]*#zones/ID#' >"$t/order.txt"
[[ $(cat "$t/order.txt") == $'DELETE zones/ID/dns_records\nDELETE zones/ID/dns_records\nDELETE accounts/ID/access/apps' ]] && ok "removal order: the record and the owner TXT before the Access application" || bad "order: $(cat "$t/order.txt")"
python3 - "$t/state/state.json" <<'PYX' && ok "the foreign TXT record is still there, the application is gone" || bad "after removal state"
import json, sys
s = json.load(open(sys.argv[1]))
assert [r["id"] for r in s["records"]] == ["t2"] and s["apps"] == []
PYX
state "{\"apps\":[{\"id\":\"$APPID\",\"name\":\"k3s-access-gone.chill-town.de\",\"domain\":\"gone.chill-town.de\"}],\"records\":[$(cname c1 gone.chill-town.de),$(txt t2 gone.chill-town.de somebody-else)]}"
run --remove gone.chill-town.de --dry-run
[[ $rc != 0 && $out == *'record not owned by k3s-homelab'* && $(writes) == 0 ]] && ok "a CNAME without an owner TXT of k3s-homelab: FAIL, nothing changed" || bad "unowned record: rc=$rc $out"
# R15: any other record of the host (an A record, a second CNAME) stops the removal before anything is deleted
arec() { printf '{"id":"%s","type":"A","name":"%s","content":"198.51.100.7"}' "$1" "$2"; }
state "{\"apps\":[{\"id\":\"$APPID\",\"name\":\"k3s-access-gone.chill-town.de\",\"domain\":\"gone.chill-town.de\"}],\"records\":[$(arec a1 gone.chill-town.de)]}"
run --remove gone.chill-town.de --dry-run
[[ $rc != 0 && $out == *'FAIL access-remove gone.chill-town.de records remain'* && $(writes) == 0 ]] && ok "an A record of the host: FAIL access-remove <host> records remain, nothing deleted" || bad "A record: rc=$rc $out"
state "{\"apps\":[{\"id\":\"$APPID\",\"name\":\"k3s-access-gone.chill-town.de\",\"domain\":\"gone.chill-town.de\"}],\"records\":[$(cname c1 gone.chill-town.de),$(txt t1 gone.chill-town.de k3s-homelab),$(arec a1 gone.chill-town.de)]}"
run --remove gone.chill-town.de --confirm "$APPID"
[[ $rc != 0 && $out == *'records remain'* && $(writes) == 0 ]] && ok "a CNAME with an A record next to it: refused before any delete, also with --confirm" || bad "CNAME and A: rc=$rc $out"
# a record that survives the delete keeps the Access application
sticky=$(printf '{"id":"c9","type":"CNAME","name":"gone.chill-town.de","content":"x.example.invalid","sticky":true}')
state "{\"apps\":[{\"id\":\"$APPID\",\"name\":\"k3s-access-gone.chill-town.de\",\"domain\":\"gone.chill-town.de\"}],\"records\":[$sticky,$(txt t9 gone.chill-town.de k3s-homelab)]}"
run --remove gone.chill-town.de --confirm "$APPID"
[[ $rc != 0 && $out == *'records remain; the application is kept'* ]] && ! grep -q 'DELETE accounts' "$t/state/requests.log" && ok "a record that is still there after the deletes: the Access application is kept" || bad "sticky: rc=$rc $out"
# the route check: an opted-in route on main of the fixed endpoint still names the host
state "{\"apps\":[{\"id\":\"$APPID\",\"name\":\"k3s-access-shown.chill-town.de\",\"domain\":\"shown.chill-town.de\"}],\"records\":[]}"
run --remove shown.chill-town.de --confirm "$APPID"
[[ $rc != 0 && $out == *'FAIL access-remove shown.chill-town.de route present'* && $(writes) == 0 ]] && ok "removal while an opted-in route names the host: FAIL access-remove <host> route present, nothing deleted" || bad "route present: rc=$rc $out"
state "{\"apps\":[{\"id\":\"$APPID\",\"name\":\"other-name\",\"domain\":\"nobody.chill-town.de\"}],\"records\":[]}"
run --remove nobody.chill-town.de --dry-run
[[ $rc != 0 && $out == *'no application k3s-access-nobody.chill-town.de'* && $(writes) == 0 ]] && ok "an application with another name is never a removal target" || bad "other name: rc=$rc $out"

# ---- tokens and files
run demo.chill-town.de --dry-run
unset CLOUDFLARE_ACCESS_TOKEN
run demo.chill-town.de --dry-run
[[ $rc != 0 && $out == *'the access token is not in the environment'* ]] && ok "no Access token in the environment is a FAIL" || bad "no access token, rc=$rc $out"
export CLOUDFLARE_ACCESS_TOKEN=$A_TOK
state '{"apps":[],"records":[]}'
run demo.chill-town.de
for c in "$D_TOK" "$A_TOK" "$MAIL"; do
  if [[ $out == *"$c"* ]] || grep -qF -- "$c" "$t/state/argv.log" "$t/state/requests.log" 2>/dev/null || grep -rqF -- "$c" "$t/tmp" 2>/dev/null; then bad "a canary reached the output, curl's arguments, the request log or a temp file"; fi
done
ok "no token and no e-mail in the output, curl's arguments, the request log or a temp file"
[[ -z $(ls -A "$t/tmp") ]] && ok "no temp directory left" || bad "temp left"
grep -qE -- '-K -' "$t/state/argv.log" && ! grep -qE 'Bearer|Authorization' "$t/state/argv.log" && ok "curl gets its configuration on stdin (-K -), no header in argv" || bad "curl argv"
if grep -nE 'set -x|printenv' "$T" >/dev/null; then bad "tracing or printenv"; else ok "no tracing, no printenv"; fi

[[ $fails -eq 0 ]] && echo "test-cf-access OK" || { echo "test-cf-access: $fails failure(s)"; exit 1; }
