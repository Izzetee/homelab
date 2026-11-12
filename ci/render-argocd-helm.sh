#!/usr/bin/env bash
# Renders every Helm source of an ArgoCD Application under apps/ the way ArgoCD does (chart from its repository
# at the pinned targetRevision, with the values files, inline values and parameters the Application names), so the
# rendered manifests can go through kubeconform and the image check like every other manifest.
#   ci/render-argocd-helm.sh <out-file>      appends the rendered documents to <out-file> (created empty)
# Run from anywhere; it works on the repository root. A Helm source is a source that sets `chart`; a source that
# is a path with its own Chart.yaml is rendered by the local-chart step of CI. Value files must be `$ref/path` of
# a source of this repository (`ref:`), the layout ArgoCD needs to read values from Git next to a chart.
# Prints `OK render <app> <chart>@<version>` per source, `SKIP render no files`, `FAIL render <app> <reason>`;
# exit 1 on any FAIL.
# HELM=<command> runs a local helm instead of the pinned image, YQ=<command> a local yq (tests, local use).
# This repository is $GITHUB_REPOSITORY (owner/name, set on the runner), else the owner/name of the `origin` remote; a values
# source of any other repository is refused. KUBE_VERSION sets --kube-version (default 1.34.0, the version kubeconform checks).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HELM_IMAGE=alpine/helm:4.3.1@sha256:e3f8d5c462d75470fbb1fce79ad5c20063657096d1f98c0fcea869e2600e2e5e
YQ_IMAGE=docker.io/mikefarah/yq:4.54.3@sha256:7834187596ad56fd5a81436114e0b0b9dd54c91bb43946d1f7145b2be5f9c3d2
KUBE_VERSION=${KUBE_VERSION:-1.34.0}
APPS_DIR=${APPS_DIR:-apps}
EXACT_VERSION='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

[[ $# -eq 1 ]] || { echo "FAIL render usage: $0 <out-file>"; exit 2; }
out=$1
tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/render.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
: >"$out"

self_slug() { # owner/name of this repository, lowercase, without .git; empty when unknown
  local u=${GITHUB_REPOSITORY:-}
  [[ -n $u ]] || u=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##' || true)
  u=${u%.git}
  [[ $u =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
  return 0
}
SELF=$(self_slug)
yq_docs() { # one compact JSON document per line
  if [[ -n ${YQ:-} ]]; then
    # shellcheck disable=SC2086 # YQ is a command line on purpose
    $YQ -o=json -I=0 '.' -
  else
    docker run --rm -i "$YQ_IMAGE" -o=json -I=0 '.' -
  fi
}
helm() {
  if [[ -n ${HELM:-} ]]; then
    # shellcheck disable=SC2086 # HELM is a command line on purpose
    $HELM "$@"
  else
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/work" -v "$tmp:$tmp:ro" -w /work "$HELM_IMAGE" "$@"
  fi
}

# one JSON job per Helm source of every Application
: >"$tmp/jobs.jsonl"
while IFS= read -r f; do
  # shellcheck disable=SC2094 # $f is only read (the second use is a label for the job)
  yq_docs <"$f" | jq -c --arg f "$f" '
    select(type == "object" and ((.apiVersion // "") | tostring | startswith("argoproj.io/")) and .kind == "Application")
    | . as $a | (if .spec.sources then .spec.sources else [.spec.source // empty] end) as $src
    | ($src | map(select(.ref != null) | {(.ref): .repoURL}) | add // {}) as $refs
    | $src[] | select(.chart != null)
    | {file: $f, app: $a.metadata.name, ns: ($a.spec.destination.namespace // "default"), repo: .repoURL, chart: .chart,
       rev: ((.targetRevision // "") | tostring), release: (.helm.releaseName // $a.metadata.name),
       files: (.helm.valueFiles // []), values: (.helm.values // ""), obj: (.helm.valuesObject // null),
       params: [(.helm.parameters // [])[] | "\(.name)=\(.value)"], skipCrds: (.helm.skipCrds // false), refs: $refs}' >>"$tmp/jobs.jsonl" ||
    { echo "FAIL render $f is not readable YAML"; exit 1; }
done < <(find "$APPS_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort)

if [[ ! -s $tmp/jobs.jsonl ]]; then
  echo "SKIP render no files"
  exit 0
fi

fail=0
n=0
while IFS= read -r job; do
  n=$((n + 1))
  j() { jq -r "$1" <<<"$job"; }
  app=$(j .app) chart=$(j .chart) rev=$(j .rev) repo=$(j .repo)
  if [[ ! $rev =~ $EXACT_VERSION ]]; then
    echo "FAIL render $app targetRevision '$rev' of $chart is not an exact version"
    fail=1
    continue
  fi
  if [[ ! $repo =~ ^https://[A-Za-z0-9._/-]+$ ]]; then
    echo "FAIL render $app chart repository '$repo' is not an https URL"
    fail=1
    continue
  fi
  args=(template "$(j .release)" "$chart" --repo "$repo" --version "$rev" --namespace "$(j .ns)" --kube-version "$KUBE_VERSION")
  [[ $(j .skipCrds) == true ]] || args+=(--include-crds)
  bad=""
  while IFS= read -r vf; do
    [[ -n $vf ]] || continue
    if [[ $vf =~ ^\$([A-Za-z0-9_-]+)/([A-Za-z0-9_./-]+)$ ]]; then
      ref=${BASH_REMATCH[1]} path=${BASH_REMATCH[2]}
      refrepo=$(jq -r --arg r "$ref" '.refs[$r] // ""' <<<"$job")
      if [[ -z $refrepo ]]; then bad="values file $vf names no source with ref $ref"
      elif [[ -z $SELF ]]; then bad="this repository is unknown (set GITHUB_REPOSITORY or an origin remote), values file $vf cannot be checked"
      elif [[ $(sed -E 's#^https://github\.com/##; s#\.git$##' <<<"$refrepo" | tr '[:upper:]' '[:lower:]') != "$SELF" ]]; then bad="values file $vf comes from a repository other than this one"
      elif [[ $path == *..* || ! -f $path ]]; then bad="values file $path not found in this repository"
      fi
      args+=(-f "$path")
    else
      bad="values file $vf is not of the form \$<ref>/<path>"
    fi
  done < <(jq -r '.files[]' <<<"$job")
  if [[ -n $bad ]]; then
    echo "FAIL render $app $bad"
    fail=1
    continue
  fi
  if [[ -n $(j .values) ]]; then
    j .values >"$tmp/$n-values.yaml"
    args+=(-f "$tmp/$n-values.yaml")
  fi
  if [[ $(j '.obj != null') == true ]]; then
    jq '.obj' <<<"$job" >"$tmp/$n-object.yaml"
    args+=(-f "$tmp/$n-object.yaml")
  fi
  while IFS= read -r p; do
    [[ -z $p ]] || args+=(--set "$p")
  done < <(jq -r '.params[]' <<<"$job")
  if helm "${args[@]}" >"$tmp/$n-render.yaml" 2>"$tmp/$n-helm.err"; then
    { cat "$tmp/$n-render.yaml"; echo "---"; } >>"$out"
    echo "OK   render $app $chart@$rev"
  else
    echo "FAIL render $app helm template of $chart@$rev failed ($(tail -n 1 "$tmp/$n-helm.err" | cut -c1-200))"
    fail=1
  fi
done <"$tmp/jobs.jsonl"
[[ $fail == 0 ]] || exit 1
