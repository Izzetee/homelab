#!/usr/bin/env bash
# Proves that the custom rules of a gitleaks config still fire (and still stay quiet on references).
# Literals are generated at run time into a temp dir, so no committed file holds one.
#   ci/gitleaks-selftest.sh [config]      default .gitleaks.toml
# GITLEAKS=<command> runs a local binary instead of the pinned image (tests, local use).
set -euo pipefail

CONFIG=${1:-.gitleaks.toml}
IMAGE=ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
[[ -f $CONFIG ]] || { echo "FAIL selftest config missing"; exit 1; }

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/in" "$work/out"
chmod 755 "$work" "$work/in" "$work/out"

rnd() { head -c "$(($1 / 2 + 1))" /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-"$1"; }
R=$(rnd 14)

# key names and markers are assembled from fragments, so this file itself holds no literal the rules would flag
PW=pass
PW+=word
TK=to
TK+=ken
CS=clientSec
CS+=ret
AK=API_
AK+=KEY
PK=private_
PK+=key
DP=DB_
DP+=PASS
DBP=DB_
DBP+=PASSWORD
ENC=ENC
ENC+='[AES256_GCM,'
AGE='-----BEGIN AGE '
AGE+='ENCRYPTED FILE-----'
CM=change
CM+=me
SOPS=so
SOPS+='ps:'
SEALED=kind:
SEALED+=' SealedSecret'

# hits: <file>|<expected rule>|<content>; short, numeric and default-with-literal forms included
hits=(
  "h01.yaml|homelab-literal-secret|$PW: abc"
  "h02.yaml|homelab-literal-secret|$PW: 1234"
  "h03.env|homelab-literal-secret|$DP=ab"
  "h04.yaml|homelab-literal-secret|$TK: x1"
  "h05.yaml|homelab-literal-secret|$PW: $R"
  "h06.env|homelab-literal-secret|$AK=$R"
  "h07.tf|homelab-literal-secret|api_$TK = \"$R\""
  "h08.yaml|homelab-literal-secret|$PW: $CM"
  "h09.yaml|homelab-literal-secret|$PW: \${$DBP:-$R}"
  "h10.yaml|homelab-literal-secret|$PW: \${X-$R}"
  "h11.yml|homelab-literal-secret|$TK: \"{{ x | default('$R') }}\""
  "h12.yaml|homelab-literal-secret|$CS: abc"
  "h13.json|homelab-literal-secret|{\"$PW\": \"abc\"}"
  "h14.yaml|homelab-literal-secret|$PK: $R"
  "h15.yaml|homelab-ciphertext|data: $ENC""data:$R,iv:x,tag:y,type:str]"
  "h16.txt|homelab-ciphertext|$AGE"
  "h17.yaml|homelab-ciphertext|$SOPS"
  "h18.yaml|homelab-ciphertext|$SEALED"
  "h19.yaml|homelab-literal-secret|$PW: \"\$2y\$10\$$R\""
  "h20.yaml|homelab-literal-secret|$PW: \$argon2id\$v=19\$$R"
)
# passes: references and look-alikes that must not fire
passes=(
  "p01.yaml|secretKey: $PW"
  "p02.yaml|existingSecret: x"
  "p03.yaml|secretName: tls-x"
  "p04.yaml|${TK}TTL: 1h"
  "p05.yaml|$PW: \${$DBP}"
  "p06.yaml|$PW: \"\""
  "p07.yml|k3s_$TK: \"{{ lookup('env', 'K3S_TOKEN') }}\""
  "p08.yml|secret_x: \"{{ lookup('env','X') | default('') }}\""
  "p09.tf|api_$TK = var.pve_token"
  "p10.yaml|$PW: true"
  "p11.yaml|$TK: ~"
  "p12.yaml|existingSecretName: foo"
  "p13.yaml|$PW: <your-password>"
  "p14.yaml|$PW: null"
  "p15.yaml|remoteRef: {key: apps/db, property: $PW}"
  "p16.yaml|bypass: enabled"
  "p17.sh|docker run -v \"\$PWD:/repo\" image"
  "p18.yaml|$PW: \$DB_VAR"
)
for h in "${hits[@]}"; do
  IFS='|' read -r f _ c <<<"$h"
  printf '%s\n' "$c" >"$work/in/$f"
done
for p in "${passes[@]}"; do
  IFS='|' read -r f c <<<"$p"
  printf '%s\n' "$c" >"$work/in/$f"
done
chmod 644 "$work"/in/*
cp "$CONFIG" "$work/gitleaks.toml"
chmod 644 "$work/gitleaks.toml"

if [[ -n ${GITLEAKS:-} ]]; then
  # shellcheck disable=SC2086 # GITLEAKS is a command line on purpose
  $GITLEAKS dir --config "$work/gitleaks.toml" --redact --no-banner --log-level error --exit-code 0 \
    --report-format json --report-path "$work/out/report.json" "$work/in" >/dev/null 2>&1 || { echo "FAIL selftest run"; exit 1; }
else
  docker run --rm --user "$(id -u):$(id -g)" -v "$work:/w" "$IMAGE" dir --config /w/gitleaks.toml --redact --no-banner \
    --log-level error --exit-code 0 --report-format json --report-path /w/out/report.json /w/in >/dev/null 2>&1 || { echo "FAIL selftest run"; exit 1; }
fi
[[ -f $work/out/report.json ]] || { echo "FAIL selftest no report"; exit 1; }

fail=0
findings=$(jq -r '.[] | "\(.File | split("/") | last) \(.RuleID)"' "$work/out/report.json")
for h in "${hits[@]}"; do
  IFS='|' read -r f rule _ <<<"$h"
  if ! grep -qx "$f $rule" <<<"$findings"; then
    echo "FAIL selftest $f not detected by $rule"
    fail=1
  fi
done
for p in "${passes[@]}"; do
  IFS='|' read -r f _ <<<"$p"
  if grep -q "^$f " <<<"$findings"; then
    echo "FAIL selftest $f false positive"
    fail=1
  fi
done
[[ $fail == 0 ]] || exit 1
echo "OK selftest hits=${#hits[@]} passes=${#passes[@]}"
