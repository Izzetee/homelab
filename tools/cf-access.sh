#!/usr/bin/env bash
# cf-access.sh <host> [--dry-run] | --verify <host> | --remove <host> (--dry-run | --confirm <app id>)
# Creates, checks and removes the Access application `k3s-access-<host>` of a public test name.
set -euo pipefail
umask 077

ZONE=chill-town.de
OWNER_ID=k3s-homelab
TXT_PREFIX=extdns-cname-
ENDPOINT=https://github.com/Izzetee/homelab.git
CF_API=https://api.cloudflare.com/client/v4
if [[ ${HOMELAB_CF_TEST:-0} == 1 ]]; then CF_API=${CF_API_OVERRIDE:-$CF_API}; fi
TMP=""
cleanup() { [[ -z $TMP ]] || rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

fail() { echo "FAIL $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed"; }

# cf <dns|access> <method> <path> [json]
cf() {
  local which=$1 m=$2 p=$3 body=${4:-} tok esc="" data=""
  case $which in dns) tok=${CLOUDFLARE_API_TOKEN-} ;; access) tok=${CLOUDFLARE_ACCESS_TOKEN-} ;; *) fail "internal" ;; esac
  [[ -n $tok ]] || fail "the $which token is not in the environment (run through homelab-bao run cloudflare-dns,cloudflare-access)"
  if [[ -n $body ]]; then
    esc=$(printf '%s' "$body" | jq -Rrs 'gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")')
    data=$(printf 'data-raw = "%s"\n' "$esc")
  fi
  printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\nrequest = "%s"\nurl = "%s/%s"\n%s\n' "$tok" "$m" "$CF_API" "$p" "$data" |
    curl -q -sS --fail --max-time 30 -K -
}

host_ok() {
  [[ ${1:-} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?\.$ZONE$ && $1 != *\** ]] || fail "access: <host> must be one exact name below $ZONE (no wildcard)"
}
setup() {
  need curl
  need jq
  [[ -n ${CLOUDFLARE_API_TOKEN-} ]] || fail "the dns token is not in the environment (run through homelab-bao run cloudflare-dns,cloudflare-access)"
  [[ -n ${CLOUDFLARE_ACCESS_TOKEN-} ]] || fail "the access token is not in the environment (run through homelab-bao run cloudflare-dns,cloudflare-access)"
  [[ -n ${CLOUDFLARE_ACCOUNT_ID:-} && $CLOUDFLARE_ACCOUNT_ID =~ ^[0-9a-f]{32}$ ]] || fail "CLOUDFLARE_ACCOUNT_ID is missing or has an unexpected form"
  ACC=accounts/$CLOUDFLARE_ACCOUNT_ID
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/cf-access.XXXXXX")
}
ZONE_ID=""
zone_id() {
  local a
  [[ -z $ZONE_ID ]] || return 0
  a=$(cf dns GET "zones?name=$ZONE") || fail "zone unreadable"
  ZONE_ID=$(jq -er '.result[0].id | select(type == "string" and test("^[0-9a-f]{32}$"))' <<<"$a") || fail "zone $ZONE not found"
}
AA=""
access_apps() {
  AA=$(cf access GET "$ACC/access/apps?per_page=1000") || fail "access applications unreadable"
  jq -e '.success == true and (.result | type == "array") and ((.result_info.total_pages // 1) <= 1)' >/dev/null <<<"$AA" || fail "access applications answer unsuccessful or paged"
}
# covering <host>: ids of the applications whose domain, self-hosted domains or destinations are the host or a wildcard covering it
covering() {
  jq -r --arg h "$1" '
    def dom: sub("/.*$"; "") | ascii_downcase;
    def covers($d): ($d == $h) or ($d | startswith("*.") and ($h | endswith($d | .[1:])));
    .result[] | select([(.domain // empty), (.self_hosted_domains // [])[], ((.destinations // [])[] | .uri // empty)] | map(dom) | any(covers(.)))
    | .id' <<<"$AA"
}
# own_app <host>: the id of the application named k3s-access-<host> whose domain is exactly the host (empty when absent)
own_app() {
  jq -r --arg n "k3s-access-$1" --arg h "$1" '[.result[] | select(.name == $n and .domain == $h) | .id] | if length == 1 then .[0] else empty end' <<<"$AA"
}
records_named() { # <name>: `<id> <type> <content>` lines
  local a
  zone_id
  a=$(cf dns GET "zones/$ZONE_ID/dns_records?name=$1") || fail "record list unreadable"
  jq -e '.success == true and (.result | type == "array")' >/dev/null <<<"$a" || fail "record list answer unsuccessful"
  jq -r --arg n "$1" '.result[] | select(.name == $n) | "\(.id) \(.type) \(.content)"' <<<"$a"
}

# routes_naming <host>: whether an opted-in route on main of the fixed endpoint names the host (0 = yes)
routes_naming() {
  local sha repo f hit=1 docs
  repo=$TMP/main.git
  if [[ ${HOMELAB_CF_TEST:-0} == 1 && -n ${HOMELAB_CF_REPO:-} ]]; then repo=$HOMELAB_CF_REPO; sha=$(git -C "$repo" rev-parse refs/heads/main) || fail "access-remove: the routes are unreadable"
  else
    need yq
    sha=$(git ls-remote "$ENDPOINT" refs/heads/main 2>/dev/null | awk '{print $1}' | head -1)
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || fail "access-remove: the routes are unreadable (endpoint)"
    git init -q --bare "$repo"
    git -C "$repo" fetch -q --no-tags "$ENDPOINT" "$sha" 2>/dev/null || fail "access-remove: the routes are unreadable (fetch)"
  fi
  need yq
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    docs=$(git -C "$repo" show "$sha:$f" | yq -o=json -I=0 '.' 2>/dev/null) || fail "access-remove: a route file is unreadable"
    if jq -e --arg h "$1" 'select(.kind == "HTTPRoute" and (.metadata.annotations // {} | has("homelab.io/public-dns")) and ((.spec.hostnames // []) | index($h)))' <<<"$docs" >/dev/null 2>&1; then hit=0; fi
  done < <(git -C "$repo" grep -lF 'homelab.io/public-dns' "$sha" -- apps networking 2>/dev/null | sed "s/^$sha://")
  return "$hit"
}

do_create() {
  local host=$1 dry=$2 cov aid rr body
  host_ok "$host"
  setup
  access_apps
  cov=$(covering "$host")
  if [[ -n $cov ]]; then
    aid=$(own_app "$host")
    if [[ -n $aid && $(grep -c . <<<"$cov") == 1 && $cov == "$aid" ]]; then echo "SKIP access $host exists (k3s-access-$host) id=$aid"; return 0; fi
    fail "access $host exists (an application covers it, exactly or by wildcard, and it is not k3s-access-$host); nothing changed"
  fi
  rr=$(records_named "$host")
  [[ -z $rr ]] || fail "access $host exists (the zone holds a record for it); nothing changed"
  [[ ${CLOUDFLARE_ACCESS_EMAIL:-} =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fail "access: CLOUDFLARE_ACCESS_EMAIL is missing or has an unexpected form"
  if [[ $dry == 1 ]]; then echo "PLAN create access application k3s-access-$host (self_hosted, inline allow policy for the login e-mail)"; return 0; fi
  body=$(printf '%s' "$CLOUDFLARE_ACCESS_EMAIL" | jq -Rc --arg n "k3s-access-$host" --arg h "$host" '{name: $n, domain: $h, type: "self_hosted", session_duration: "24h", policies: [{name: $n, decision: "allow", precedence: 1, include: [{email: {email: .}}]}]}')
  aid=$(cf access POST "$ACC/access/apps" "$body" | jq -er '.result.id | select(type == "string" and test("^[0-9a-f-]{32,36}$"))') || fail "access application create failed (the answer is not shown)"
  echo "OK   access application k3s-access-$host created id=$aid"
}

do_verify() {
  local host=$1 aid
  host_ok "$host"
  setup
  access_apps
  aid=$(own_app "$host")
  [[ -n $aid ]] || fail "access $host missing (no application k3s-access-$host with that exact domain)"
  echo "OK   access $host id=$aid"
}

# targets <host>: sets APP, CNAME_ID, TXT_IDS; only a single CNAME with an owner record of k3s-homelab is ever a target, any other record of the host stops the removal
targets() {
  local host=$1 all cname txt_all foreign other
  access_apps
  APP=$(own_app "$host")
  CNAME_ID="" TXT_IDS=()
  all=$(records_named "$host")
  other=$(awk '$2 != "CNAME"' <<<"$all")
  [[ -z $other ]] || fail "access-remove $host records remain (not a CNAME of the owner); nothing changed"
  cname=$(awk '$2 == "CNAME"' <<<"$all")
  txt_all=$(records_named "$TXT_PREFIX$host" | awk '$2 == "TXT"')
  local mine=()
  while read -r id _ _; do [[ -n $id ]] && mine+=("$id"); done < <(grep "external-dns/owner=${OWNER_ID}[,\"]" <<<"$txt_all" || true)
  if [[ -n $cname ]]; then
    [[ ${#mine[@]} -ge 1 && $(grep -c . <<<"$cname") == 1 ]] || fail "access-remove $host record not owned by $OWNER_ID; nothing changed"
    CNAME_ID=$(awk '{print $1}' <<<"$cname")
  fi
  TXT_IDS=("${mine[@]+"${mine[@]}"}")
  foreign=$(grep -vc "external-dns/owner=${OWNER_ID}[,\"]" <<<"$txt_all" || true)
  [[ ${foreign:-0} == 0 ]] || echo "SKIP foreign TXT $TXT_PREFIX$host (owner is not $OWNER_ID; left in place)"
}

do_remove() {
  local host=$1 dry=$2 confirm=$3 id
  host_ok "$host"
  setup
  if routes_naming "$host"; then fail "access-remove $host route present"; fi
  targets "$host"
  [[ -n $APP ]] || fail "access-remove $host no application k3s-access-$host with that exact domain; nothing changed"
  if [[ $dry == 1 ]]; then
    [[ -z $CNAME_ID ]] || echo "PLAN delete record $host id=$CNAME_ID"
    for id in ${TXT_IDS[@]+"${TXT_IDS[@]}"}; do echo "PLAN delete owner TXT $TXT_PREFIX$host id=$id"; done
    echo "PLAN delete access application k3s-access-$host id=$APP"
    echo "CONFIRM $APP"
    return 0
  fi
  [[ $confirm == "$APP" ]] || fail "access-remove $host confirm"
  zone_id
  [[ -z $CNAME_ID ]] || { cf dns DELETE "zones/$ZONE_ID/dns_records/$CNAME_ID" >/dev/null || fail "record delete failed"; echo "OK   record $host deleted id=$CNAME_ID"; }
  for id in ${TXT_IDS[@]+"${TXT_IDS[@]}"}; do
    cf dns DELETE "zones/$ZONE_ID/dns_records/$id" >/dev/null || fail "TXT delete failed"
    echo "OK   owner TXT $TXT_PREFIX$host deleted id=$id"
  done
  [[ -z $(records_named "$host") ]] || fail "access-remove $host records remain; the application is kept"
  cf access DELETE "$ACC/access/apps/$APP" >/dev/null || fail "access application delete failed"
  echo "OK   access application k3s-access-$host deleted id=$APP"
}

main() {
  local host="" dry=0 mode=create confirm=""
  [[ $# -ge 1 ]] || fail "usage: cf-access.sh <host> [--dry-run] | --verify <host> | --remove <host> (--dry-run | --confirm <app id>)"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) dry=1 ;;
      --verify) mode=verify; host=${2:-}; shift ;;
      --remove) mode=remove; host=${2:-}; shift ;;
      --confirm) confirm=${2:-}; shift ;;
      -*) fail "usage: cf-access.sh <host> [--dry-run] | --verify <host> | --remove <host> (--dry-run | --confirm <app id>)" ;;
      *) [[ -z $host ]] || fail "usage"; host=$1 ;;
    esac
    shift || true
  done
  [[ -n $host ]] || fail "usage: a host is needed"
  case $mode in
    create) do_create "$host" "$dry" ;;
    verify) do_verify "$host" ;;
    remove)
      [[ $dry == 1 || -n $confirm ]] || fail "access-remove $host needs --dry-run or --confirm <app id>"
      do_remove "$host" "$dry" "$confirm"
      ;;
  esac
}
main "$@"
