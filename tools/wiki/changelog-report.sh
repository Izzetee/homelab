#!/usr/bin/env bash
# changelog-report.sh (--since <YYYY-MM-DD> | --from-pr <n>) [--scan]
# Lists merged pull requests without a changelog entry (MISSING homelab#<n>) and entries that break the value-free rules (FAIL entry <doc id> <rule>).
set -euo pipefail
umask 077

GH_API=https://api.github.com
WIKI_URL=https://wiki.lan.chill-town.de
REPO=Izzetee/homelab
if [[ ${HOMELAB_REPORT_TEST:-0} == 1 ]]; then GH_API=${REPORT_GH_API:-$GH_API}; WIKI_URL=${REPORT_WIKI_URL:-$WIKI_URL}; fi
TMP=""
cleanup() { [[ -z $TMP ]] || rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
RC=0
fail() { echo "FAIL $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed"; }

# gh_get <url>
gh_get() {
  local cfg
  cfg=$(printf 'url = "%s"\nheader = "Accept: application/vnd.github+json"\n' "$1")
  if [[ -n ${GH_TOKEN-} ]]; then cfg+=$(printf '\nheader = "Authorization: Bearer %s"' "$GH_TOKEN"); fi
  printf '%s\n' "$cfg" | curl -q -sS --fail --max-time 30 -K -
}
# wiki_post <method> <json>
wiki_post() {
  local esc
  esc=$(printf '%s' "$2" | jq -Rrs 'gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")')
  printf 'url = "%s/api/%s"\nrequest = "POST"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\ndata-raw = "%s"\n' "$WIKI_URL" "$1" "$WIKI_TOKEN" "$esc" |
    curl -q -sS --fail --max-time 30 -K -
}

# collection_id <name>: id of the collection with that name (case-insensitive), empty when absent
collection_id() {
  local a
  a=$(wiki_post collections.list '{"limit":100}') || fail "wiki unreadable"
  jq -r --arg n "$1" '[.data[] | select((.name | ascii_downcase) == ($n | ascii_downcase)) | .id] | .[0] // empty' <<<"$a"
}
# docs_of <collection id>: JSON array of {id,title,text,updatedAt}, paged
docs_of() {
  local off=0 page all='[]' n
  while :; do
    page=$(wiki_post documents.list "$(jq -nc --arg c "$1" --argjson o "$off" '{collectionId: $c, limit: 100, offset: $o}')") || fail "wiki unreadable"
    n=$(jq '.data | length' <<<"$page")
    all=$(jq -c --argjson p "$(jq -c '.data' <<<"$page")" '. + $p' <<<"$all")
    [[ $n -ge 100 ]] || break
    off=$((off + 100))
  done
  printf '%s' "$all"
}

scan_host() { # scan_host <member name> <file>
  local name=$1 f=$2 d=$TMP/scan out
  [[ -n ${DOOR_SCAN_SSH_KEY:-} && -n ${DOOR_SCAN_TARGET:-} && -n ${DOOR_SCAN_KNOWN_HOST:-} ]] || fail "scan host: the door-scan entry is not in the environment"
  rm -rf "$d"
  mkdir -p "$d/tar/wiki"
  cp "$f" "$d/tar/$name"
  COPYFILE_DISABLE=1 tar -C "$d/tar" -cf "$d/in.tar" wiki
  printf '%s' "$DOOR_SCAN_SSH_KEY" | base64 -d >"$d/key" 2>/dev/null || fail "scan host: the key is not base64"
  printf '%s\n' "$DOOR_SCAN_KNOWN_HOST" >"$d/known"
  chmod 600 "$d/key" "$d/known"
  out=$(ssh -i "$d/key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$d/known" "$DOOR_SCAN_TARGET" <"$d/in.tar" 2>/dev/null) || true
  rm -rf "$d"
  if grep -qE '^OK scan files=1 patterns=[0-9]+$' <<<"$out" && ! grep -q '^FAIL ' <<<"$out"; then return 0; fi
  grep -E '^FAIL (scan|text) ' <<<"$out" || echo "FAIL scan host"
  return 1
}

main() {
  local since="" from_pr="" have_since=0 have_from=0 scan=0 prs entries pages ch_id ops_id n title count_prs=0 count_entries=0 missing=0 line id text
  while [[ $# -gt 0 ]]; do
    case $1 in
      --since) [[ -n ${2:-} && $have_since == 0 ]] || fail "usage: changelog-report.sh (--since <YYYY-MM-DD> | --from-pr <n>) [--scan]"; since=$2; have_since=1; shift ;;
      --from-pr) [[ -n ${2:-} && $have_from == 0 ]] || fail "usage: changelog-report.sh (--since <YYYY-MM-DD> | --from-pr <n>) [--scan]"; from_pr=$2; have_from=1; shift ;;
      --scan) scan=1 ;;
      *) fail "usage: changelog-report.sh (--since <YYYY-MM-DD> | --from-pr <n>) [--scan]" ;;
    esac
    shift || true
  done
  # exactly one window: a date, or a PR number (a day can hold PRs from before the changelog existed)
  if [[ $have_from == 1 ]]; then
    [[ $have_since == 0 && $from_pr =~ ^[0-9]{1,7}$ ]] || fail "usage: changelog-report.sh (--since <YYYY-MM-DD> | --from-pr <n>) [--scan]"
  else
    [[ $have_since == 1 && $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "usage: changelog-report.sh (--since <YYYY-MM-DD> | --from-pr <n>) [--scan]"
  fi
  need curl
  need jq
  [[ -n ${WIKI_TOKEN-} ]] || fail "WIKI_TOKEN is not in the environment (run through homelab-bao run wiki-pi)"
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/changelog-report.XXXXXX")

  # merged pull requests since the date (closed, base main, merged_at set), at most five pages of 100
  prs="[]"
  for page in 1 2 3 4 5; do
    n=$(gh_get "$GH_API/repos/$REPO/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100&page=$page") || fail "github unreadable"
    prs=$(jq -c --argjson p "$(jq -c '[.[] | select(.merged_at != null) | {number, title, merged_at}]' <<<"$n")" '. + $p' <<<"$prs")
    [[ $(jq 'length' <<<"$n") -ge 100 ]] || break
  done
  if [[ -n $from_pr ]]; then
    prs=$(jq -c --argjson f "$from_pr" '[.[] | select(.number >= $f)] | unique_by(.number) | sort_by(.number)' <<<"$prs")
    # the page scan below starts on the day of the first PR of the window
    since=$(jq -r '.[0].merged_at[0:10] // empty' <<<"$prs")
    [[ -n $since ]] || fail "no merged pull request from #$from_pr"
  else
    prs=$(jq -c --arg s "$since" '[.[] | select(.merged_at[0:10] >= $s)] | unique_by(.number) | sort_by(.number)' <<<"$prs")
  fi
  count_prs=$(jq 'length' <<<"$prs")

  ch_id=$(collection_id Changelog)
  [[ -n $ch_id ]] || fail "the collection Changelog does not exist"
  entries=$(docs_of "$ch_id")
  count_entries=$(jq 'length' <<<"$entries")

  # one entry per merged pull request: the title carries `homelab#<n>:`
  while IFS=$'\t' read -r n title; do
    [[ -n $n ]] || continue
    if [[ $(jq --arg k "homelab#$n:" '[.[] | select(.title | contains($k))] | length' <<<"$entries") == 0 ]]; then
      echo "MISSING homelab#$n $(printf '%s' "$title" | tr -c 'A-Za-z0-9 ._:#/()+,-' '?' | cut -c1-80)"
      missing=$((missing + 1))
      RC=1
    fi
  done < <(jq -r '.[] | [.number, .title] | @tsv' <<<"$prs")

  # rules on every entry
  while IFS=$'\t' read -r id _; do
    [[ -n $id ]] || continue
    text=$(jq -r --arg i "$id" '.[] | select(.id == $i) | .title + "\n" + .text' <<<"$entries")
    if grep -qE '(^|[^0-9A-Fa-f])[0-9A-Fa-f]{12}($|[^0-9A-Fa-f])' <<<"$text"; then echo "FAIL entry $(printf '%s' "$id" | tr -c 'A-Za-z0-9-' '?') fingerprint"; RC=1; fi
    if grep -qE '[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]@]+@' <<<"$text"; then echo "FAIL entry $(printf '%s' "$id" | tr -c 'A-Za-z0-9-' '?') userinfo"; RC=1; fi
  done < <(jq -r '.[] | [.id] | @tsv' <<<"$entries")

  if [[ $scan == 1 ]]; then
    ops_id=$(collection_id Operations)
    pages=$(jq -c --arg s "$since" '[.[] | select(.updatedAt[0:10] >= $s)]' <<<"$entries")
    if [[ -n $ops_id ]]; then pages=$(jq -c --arg s "$since" --argjson o "$(docs_of "$ops_id")" '. + [$o[] | select(.updatedAt[0:10] >= $s)]' <<<"$pages"); fi
    while IFS= read -r id; do
      [[ $id =~ ^[A-Za-z0-9-]{1,64}$ ]] || { echo "FAIL scan page id"; RC=1; continue; }
      jq -r --arg i "$id" '.[] | select(.id == $i) | .title + "\n\n" + .text' <<<"$pages" >"$TMP/page.txt"
      if ! line=$(scan_host "wiki/$id" "$TMP/page.txt"); then
        echo "$line"
        RC=1
      fi
    done < <(jq -r '.[].id' <<<"$pages")
  fi

  if [[ $RC == 0 ]]; then echo "OK changelog prs=$count_prs entries=$count_entries missing=0"; else echo "FAIL changelog prs=$count_prs entries=$count_entries missing=$missing"; fi
  return "$RC"
}
main "$@"
