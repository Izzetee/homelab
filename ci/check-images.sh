#!/usr/bin/env bash
# Image pinning and architecture check on rendered Kubernetes manifests (every container, init container
# and CronJob template). An image must be <name>:<tag>@sha256:<64 hex>; without a kubernetes.io/arch
# nodeSelector the pod must run on both linux/amd64 and linux/arm64 images, with one the selected
# architecture must be in the image platforms.
#   ci/check-images.sh [file ...]         default: stdin (kustomize build ... | ci/check-images.sh)
# Prints `FAIL image <ref> <reason>` per finding and `OK images n=<count>`; exit 1 on any FAIL.
# Platforms come from `docker buildx imagetools inspect` (index, or the image config of a single manifest).
# YQ=<command> runs a local yq instead of the pinned image (tests, local use).
set -euo pipefail

YQ_IMAGE=docker.io/mikefarah/yq:4.54.3@sha256:7834187596ad56fd5a81436114e0b0b9dd54c91bb43946d1f7145b2be5f9c3d2
yq_docs() { # one compact JSON document per line
  if [[ -n ${YQ:-} ]]; then
    # shellcheck disable=SC2086 # YQ is a command line on purpose
    $YQ -o=json -I=0 '.' -
  else
    docker run --rm -i "$YQ_IMAGE" -o=json -I=0 '.' -
  fi
}

tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/images.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
if [[ $# -gt 0 ]]; then cat "$@" >"$tmp/in.yaml"; else cat >"$tmp/in.yaml"; fi

yq_docs <"$tmp/in.yaml" | jq -r '
  def pod: if .kind == "Pod" then .spec
    elif .kind == "CronJob" then .spec.jobTemplate.spec.template.spec
    elif (.kind | IN("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "ReplicationController")) then .spec.template.spec
    else empty end;
  select(type == "object") | pod | . as $p | ($p.nodeSelector["kubernetes.io/arch"] // "-") as $a
  | (if (($p.imagePullSecrets // []) | length) > 0 then "pull" else "-" end) as $s
  | (($p.containers // []) + ($p.initContainers // []) + ($p.ephemeralContainers // []))[] | "\(.image)\t\($a)\t\($s)"' |
  sort -u >"$tmp/images.tsv"

if [[ ! -s $tmp/images.tsv ]]; then
  echo "SKIP images no files"
  exit 0
fi

platforms() { # platforms <ref>: linux architectures, one per line; non-zero when unreadable
  local raw
  raw=$(docker buildx imagetools inspect --raw "$1" 2>/dev/null) || return 1
  if jq -e 'has("manifests")' >/dev/null 2>&1 <<<"$raw"; then
    jq -r '.manifests[].platform | select(. != null and .os == "linux") | .architecture' <<<"$raw" | sort -u
  else
    docker buildx imagetools inspect --format '{{json .Image}}' "$1" 2>/dev/null |
      jq -r 'if has("architecture") then (select(.os == "linux") | .architecture) else (to_entries[] | .value | select(.os == "linux") | .architecture) end' | sort -u
  fi
}

fail=0 n=0
while IFS=$'\t' read -r ref sel pull; do
  n=$((n + 1))
  if [[ ! $ref =~ ^[^[:space:]@]+:[A-Za-z0-9_][A-Za-z0-9._-]*@sha256:[0-9a-f]{64}$ ]]; then
    echo "FAIL image $ref not digest-pinned"
    fail=1
    continue
  fi
  if ! pl=$(platforms "$ref") || [[ -z $pl ]]; then
    if [[ $ref == ghcr.io/izzetee/lawnews/* && $sel != - && $pull == pull ]]; then
      echo "SKIP image $ref private"
      continue
    fi
    echo "FAIL image $ref platforms unreadable"
    fail=1
    continue
  fi
  need=$sel
  [[ $need != - ]] || need="amd64 arm64"
  for a in $need; do
    if ! grep -qx "$a" <<<"$pl"; then
      echo "FAIL image $ref arch $a missing"
      fail=1
    fi
  done
done <"$tmp/images.tsv"
[[ $fail == 0 ]] || exit 1
echo "OK images n=$n"
