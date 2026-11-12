#!/usr/bin/env bash
# Self-test of ci/render-argocd-helm.sh with a stub helm (offline): the helm command line ArgoCD would run, the
# refusals, and that an unpinned image in a rendered chart reaches the image check and fails it.
#   ci/render-argocd-helm-selftest.sh
# YQ=<command> runs a local yq instead of the pinned image.
# shellcheck disable=SC2015,SC2016 # `A && ok || bad` reports, and $values is a literal ArgoCD reference
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SRC=$PWD
t=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/render-selftest.XXXXXX")
trap 'rm -rf "$t"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL selftest $1"; fails=$((fails + 1)); }

# stub helm: logs its argv, renders one Deployment whose image is $STUB_IMAGE
cat >"$t/helm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
[[ -z ${STUB_FAIL:-} ]] || { echo "Error: chart not found" >&2; exit 1; }
cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: x
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
      containers:
        - name: c
          image: ${STUB_IMAGE:-example.test/app:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000}
YAML
STUB
chmod +x "$t/helm"

mkrepo() { # mkrepo <dir>: apps tree with a values file
  rm -rf "$1"
  mkdir -p "$1/apps/platform/demo"
  printf 'replicas: 1\n' >"$1/apps/platform/demo/values.yaml"
}
app() { # app <dir> <name> <extra source fields...> : multi-source Application, values from this repository
  local d=$1 name=$2 rev=$3 vf=${4:-\$values/apps/platform/demo/values.yaml} refrepo=${5:-https://github.com/example-owner/homelab.git}
  cat >"$d/apps/$name.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $name
  namespace: argocd
spec:
  project: platform
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-ns
  sources:
    - repoURL: https://charts.example.test/stable
      chart: demo-chart
      targetRevision: "$rev"
      helm:
        releaseName: demo
        valueFiles:
          - $vf
    - repoURL: $refrepo
      targetRevision: main
      ref: values
YAML
}
run() { # run <repo dir> [env...]: out, rc
  rc=0
  : >"$t/log"
  out=$(cd "$1" && shift && env HELM="$t/helm" STUB_LOG="$t/log" "$@" APPS_DIR=apps bash "$SRC/ci/render-argocd-helm.sh" "$t/rendered.yaml" 2>&1) || rc=$?
}
# the script works on the repository root of its own location: run a copy placed under the fixture repo
expect() { # expect <label> <rc 0|1> <regex>
  if { [[ $2 == 0 && $rc == 0 ]] || [[ $2 == 1 && $rc != 0 ]]; } && [[ $out =~ $3 ]]; then ok "$1"; else bad "$1 (rc=$rc out=$out)"; fi
}
fixture() { mkrepo "$t/r"; mkdir -p "$t/r/ci"; cp "$SRC/ci/render-argocd-helm.sh" "$t/r/ci/"; }
runfx() { # run the copy inside the fixture repo
  rc=0
  : >"$t/log"
  out=$(env HELM="$t/helm" STUB_LOG="$t/log" GITHUB_REPOSITORY=example-owner/homelab "$@" bash "$t/r/ci/render-argocd-helm.sh" "$t/rendered.yaml" 2>&1) || rc=$?
}

fixture
runfx
expect "no Application: SKIP, exit 0" 0 'SKIP render no files'

app "$t/r" good 1.2.3
runfx
expect "an exact version renders" 0 'OK   render good demo-chart@1.2.3'
want='template demo demo-chart --repo https://charts.example.test/stable --version 1.2.3 --namespace demo-ns --kube-version 1.34.0 --include-crds -f apps/platform/demo/values.yaml'
[[ $(cat "$t/log") == "$want" ]] && ok "helm command line equals ArgoCD's (release, repo, version, namespace, crds, values)" || bad "helm argv: $(cat "$t/log")"
grep -q 'kind: Deployment' "$t/rendered.yaml" && ok "rendered documents land in the out file" || bad "out file"

# the render reaches the image check: a pinned image passes, an unpinned one fails
STUB_IMAGE='example.test/app:1.0.0' runfx
if env YQ="${YQ:-}" bash "$SRC/ci/check-images.sh" "$t/rendered.yaml" >"$t/img.out" 2>&1; then bad "unpinned image canary passed the image check"; else
  grep -q 'FAIL image example.test/app:1.0.0 not digest-pinned' "$t/img.out" && ok "an unpinned image in a rendered chart fails the image check" || bad "canary output: $(cat "$t/img.out")"
fi

rm "$t/r/apps/good.yaml"
for rev in '^1.2.0' '~1.2' '*' latest 1.x '>=1.0.0' '1.2' ''; do
  app "$t/r" bad "$rev"
  runfx
  expect "targetRevision '$rev' refused" 1 'FAIL render bad targetRevision .* is not an exact version'
  [[ ! -s $t/log ]] || bad "helm ran for targetRevision '$rev'"
done
rm "$t/r/apps/bad.yaml"

app "$t/r" refs 1.2.3 '$other/apps/platform/demo/values.yaml'
runfx
expect "a values file naming no ref source is refused" 1 'names no source with ref other'
app "$t/r" refs 1.2.3 '$values/apps/platform/demo/values.yaml' https://github.com/example-owner/other-repo.git
runfx
expect "values from another repository refused" 1 'comes from a repository other than this one'
app "$t/r" refs 1.2.3 '$values/apps/platform/demo/values.yaml' https://github.com/other-owner/homelab.git
runfx
expect "values from the same repository name under another owner refused" 1 'comes from a repository other than this one'
app "$t/r" refs 1.2.3 '$values/apps/platform/demo/values.yaml' https://github.com/Example-Owner/Homelab
runfx
expect "the own repository (URL without .git, any case) is accepted" 0 'OK   render refs demo-chart@1.2.3'
runfx GITHUB_REPOSITORY=
expect "without GITHUB_REPOSITORY and an origin remote the repository is unknown: refused" 1 'this repository is unknown'
git -C "$t/r" init -q && git -C "$t/r" remote add origin https://github.com/example-owner/homelab.git
runfx GITHUB_REPOSITORY=
expect "the origin remote identifies this repository when GITHUB_REPOSITORY is unset" 0 'OK   render refs demo-chart@1.2.3'
rm -rf "$t/r/.git"
app "$t/r" refs 1.2.3 '$values/apps/platform/missing.yaml'
runfx
expect "a missing values file refused" 1 'not found in this repository'
app "$t/r" refs 1.2.3 '$values/../outside.yaml'
runfx
expect "a path with .. refused" 1 'not found in this repository'
app "$t/r" refs 1.2.3 'values.yaml'
runfx
expect "a plain values path (a file of the chart repository) refused" 1 'is not of the form'
rm "$t/r/apps/refs.yaml"

# inline values, valuesObject, parameters, skipCrds, single source
cat >"$t/r/apps/inline.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: inline
spec:
  destination:
    namespace: other-ns
  source:
    repoURL: https://charts.example.test/stable
    chart: other-chart
    targetRevision: v2.0.0-rc.1
    helm:
      skipCrds: true
      values: |
        a: 1
      valuesObject:
        b: 2
      parameters:
        - name: image.tag
          value: v2
YAML
runfx
expect "inline values, object and parameters render" 0 'OK   render inline other-chart@v2.0.0-rc.1'
grep -q -- '--set image.tag=v2' "$t/log" && ! grep -q -- 'other-chart.*--include-crds' "$t/log" && grep -c -- ' -f ' "$t/log" >/dev/null && ok "parameter passed as --set, skipCrds drops --include-crds" || bad "inline argv: $(cat "$t/log")"
rm "$t/r/apps/inline.yaml"

# an Application whose source is a path (no chart) and other kinds are ignored
cat >"$t/r/apps/path.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: path-app
spec:
  source:
    repoURL: https://github.com/example-owner/homelab.git
    path: apps/x
    targetRevision: main
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: not-an-app
YAML
rm -f "$t/r/apps/good.yaml"
runfx
expect "path sources and other kinds are ignored" 0 'SKIP render no files'
rm "$t/r/apps/path.yaml"

app "$t/r" good 1.2.3
runfx STUB_FAIL=1
expect "a failing helm template fails the step" 1 'FAIL render good helm template of demo-chart@1.2.3 failed \(Error: chart not found\)'

[[ $fails == 0 ]] || { echo "render-argocd-helm-selftest: $fails failure(s)"; exit 1; }
echo "render-argocd-helm-selftest OK"
