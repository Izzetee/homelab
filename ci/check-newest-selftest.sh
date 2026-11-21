#!/usr/bin/env bash
# Offline self-test of ci/check-newest.sh --filter on fixtures cut from real Renovate reports (ci/testdata/newest/: extract.json from
# --dry-run=extract, lookup.json from --dry-run=lookup, trimmed to a few dependencies). No container, no network.
#   ci/check-newest-selftest.sh      prints `ok ...` per case and `OK newest-selftest cases=<n>`; exit 1 on any failure
set -euo pipefail
cd "$(dirname "$0")/.."
CHK=ci/check-newest.sh
FX=ci/testdata/newest
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cases=0
fails=0
ok() { cases=$((cases + 1)); echo "ok   $1"; }
bad() { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }

# clone <json-in> <manager> <dep name> <new file> <json-out>: a copy of the file entry that holds the dep, under a new file name
clone() {
  jq --arg m "$2" --arg d "$3" --arg f "$4" \
    '.repositories.local.packageFiles[$m] += [ .repositories.local.packageFiles[$m][] | select(any(.deps[]; .depName == $d)) | (.packageFile = $f) | (.deps |= map(select(.depName == $d))) ]' "$1" >"$5"
}
# the registry's answer for the digest pins of the fixtures: tag -> digest (what resolve_digest would print)
DG_OK='{"docker.io/cloudflare/cloudflared:2026.11.1": "sha256:e613aadbc2d9511785d2e67a86b0c8ac18dd63a3f9af0d06faf04cbfdcb35f2d"}'
run() { # run <head extract> <lookup> [<digests json>]: new + result as the script runs them; sets out, rc
  rc=0
  printf '%s' "${3:-$DG_OK}" >"$tmp/dg.json"
  out=$("$CHK" --filter new "$FX/extract.json" "$1" "$tmp/new.json") || rc=$?
  if [[ -s $tmp/new.json ]]; then
    out=$("$CHK" --filter result "$tmp/new.json" "$2" "$tmp/dg.json") || rc=$?
  fi
  rm -f "$tmp/new.json"
}
has() { grep -qxF -- "$1" <<<"$out"; }
expect() { # expect <label> <rc> <exact line>...
  local label=$1 want=$2 l okk=1
  shift 2
  [[ $rc == "$want" ]] || okk=0
  for l in "$@"; do has "$l" || okk=0; done
  if [[ $okk == 1 ]]; then ok "$label"; else bad "$label: rc=$rc ${out//$'\n'/ ; }"; fi
}

# 1. nothing new
run "$FX/extract.json" "$FX/lookup.json"
expect "head equals base: SKIP, exit 0, no lookup needed" 0 "SKIP newest no new dependencies"

# 2. new current dependency with a positive lookup
clone "$FX/extract.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/a.yaml "$tmp/h.json"
clone "$FX/lookup.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/a.yaml "$tmp/l.json"
run "$tmp/h.json" "$tmp/l.json"
expect "new current pin with a positive lookup: OK, exit 0" 0 "OK newest apps/tools/new/a.yaml docker.io/cloudflare/cloudflared 2026.11.1" "RESULT newest new=1 fail=0 warn=0"

# 3. new outdated pin
clone "$FX/extract.json" argocd kube-prometheus-stack apps/_argocd/new.yaml "$tmp/h.json"
clone "$FX/lookup.json" argocd kube-prometheus-stack apps/_argocd/new.yaml "$tmp/l.json"
run "$tmp/h.json" "$tmp/l.json"
expect "new outdated pin: FAIL with the newest, exit 1" 1 "FAIL newest apps/_argocd/new.yaml kube-prometheus-stack 93.4.0 -> 93.6.1 minor" "RESULT newest new=1 fail=1 warn=0"

# 4. newer digest of the same tag
clone "$FX/extract.json" kubernetes ghcr.io/open-webui/open-terminal apps/tools/new/b.yaml "$tmp/h.json"
clone "$FX/lookup.json" kubernetes ghcr.io/open-webui/open-terminal apps/tools/new/b.yaml "$tmp/l.json"
run "$tmp/h.json" "$tmp/l.json"
expect "newer digest of the same tag: FAIL, exit 1" 1 "FAIL newest apps/tools/new/b.yaml ghcr.io/open-webui/open-terminal latest -> latest digest"

# 5. held newer version is listed (holds are not read by the filter; the lookup ran without them)
clone "$FX/extract.json" kubernetes docker.io/n8nio/n8n apps/tools/new/c.yaml "$tmp/h.json"
clone "$FX/lookup.json" kubernetes docker.io/n8nio/n8n apps/tools/new/c.yaml "$tmp/l.json"
run "$tmp/h.json" "$tmp/l.json"
expect "held newer version (n8n 3.x) listed: FAIL, exit 1" 1 "FAIL newest apps/tools/new/c.yaml docker.io/n8nio/n8n 2.48.7 -> 3.3.0 major"

# 6. only existing dependencies changed
jq '(.repositories.local.packageFiles.kubernetes[] | select(.packageFile == "apps/platform/cloudflared/deployment.yaml") | .deps[0].currentValue) = "2026.1.0"' "$FX/extract.json" >"$tmp/h.json"
run "$tmp/h.json" "$FX/lookup.json"
expect "only an existing dependency changed: SKIP, exit 0" 0 "SKIP newest no new dependencies"

# 7. lookup warning
clone "$FX/extract.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/d.yaml "$tmp/h.json"
clone "$FX/lookup.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/d.yaml "$tmp/l.json"
jq '(.repositories.local.packageFiles.kubernetes[] | select(.packageFile == "apps/tools/new/d.yaml") | .deps[0].warnings) = [{topic: "x", message: "lookup failed"}]' "$tmp/l.json" >"$tmp/l2.json"
run "$tmp/h.json" "$tmp/l2.json"
expect "lookup warning: WARN lookup (never OK), exit 1" 1 "WARN newest apps/tools/new/d.yaml docker.io/cloudflare/cloudflared lookup" "RESULT newest new=1 fail=0 warn=1"

# 8. new dependency missing from the lookup report
run "$tmp/h.json" "$FX/lookup.json"
expect "new dependency missing from the lookup report: WARN unresolved, exit 1" 1 "WARN newest apps/tools/new/d.yaml docker.io/cloudflare/cloudflared unresolved"

# 9. skipReason: disabled runner label and a GitHub pin without a token
jq '.repositories.local.packageFiles["github-actions"] |= map(.packageFile = ".github/workflows/new.yml")' "$FX/extract.json" >"$tmp/h0.json"
jq -s '.[0].repositories.local.packageFiles["github-actions"] += .[1].repositories.local.packageFiles["github-actions"] | .[0]' "$FX/extract.json" "$tmp/h0.json" >"$tmp/h.json"
jq '.repositories.local.packageFiles["github-actions"] |= map(.packageFile = ".github/workflows/new.yml")' "$FX/lookup.json" >"$tmp/l0.json"
run "$tmp/h.json" "$tmp/l0.json"
expect "skipReason disabled and github-token-required: WARN unresolved each, exit 1" 1 \
  "WARN newest .github/workflows/new.yml ubuntu unresolved" "WARN newest .github/workflows/new.yml actions/checkout unresolved" "RESULT newest new=2 fail=0 warn=2"

# 10. current version unresolved without an update (floating tag)
clone "$FX/extract.json" kubernetes docker.io/excalidraw/excalidraw apps/tools/new/e.yaml "$tmp/h.json"
clone "$FX/lookup.json" kubernetes docker.io/excalidraw/excalidraw apps/tools/new/e.yaml "$tmp/l.json"
run "$tmp/h.json" "$tmp/l.json"
expect "floating tag, version unresolved and no update: WARN unresolved, never OK" 1 "WARN newest apps/tools/new/e.yaml docker.io/excalidraw/excalidraw unresolved"
if has "OK newest apps/tools/new/e.yaml docker.io/excalidraw/excalidraw latest"; then bad "OK for an unresolved pin"; else ok "no OK line for the unresolved pin"; fi

# 11. a positive-looking record without the datasource's answer (no registryUrl) is not OK
clone "$FX/extract.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/f.yaml "$tmp/h.json"
clone "$FX/lookup.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/f.yaml "$tmp/l.json"
jq '(.repositories.local.packageFiles.kubernetes[] | select(.packageFile == "apps/tools/new/f.yaml") | .deps[0]) |= del(.registryUrl)' "$tmp/l.json" >"$tmp/l2.json"
run "$tmp/h.json" "$tmp/l2.json"
expect "no datasource answer (registryUrl absent): WARN unresolved" 1 "WARN newest apps/tools/new/f.yaml docker.io/cloudflare/cloudflared unresolved"

# 12. a moved file counts as new
jq '(.repositories.local.packageFiles.kubernetes[] | select(.packageFile == "apps/platform/cloudflared/deployment.yaml") | .packageFile) = "apps/platform/tunnel/deployment.yaml"' "$FX/extract.json" >"$tmp/h.json"
jq '(.repositories.local.packageFiles.kubernetes[] | select(.packageFile == "apps/platform/cloudflared/deployment.yaml") | .packageFile) = "apps/platform/tunnel/deployment.yaml"' "$FX/lookup.json" >"$tmp/l.json"
run "$tmp/h.json" "$tmp/l.json"
expect "moved file: counted as new, OK on the new path" 0 "OK newest apps/platform/tunnel/deployment.yaml docker.io/cloudflare/cloudflared 2026.11.1"

# 13. pins that are no upstream version never count: own branch, API kinds
clone "$FX/extract.json" argocd https://github.com/Izzetee/homelab.git apps/_argocd/other.yaml "$tmp/h.json"
run "$tmp/h.json" "$FX/lookup.json"
expect "a new Application's own-branch source is not a dependency: SKIP" 0 "SKIP newest no new dependencies"
clone "$FX/extract.json" kubernetes CronJob apps/tools/new/g.yaml "$tmp/h.json"
run "$tmp/h.json" "$FX/lookup.json"
expect "a new Kubernetes API kind is not a dependency: SKIP" 0 "SKIP newest no new dependencies"

# 14. names from the PR are sanitised: one line per finding, no workflow command at a line start
clone "$FX/extract.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/h.yaml "$tmp/h.json"
clone "$FX/lookup.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/h.yaml "$tmp/l.json"
bad_name=$'evil\n::error::boom'
jq --arg n "$bad_name" '(.repositories.local.packageFiles.kubernetes[] | select(.packageFile == "apps/tools/new/h.yaml") | .deps[0].depName) = $n' "$tmp/h.json" >"$tmp/h2.json"
jq --arg n "$bad_name" '(.repositories.local.packageFiles.kubernetes[] | select(.packageFile == "apps/tools/new/h.yaml") | .deps[0].depName) = $n' "$tmp/l.json" >"$tmp/l2.json"
run "$tmp/h2.json" "$tmp/l2.json"
if [[ $(wc -l <<<"$out") -eq 2 ]] && ! grep -q '^::' <<<"$out"; then ok "hostile dependency name stays on one line"; else bad "hostile name: ${out//$'\n'/ ; }"; fi

# 15. report-level problems are a WARN, usage errors exit 2
jq '.problems = [{message: "x"}]' "$tmp/l.json" >"$tmp/l2.json"
run "$tmp/h.json" "$tmp/l2.json"
if [[ $out == *"lookup problems=1"* && $rc == 1 ]]; then ok "report problems: WARN, exit 1"; else bad "problems: rc=$rc $out"; fi
# 16. a digest pin needs the registry's confirmation: missing or different digest is a WARN, never OK
clone "$FX/extract.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/i.yaml "$tmp/h.json"
clone "$FX/lookup.json" kubernetes docker.io/cloudflare/cloudflared apps/tools/new/i.yaml "$tmp/l.json"
run "$tmp/h.json" "$tmp/l.json" '{}'
expect "digest pin, version resolved but no registry digest: WARN digest, exit 1" 1 "WARN newest apps/tools/new/i.yaml docker.io/cloudflare/cloudflared digest"
run "$tmp/h.json" "$tmp/l.json" '{"docker.io/cloudflare/cloudflared:2026.11.1": "sha256:0000000000000000000000000000000000000000000000000000000000000000"}'
expect "digest pin, registry maps the tag to another digest: WARN digest, exit 1" 1 "WARN newest apps/tools/new/i.yaml docker.io/cloudflare/cloudflared digest"
if has "OK newest apps/tools/new/i.yaml docker.io/cloudflare/cloudflared 2026.11.1"; then bad "OK without digest evidence"; else ok "no OK line without digest evidence"; fi
"$CHK" --filter new "$FX/extract.json" "$tmp/h.json" "$tmp/new.json" >/dev/null
refs=$("$CHK" --filter digests "$tmp/new.json" "$tmp/l.json")
if [[ $refs == "docker.io/cloudflare/cloudflared:2026.11.1" ]]; then ok "digests filter lists the ref the registry must confirm"; else bad "digests filter: $refs"; fi
rm -f "$tmp/new.json"

# 17. a failed report as a whole gives no OK for any pin; a listed update stays a FAIL
jq '.problems = [{message: "x"}]' "$tmp/l.json" >"$tmp/l2.json"
run "$tmp/h.json" "$tmp/l2.json"
expect "report problems with a positive pin: WARN lookup for the pin, no OK, exit 1" 1 "WARN newest apps/tools/new/i.yaml docker.io/cloudflare/cloudflared lookup" "WARN newest - - lookup problems=1"
if has "OK newest apps/tools/new/i.yaml docker.io/cloudflare/cloudflared 2026.11.1"; then bad "OK despite a failed report"; else ok "no OK line when the report failed"; fi
clone "$FX/extract.json" argocd kube-prometheus-stack apps/_argocd/new2.yaml "$tmp/h3.json"
clone "$FX/lookup.json" argocd kube-prometheus-stack apps/_argocd/new2.yaml "$tmp/l3.json"
jq '.problems = [{message: "x"}]' "$tmp/l3.json" >"$tmp/l4.json"
run "$tmp/h3.json" "$tmp/l4.json"
expect "report problems with a listed update: still FAIL" 1 "FAIL newest apps/_argocd/new2.yaml kube-prometheus-stack 93.4.0 -> 93.6.1 minor"

rc=0
"$CHK" --filter bogus >/dev/null 2>&1 || rc=$?
if [[ $rc == 2 ]]; then ok "unknown filter mode: exit 2"; else bad "usage rc=$rc"; fi
rc=0
"$CHK" >/dev/null 2>&1 || rc=$?
if [[ $rc == 2 ]]; then ok "no argument: usage, exit 2"; else bad "usage no arg rc=$rc"; fi

if [[ $fails -eq 0 ]]; then
  echo "OK newest-selftest cases=$cases"
else
  echo "FAIL newest-selftest failures=$fails cases=$cases"
  exit 1
fi
