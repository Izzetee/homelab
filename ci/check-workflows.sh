#!/usr/bin/env bash
# Workflow hygiene check: GitHub-hosted runners only, safe triggers, least privilege, no artifacts or
# caches (public repo: both are public), actions pinned to a full commit SHA, container and docker:// images and
# tool images pinned by digest, no untrusted interpolation in run:.
#   ci/check-workflows.sh [file ...]      default .github/workflows/*.yml and *.yaml
# Prints `FAIL workflow <file> <rule>` per finding and `OK workflows files=<n>`; exit 1 on any FAIL.
# YQ=<command> runs a local yq instead of the pinned image (tests, local use).
set -euo pipefail

YQ_IMAGE=docker.io/mikefarah/yq:4.54.3@sha256:7834187596ad56fd5a81436114e0b0b9dd54c91bb43946d1f7145b2be5f9c3d2
yq_json() {
  if [[ -n ${YQ:-} ]]; then
    # shellcheck disable=SC2086 # YQ is a command line on purpose
    $YQ -o=json '.' -
  else
    docker run --rm -i "$YQ_IMAGE" -o=json '.' -
  fi
}

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [[ -f $f ]] && files+=("$f")
  done
fi
if [[ ${#files[@]} -eq 0 ]]; then
  echo "SKIP workflows no files"
  exit 0
fi

fail=0
for f in "${files[@]}"; do
  wf=$f
  out=$(yq_json <"$wf" | python3 -c '
import json, re, sys

name = sys.argv[1]
doc = json.load(sys.stdin)
bad = []
if not isinstance(doc, dict):
    print("FAIL workflow %s not a mapping" % name)
    sys.exit(1)

ALLOWED_RUNNER = "ubuntu-24.04"
ALLOWED_TRIGGERS = {"pull_request", "push", "schedule", "workflow_dispatch"}
FORBIDDEN_USES = ("actions/upload-artifact", "actions/download-artifact", "actions/cache")
VALUE_OPTS = {"-v", "--volume", "-w", "--workdir", "-e", "--env", "--env-file", "-u", "--user", "--name",
              "--network", "-p", "--publish", "--platform", "--entrypoint", "--mount", "-a", "--add-host",
              "--cap-add", "--cap-drop", "--security-opt", "--tmpfs", "--pull", "-l", "--label", "-h", "--hostname"}


def walk(o):
    yield o
    if isinstance(o, dict):
        for v in o.values():
            yield from walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v)


# triggers: only pull_request, push, schedule, workflow_dispatch (never pull_request_target / workflow_run)
on = doc.get("on", doc.get(True))
trig = [on] if isinstance(on, str) else (on if isinstance(on, list) else list((on or {}).keys()))
for t in trig:
    if t in ("pull_request_target", "workflow_run"):
        bad.append("trigger " + t)
    elif t not in ALLOWED_TRIGGERS:
        bad.append("trigger " + str(t) + " not allowed")

# runners
for o in walk(doc):
    if isinstance(o, dict) and "runs-on" in o and o["runs-on"] != ALLOWED_RUNNER:
        bad.append("runs-on not " + ALLOWED_RUNNER)

# permissions: {} on top; read or none per scope everywhere
if doc.get("permissions") != {}:
    bad.append("top-level permissions must be {}")
perms = [doc.get("permissions")] + [j.get("permissions") for j in (doc.get("jobs") or {}).values() if isinstance(j, dict)]
for p in perms:
    if p is None:
        continue
    if not isinstance(p, dict):
        bad.append("permissions " + str(p))
    else:
        for scope, v in p.items():
            if v not in ("read", "none"):
                bad.append("permissions %s: %s" % (scope, v))

# artifacts, caches, pinning of actions and container images, untrusted interpolation, docker run images
for o in walk(doc):
    if not isinstance(o, dict):
        continue
    uses = o.get("uses")
    if isinstance(uses, str) and uses.lower().startswith(FORBIDDEN_USES):
        bad.append("uses " + uses.split("@")[0])
    if isinstance(uses, str) and not uses.startswith("./"):
        if uses.startswith("docker://"):
            if not re.search(r"@sha256:[0-9a-f]{64}$", uses):
                bad.append("docker:// image not digest-pinned")
        elif not re.search(r"@[0-9a-f]{40}$", uses):
            bad.append("uses not pinned to a full commit SHA")
    for key in ("container",):
        c = o.get(key)
        img = c.get("image") if isinstance(c, dict) else c
        if key in o and isinstance(img, str) and not re.search(r"@sha256:[0-9a-f]{64}$", img):
            bad.append("container image not digest-pinned")
    if isinstance(o.get("services"), dict):
        for svc in o["services"].values():
            img = svc.get("image") if isinstance(svc, dict) else None
            if isinstance(img, str) and not re.search(r"@sha256:[0-9a-f]{64}$", img):
                bad.append("service image not digest-pinned")
    w = o.get("with")
    if isinstance(w, dict) and "cache" in w:
        bad.append("cache input")
    run = o.get("run")
    if isinstance(run, str):
        if re.search(r"\$\{\{[^}]*github\.(event|head_ref)", run):
            bad.append("untrusted interpolation in run")
        text = run.replace("\\\n", " ")
        for line in text.split("\n"):
            toks = line.split()
            for i, t in enumerate(toks):
                if t == "run" and i > 0 and toks[i - 1] == "docker":
                    j = i + 1
                    while j < len(toks) and toks[j].startswith("-"):
                        j += 2 if (toks[j] in VALUE_OPTS) else 1
                    img = toks[j].strip("\"\x27") if j < len(toks) else ""
                    if not re.search(r"@sha256:[0-9a-f]{64}$", img):
                        bad.append("docker run image not digest-pinned")
for b in sorted(set(bad)):
    print("FAIL workflow %s %s" % (name, b))
sys.exit(1 if bad else 0)
' "$f") || { echo "$out"; fail=1; continue; }
done
[[ $fail == 0 ]] || exit 1
echo "OK workflows files=${#files[@]}"
