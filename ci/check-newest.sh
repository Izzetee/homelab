#!/usr/bin/env bash
# Newest-release check for new dependencies (read-only, no token, no secret).
#   ci/check-newest.sh <base-ref> [<head-ref>]   head defaults to HEAD
#   ci/check-newest.sh --filter new <base-extract.json> <head-extract.json> <new.json>
#   ci/check-newest.sh --filter digests <new.json> <lookup.json>          refs (name:tag) of digest pins that need registry evidence
#   ci/check-newest.sh --filter result <new.json> <lookup.json> [<digests.json>]
# The first form extracts the dependencies of both trees with the Renovate image of the `lint` job (no network), and only when the
# head adds dependencies looks them up against the newest stable upstream release, ignoring this repository's holds, release-age wait
# and dashboard approvals (a rule appended in a temporary copy of the head tree only). Output, one line each:
#   OK newest <file> <dep> <current>            positive lookup, no newer release (a digest pin also needs its tag's digest read from the registry)
#   FAIL newest <file> <dep> <current> -> <newest> <type>
#   WARN newest <file> <dep> lookup|unresolved|digest  lookup warning or report failure, skipped, disabled, inconclusive or digest not
#                                               confirmed (needs a manual lookup)
#   SKIP newest no new dependencies
#   RESULT newest new=<n> fail=<f> warn=<w>     exit 1 on any FAIL or WARN
# CONTAINER=podman runs the same image with podman. Names and versions printed are sanitised; no value ever leaves the script.
set -euo pipefail

FILTER=$(
  cat <<'PY'
import json, re, sys

IGNORE_SKIP = {"local"}
VERSIONISH = re.compile(r"^v?\d")


def safe(s):
    return re.sub(r"[^A-Za-z0-9._/@:+-]", "?", str(s))[:120]


def deps(path):
    """(file, dep) -> [dep records] of a report, without the pins that are no upstream version (own branch, API kinds, local modules)"""
    with open(path, encoding="utf-8") as fh:
        rep = json.load(fh)
    out = {}
    for _mgr, files in ((rep.get("repositories") or {}).get("local") or {}).get("packageFiles", {}).items():
        for f in files:
            for d in f.get("deps") or []:
                ds, cv = d.get("datasource"), str(d.get("currentValue") or "")
                if ds == "kubernetes-api" or d.get("skipReason") in IGNORE_SKIP or not d.get("depName"):
                    continue
                if ds == "git-tags" and not VERSIONISH.match(cv):
                    continue
                out.setdefault((f.get("packageFile", "?"), d["depName"]), []).append(d)
    return out


def cmd_new(base, head, out):
    b, h = deps(base), deps(head)
    new = sorted(k for k in h if k not in b)
    if not new:
        print("SKIP newest no new dependencies")
        return 0
    with open(out, "w", encoding="utf-8") as fh:
        json.dump([list(k) for k in new], fh)
    print(f"NEW newest {len(new)}")
    return 0


def positive(d):
    # the datasource answered (registryUrl), the current version resolved, nothing skipped or warned
    return bool(d.get("registryUrl")) and d.get("currentVersion") is not None and not d.get("skipReason") and not d.get("warnings")


def digest_pin(d):
    return d.get("datasource") == "docker" and str(d.get("currentDigest") or "").startswith("sha256:")


def candidate(d):
    return positive(d) and not [u for u in d.get("updates") or [] if isinstance(u, dict)]


def cmd_digests(newf, lookup):
    """name:tag refs of the new digest pins that would be OK: the registry must confirm that the tag still points at the pinned digest"""
    with open(newf, encoding="utf-8") as fh:
        new = [tuple(k) for k in json.load(fh)]
    found = deps(lookup)
    refs = []
    for k in new:
        for d in found.get(k) or []:
            ref = f"{d['depName']}:{d.get('currentValue') or ''}"
            if digest_pin(d) and candidate(d) and re.fullmatch(r"[a-z0-9][a-z0-9./_-]*:[A-Za-z0-9_][A-Za-z0-9._-]*", ref) and ref not in refs:
                refs.append(ref)
    print("\n".join(refs))
    return 0


def cmd_result(newf, lookup, digests=None):
    with open(newf, encoding="utf-8") as fh:
        new = [tuple(k) for k in json.load(fh)]
    with open(lookup, encoding="utf-8") as fh:
        rep = json.load(fh)
    # a lookup that failed for the whole repository is no answer for any dependency
    problems = len((rep.get("problems") or []))
    found = deps(lookup)
    confirmed = {}
    if digests:
        with open(digests, encoding="utf-8") as fh:
            confirmed = json.load(fh)
    lines, nfail, nwarn = [], 0, 0

    def add(kind, text):
        nonlocal nfail, nwarn
        line = f"{kind} newest {text}"
        if line in lines:
            return
        lines.append(line)
        nfail += kind == "FAIL"
        nwarn += kind == "WARN"

    for f, name in new:
        recs = found.get((f, name))
        sf, sn = safe(f), safe(name)
        if not recs:
            add("WARN", f"{sf} {sn} unresolved")
            continue
        for d in recs:
            cur = safe(d.get("currentValue") or d.get("currentDigest") or "-")
            ups = [u for u in d.get("updates") or [] if isinstance(u, dict)]
            if d.get("skipReason"):
                add("WARN", f"{sf} {sn} unresolved")
            elif d.get("warnings"):
                add("WARN", f"{sf} {sn} lookup")
            elif ups:
                for u in ups:
                    newest = safe(u.get("newValue") or u.get("newVersion") or u.get("newDigest") or "?")
                    add("FAIL", f"{sf} {sn} {cur} -> {newest} {safe(u.get('updateType') or '?')}")
            elif positive(d) and problems:
                add("WARN", f"{sf} {sn} lookup")  # a report that failed as a whole proves nothing for a single pin
            elif positive(d) and digest_pin(d) and confirmed.get(f"{d['depName']}:{d.get('currentValue') or ''}") != d.get("currentDigest"):
                add("WARN", f"{sf} {sn} digest")
            elif positive(d):
                add("OK", f"{sf} {sn} {cur}")
            else:
                add("WARN", f"{sf} {sn} unresolved")
    if problems:
        add("WARN", f"- - lookup problems={problems}")
    print("\n".join(lines))
    print(f"RESULT newest new={len(new)} fail={nfail} warn={nwarn}")
    return 1 if nfail or nwarn else 0


a = sys.argv[1:]
if a[:1] == ["new"] and len(a) == 4:
    sys.exit(cmd_new(*a[1:]))
if a[:1] == ["digests"] and len(a) == 3:
    sys.exit(cmd_digests(*a[1:]))
if a[:1] == ["result"] and len(a) in (3, 4):
    sys.exit(cmd_result(*a[1:]))
print("FAIL newest filter usage")
sys.exit(2)
PY
)

if [[ ${1:-} == --filter ]]; then
  [[ $# -ge 2 ]] || { echo "FAIL newest usage"; exit 2; }
  exec python3 -c "$FILTER" "${@:2}"
fi

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: ci/check-newest.sh <base-ref> [<head-ref>]"; exit 2; }
base=$1 head=${2:-HEAD}
cd "$(dirname "$0")/.."
CONTAINER=${CONTAINER:-docker}

# the same Renovate pin as the validator step of the `lint` job: one place to bump
pin=$(grep -oE 'ghcr\.io/renovatebot/renovate:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}' .github/workflows/ci.yml | head -n 1 || true)
[[ -n $pin ]] || { echo "FAIL newest renovate pin not found in the workflow"; exit 1; }
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "FAIL newest base ref unknown"; exit 1; }
git rev-parse --verify --quiet "$head^{commit}" >/dev/null || { echo "FAIL newest head ref unknown"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/base" "$tmp/head" "$tmp/lookup" "$tmp/out"
git archive "$base" | tar -x -C "$tmp/base"
git archive "$head" | tar -x -C "$tmp/head"

# no -e, --env-file or socket: the container gets neither a variable nor the host's daemon; trees are read-only, only /out is writable
run_renovate() { # run_renovate <mode> <network: none|default> <tree> <name>
  local net=() user=(--user "$(id -u):$(id -g)")
  [[ $2 == none ]] && net=(--network none)
  [[ $CONTAINER == podman* ]] && user+=(--userns=keep-id)
  "$CONTAINER" run --rm "${user[@]}" "${net[@]}" -v "$3:/repo:ro" -v "$tmp/out:/out" -w /repo "$pin" \
    --platform=local --dry-run="$1" --onboarding=false --require-config=optional \
    --base-dir="/out/$4-dir" --report-type=file --report-path="/out/$4.json" >"$tmp/$4.log" 2>&1 ||
    { echo "FAIL newest renovate $1 run failed ($4)"; exit 1; }
}

run_renovate extract none "$tmp/base" base
run_renovate extract none "$tmp/head" head
"$0" --filter new "$tmp/out/base.json" "$tmp/out/head.json" "$tmp/new.json"
[[ -s $tmp/new.json ]] || exit 0

# hold-free lookup: the head tree plus one last rule that lifts version limits, the release-age wait and dashboard approvals
cp -R "$tmp/head/." "$tmp/lookup/"
jq '.packageRules = ((.packageRules // []) + [{matchPackageNames: ["*"], allowedVersions: "/.*/", minimumReleaseAge: null, dependencyDashboardApproval: false}])' \
  "$tmp/head/renovate.json" >"$tmp/lookup/renovate.json"
run_renovate lookup default "$tmp/lookup" lookup

# a digest pin is OK only when the registry still maps its tag to the pinned digest (the report has no digest evidence of its own)
resolve_digest() { # resolve_digest <name:tag>: prints the digest or nothing; DIGEST_CMD overrides (tests, podman)
  if [[ -n ${DIGEST_CMD:-} ]]; then "$DIGEST_CMD" "$1" 2>/dev/null || true; else docker buildx imagetools inspect "$1" 2>/dev/null | awk '/^Digest:/ {print $2; exit}' || true; fi
}
"$0" --filter digests "$tmp/new.json" "$tmp/out/lookup.json" >"$tmp/refs.txt"
: >"$tmp/digests.tsv"
while IFS= read -r ref; do
  [[ -n $ref ]] || continue
  printf '%s\t%s\n' "$ref" "$(resolve_digest "$ref")" >>"$tmp/digests.tsv"
done <"$tmp/refs.txt"
jq -Rn '[inputs | split("\t") | select(length == 2) | {(.[0]): .[1]}] | add // {}' "$tmp/digests.tsv" >"$tmp/digests.json"
"$0" --filter result "$tmp/new.json" "$tmp/out/lookup.json" "$tmp/digests.json"
