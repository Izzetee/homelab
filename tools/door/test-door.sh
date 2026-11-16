#!/usr/bin/env bash
# Self-test of the publishing door (launcher, door.sh, check.py) with a local bare repository as the "fixed endpoint" (reached only through a git
# URL rewrite rule in the test's environment), a stub check host (test/stub-ssh), stub GitHub API (test/stub-gh) and stub Access API
# (test/stub-access). Canaries in every position must never reach stdout, stderr, the arguments of any stub call or a file left behind.
set -euo pipefail
AT=@ # an at sign is written through a variable: this tree holds no e-mail-shaped literal
cd "$(dirname "$0")/../.."
ROOT=$PWD
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
t=$(mktemp -d "${TMPDIR:-/tmp}/test-door.XXXXXX")
t=${t//\/\//\/}
cleanup() { [[ -z ${ACCPID:-} ]] || kill "$ACCPID" 2>/dev/null || true; rm -rf "$t"; }
trap cleanup EXIT
mkdir -p "$t/bin" "$t/home" "$t/state" "$t/tmp" "$t/src"
Q=$(printf 'q%.0s' 1 2 3 4 5 6)
G_TOK="canary-gh-$Q"
A_TOK="canary-access-$Q"
KEYB=$(printf 'canary-ssh-key-%s' "$Q" | base64 | tr -d '\n')
STORE="canary-store-value-$Q"
PRIV="privrepo-$Q"
GHP="ghp_$(printf 'Ab1%.0s' $(seq 12))" # shaped like a personal access token, built at run time
ACC=$(printf 'c%.0s' $(seq 32))
cp test/stub-gh "$t/bin/gh" 2>/dev/null || cp tools/door/test/stub-gh "$t/bin/gh"
cp tools/door/test/stub-gh "$t/bin/gh"
cp tools/door/test/stub-ssh "$t/bin/ssh"
export HOME=$t/home TMPDIR=$t/tmp STUB_DIR=$t/state STUB_GH=$G_TOK STUB_ACCESS=$A_TOK STUB_STORE_VALUES=$STORE STUB_PRIVATE=$PRIV PATH="$t/bin:$PATH"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$t/endpoint.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/Izzetee/homelab.git
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL='18075479+Izzetee@users.noreply.github.com' GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL='18075479+Izzetee@users.noreply.github.com'
export GIT_CONFIG_GLOBAL=/dev/null

# ---- the fixed endpoint: main holds the door code, the gitleaks config and a small tree with one existing app
cd "$t/src"
git init -q -b main .
mkdir -p tools/door apps/_argocd apps/tools/demo apps/platform/argocd networking apps/platform/secret-store apps/platform/openbao/config
cp "$ROOT/tools/door/launcher" "$ROOT/tools/door/door.sh" "$ROOT/tools/door/check.py" "$ROOT/tools/door/exceptions.txt" tools/door/
printf 'apps/tools/demo/exc.yaml other/exc-key\n' >>tools/door/exceptions.txt # a test-only line next to the real ones
cp "$ROOT/.gitleaks.toml" .gitleaks.toml
printf '# rules\n' >AGENTS.md
cat >apps/_argocd/demo.yaml <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo
  namespace: argocd
spec:
  project: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: demo
  source:
    repoURL: https://github.com/Izzetee/homelab.git
    targetRevision: main
    path: apps/tools/demo
YAML
cat >apps/tools/demo/kustomization.yaml <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - externalsecret.yaml
  - route.yaml
YAML
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: demo\n  namespace: demo\ndata:\n  mode: one\n' >apps/tools/demo/configmap.yaml
cat >apps/tools/demo/externalsecret.yaml <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: demo
  namespace: demo
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: demo
  data:
    - secretKey: k
      remoteRef:
        key: apps/demo/app
        property: value
YAML
cat >apps/tools/demo/route.yaml <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo
  namespace: demo
spec:
  parentRefs:
    - name: homelab
      namespace: gateway
      sectionName: lan
  hostnames:
    - demo.lan.chill-town.de
  rules:
    - backendRefs:
        - name: demo
          port: 80
YAML
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: project\n' >apps/platform/argocd/project.yaml
printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: demo\n' >networking/namespaces.yaml
printf 'demo\n' >apps/platform/openbao/config/namespaces.txt
printf 'kind: ClusterSecretStore\n' >apps/platform/secret-store/cluster-secret-store.yaml
git add -A
git commit -q -m "endpoint main"
git clone -q --bare . "$t/endpoint.git"
cd "$ROOT"
endpoint_main() { git -C "$t/endpoint.git" rev-parse refs/heads/main; }

# ---- the clone (its origin is the fixed URL; the rewrite rule only changes the transport)
git clone -q "$t/endpoint.git" "$t/clone"
git -C "$t/clone" remote set-url origin https://github.com/Izzetee/homelab.git
CL=$t/clone
HD=$HOME/.local/bin/homelab-door
cl() { git -C "$CL" "$@"; }
entries() { # the environment the store entries would provide
  env GH_TOKEN="$G_TOK" DOOR_SCAN_SSH_KEY="$KEYB" DOOR_SCAN_TARGET=owner${AT}scan.example.invalid DOOR_SCAN_KNOWN_HOST='scan.example.invalid ssh-ed25519 AAAA' \
    CLOUDFLARE_ACCESS_TOKEN="$A_TOK" CLOUDFLARE_ACCOUNT_ID="$ACC" HOMELAB_DOOR_TEST=1 DOOR_CF_API="${DOOR_CF_API:-http://127.0.0.1:1}" "$@"
}
door() { rc=0; out=$(cd "$CL" && entries "$HD" "$@" 2>&1 </dev/null) || rc=$?; }
reset_stubs() { : >"$t/state/ssh-argv.log"; : >"$t/state/gh-argv.log"; : >"$t/state/gh-requests.log"; rm -f "$t/state/gh-merged.json" "$t/state/gh-created.json" "$t/state/gh-edited.json" "$t/state/down"; }
printf '{"pulls":{},"checks":{}}' >"$t/state/gh-state.json"
reset_stubs

# ---- install: dry-run, apply, idempotence, previous hook, uninstall
printf '#!/bin/sh\necho previous\n' >"$CL/.git/hooks/pre-push"
chmod +x "$CL/.git/hooks/pre-push"
rc=0
out=$(cd "$CL" && bash "$ROOT/tools/door/launcher" install --dry-run 2>&1) || rc=$?
[[ $rc == 0 && $out == *'PLAN install launcher'* && $out == *'PLAN install hook'* && $out == *'PLAN set identity'* && ! -e $HD && ! -e $HOME/.local ]] && ok "install --dry-run: PLAN lines, nothing installed, no directory created" || bad "install dry-run: rc=$rc $out"
rc=0
out=$(cd "$CL" && bash "$ROOT/tools/door/launcher" install 2>&1) || rc=$?
[[ $rc == 0 && $out == *'OK   launcher installed'* && $out == *'OK   previous hook recorded'* && $out == *'OK   hook installed'* && $out == *'OK   identity set'* && $out == *'OK   credential helper set'* ]] && ok "install: launcher, hook (previous hook recorded), identity, credential helper" || bad "install: rc=$rc $out"
rc=0
out=$(cd "$CL" && "$HD" install 2>&1) || rc=$?
[[ $rc == 0 && $out == *'SKIP launcher'* && $out == *'SKIP hook'* && $out == *'SKIP identity'* && $out == *'SKIP credential helper'* && $out != *'OK '* ]] && ok "install a second time: SKIP lines only" || bad "install again: rc=$rc $out"
[[ -f $CL/.git/hooks/pre-push.previous && $(cat "$CL/.git/hooks/pre-push.previous") == *previous* ]] && ok "the previous hook is kept as pre-push.previous" || bad "previous hook"
cmp -s "$HD" tools/door/launcher && ok "the installed launcher is the launcher of the fixed endpoint's main" || bad "launcher content"
rc=0
out=$(cd "$CL" && "$HD" uninstall 2>&1) || rc=$?
[[ $rc == 0 && $out == *'previous hook restored'* && $(cat "$CL/.git/hooks/pre-push") == *previous* ]] && ok "uninstall restores the recorded hook" || bad "uninstall: rc=$rc $out"
(cd "$CL" && "$HD" install >/dev/null 2>&1)

# ---- doctor
door doctor
[[ $rc == 0 && $out == *"OK door fixed endpoint $(endpoint_main | cut -c1-12)"* && $out == *'OK door push URL'* && $out == *'OK door launcher'* && $out == *'OK door hook'* && $out == *'OK door scan host'* && $out == *'OK entry github'* ]] && ok "doctor: endpoint SHA, push URL, launcher, hook, scan host and the github entry are OK" || bad "doctor: rc=$rc $out"
rc=0
out=$(cd "$CL" && env -u GH_TOKEN DOOR_SCAN_SSH_KEY="$KEYB" DOOR_SCAN_TARGET=owner${AT}scan.example.invalid DOOR_SCAN_KNOWN_HOST='scan.example.invalid ssh-ed25519 AAAA' "$HD" doctor 2>&1 </dev/null) || rc=$?
[[ $rc != 0 && $out == *'FAIL entry github'* && $out == *'OK door scan host'* ]] && ok "doctor without GH_TOKEN gives FAIL entry github, the rest OK" || bad "doctor no github, rc=$rc $out"
STUB_SSH_DOWN=1 door doctor
[[ $rc != 0 && $out == *'FAIL scan host'* ]] && ok "doctor with the scan host down: FAIL scan host" || bad "doctor ssh down: rc=$rc $out"

# ---- branches: a clean one is pushed, the stub host sees the framed patch
mkbranch() { cl checkout -q -B "$1" refs/remotes/origin/main; }
put() { mkdir -p "$(dirname "$CL/$1")"; printf '%s\n' "$2" >"$CL/$1"; }
commit() { cl add -A; cl commit -q -m "$1"; }
mkbranch clean
put apps/tools/demo/configmap.yaml 'apiVersion: v1
kind: ConfigMap
metadata:
  name: demo
  namespace: demo
data:
  mode: two'
commit "Change the demo mode"
reset_stubs
# main moves on at the endpoint while the clone does not know the new commit: the run must not store its objects in the clone
oldmain=$(endpoint_main)
(cd "$t/src" && printf 'later\n' >docs-later.txt && git add -A && git commit -q -m "later main" && git push -q "$t/endpoint.git" main)
printf 'x\n' >"$CL/.git/FETCH_HEAD"
cksum <"$CL/.git/FETCH_HEAD" >"$t/fh.before"
find "$CL/.git/objects" -type f | sort >"$t/obj.before"
door --dry-run clean
cksum <"$CL/.git/FETCH_HEAD" >"$t/fh.after"
find "$CL/.git/objects" -type f | sort >"$t/obj.after"
git -C "$t/endpoint.git" update-ref refs/heads/main "$oldmain"
[[ -z $(cl status --porcelain) ]] && cmp -s "$t/fh.before" "$t/fh.after" && cmp -s "$t/obj.before" "$t/obj.after" && ok "a dry run leaves FETCH_HEAD, the working tree and the clone's object store unchanged" || bad "dry run changed local state"
[[ $rc == 0 && $out == *'OK door commits=1'* && $out == *'PLAN push clean commits=1'* && ! -e $t/endpoint.git/refs/heads/clean ]] && ok "--dry-run of a clean branch: every check passes, PLAN push, nothing pushed" || bad "dry-run clean: rc=$rc $out"
grep -q 'IdentitiesOnly=yes' "$t/state/ssh-argv.log" && grep -q 'StrictHostKeyChecking=yes' "$t/state/ssh-argv.log" && ! grep -qE ' -[tTLRAXNW] ' "$t/state/ssh-argv.log" && ok "the scan call uses the dedicated key only, strict host key, no pty, forwarding or agent" || bad "ssh options: $(cat "$t/state/ssh-argv.log")"
reset_stubs
door clean
[[ $rc == 0 && $out == *'OK pushed clean commits=1'* && $(git -C "$t/endpoint.git" rev-parse refs/heads/clean) == "$(cl rev-parse clean)" ]] && ok "push: the branch reaches the endpoint after the checks" || bad "push: rc=$rc $out"
[[ ! -e $CL/.git/homelab-door.checked ]] && ok "the check stamp is removed after the push" || bad "stamp left"
door clean
[[ $rc == 0 && $out == *'SKIP clean up to date'* ]] && ok "a second push of the same tip: SKIP up to date" || bad "up to date: rc=$rc $out"
door main
[[ $rc != 0 && $out == *'FAIL door no push to main'* ]] && ok "the door never pushes main" || bad "push main: rc=$rc $out"

# ---- door provenance (spec "Door code from the fixed endpoint's main")
mkbranch evil
printf 'import sys\nsys.exit(0)\n' >"$CL/tools/door/check.py"
put apps/tools/demo/externalsecret.yaml 'apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: demo
  namespace: demo
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: demo
  data:
    - secretKey: k
      remoteRef:
        key: platform/cloudflare-dns
        property: api-token'
commit "Make the door pass everything"
door --dry-run evil
[[ $rc != 0 && $out == *'FAIL externalsecret apps/tools/demo/externalsecret.yaml scope'* ]] && ok "a branch that weakens tools/door/check.py: the endpoint's main checks still run and refuse" || bad "door changed: rc=$rc $out"
cl checkout -q clean
oldsha=$(cl rev-parse refs/remotes/origin/main)
cl update-ref refs/remotes/origin/main "$(cl rev-list --max-parents=0 HEAD)"
door doctor
[[ $out == *"OK door fixed endpoint $(endpoint_main | cut -c1-12)"* ]] && ok "a moved local origin/main has no effect: the door runs the SHA the endpoint reports" || bad "moved ref: $out"
cl update-ref refs/remotes/origin/main "$oldsha"
cl remote set-url origin "$t/endpoint.git"
door doctor
[[ $rc != 0 && $out == 'FAIL door origin' ]] && ok "origin pointing at another repository: FAIL door origin" || bad "origin: rc=$rc $out"
cl remote set-url origin https://github.com/Izzetee/homelab.git
cl remote set-url --push origin "$t/endpoint.git"
door doctor
[[ $rc != 0 && $out == 'FAIL door origin' ]] && ok "another push URL: FAIL door origin" || bad "push url: rc=$rc $out"
cl config --unset remote.origin.pushurl
door --check-tree
cl remote set-url origin git${AT}github.com:Izzetee/homelab.git
door doctor
[[ $out != 'FAIL door origin' ]] && ok "the SSH form of the fixed URL is accepted" || bad "ssh url form: $out"
cl remote set-url origin https://github.com/Izzetee/homelab.git
rc=0
out=$(cd "$CL" && GIT_CONFIG_KEY_0="url.$t/nowhere.git.insteadOf" entries "$HD" doctor 2>&1 </dev/null) || rc=$?
[[ $rc != 0 && $out == 'FAIL door source' ]] && ok "endpoint unreachable: FAIL door source, nothing runs" || bad "unreachable: rc=$rc $out"
cp "$HD" "$t/launcher.keep"
printf '# changed\n' >>"$HD"
door doctor
[[ $rc != 0 && $out == 'FAIL launcher stale' ]] && ok "a launcher that differs from the endpoint's: FAIL launcher stale" || bad "stale launcher: rc=$rc $out"
cp "$t/launcher.keep" "$HD"
cp "$CL/.git/hooks/pre-push" "$t/hook.keep"
printf '#!/bin/sh\nexit 0\n' >"$CL/.git/hooks/pre-push"
door --dry-run clean
[[ $rc != 0 && $out == 'FAIL hook' ]] && ok "a changed pre-push hook: FAIL hook (every mode but doctor and uninstall)" || bad "changed hook: rc=$rc $out"
cp "$t/hook.keep" "$CL/.git/hooks/pre-push"
cl config core.hooksPath /nonexistent
door --dry-run clean
[[ $rc != 0 && $out == 'FAIL door hooksPath' ]] && ok "core.hooksPath set: FAIL" || bad "hooksPath: rc=$rc $out"
cl config --unset core.hooksPath

# ---- content rules (spec "Content rules on every push")
rule_case() { # rule_case <label> <expected fragment> <branch commit function>
  mkbranch "$1"
  "$3"
  commit "Add $1"
  door --dry-run "$1"
  [[ $rc != 0 && $out == *"$2"* && $out != *'PLAN push'* ]] && ok "$1: $2" || bad "$1: rc=$rc $out"
}
es_with() { # es_with <data yaml body after `spec:`>
  put apps/tools/demo/externalsecret.yaml "apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: demo
  namespace: demo
spec:
$1"
}
c_find() { es_with '  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: demo
  dataFrom:
    - find:
        name:
          regexp: .*'; }
c_sourceref() { es_with '  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: demo
  data:
    - secretKey: k
      sourceRef:
        storeRef:
          name: x
          kind: SecretStore'; }
c_store() { es_with '  secretStoreRef:
    kind: SecretStore
    name: other
  target:
    name: demo
  data:
    - secretKey: k
      remoteRef:
        key: apps/demo/app
        property: value'; }
c_extract() { es_with '  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: demo
  dataFrom:
    - extract:
        key: argocd/other'; }
c_otherapp() { es_with '  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: demo
  data:
    - secretKey: k
      remoteRef:
        key: apps/otherapp/value
        property: x'; }
c_ownns() { es_with '  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: demo
  data:
    - secretKey: k
      remoteRef:
        key: demo/own
        property: x'; }
rule_case es-find 'FAIL externalsecret apps/tools/demo/externalsecret.yaml scope' c_find
rule_case es-sourceref 'FAIL externalsecret apps/tools/demo/externalsecret.yaml scope' c_sourceref
rule_case es-store 'FAIL externalsecret apps/tools/demo/externalsecret.yaml scope' c_store
rule_case es-extract 'FAIL externalsecret apps/tools/demo/externalsecret.yaml scope' c_extract
rule_case es-otherapp 'FAIL externalsecret apps/tools/demo/externalsecret.yaml scope' c_otherapp
mkbranch es-ownns
c_ownns
commit "Read the own namespace path"
door --dry-run es-ownns
[[ $rc == 0 ]] && ok "an ExternalSecret reading <namespace>/… is allowed (and apps/<app>/… above in the baseline)" || bad "own namespace: rc=$rc $out"
r_bao() { put apps/tools/demo/route2.yaml 'apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shadow
  namespace: demo
spec:
  parentRefs:
    - name: homelab
      namespace: gateway
      sectionName: lan
  hostnames:
    - bao.lan.chill-town.de
  rules:
    - backendRefs:
        - name: demo
          port: 80'; }
r_argocd() { r_bao; sed -i.bak 's/bao.lan/argocd.lan/' "$CL/apps/tools/demo/route2.yaml"; rm -f "$CL/apps/tools/demo/route2.yaml.bak"; }
r_otherhost() { r_bao; sed -i.bak 's/bao.lan/demo2.lan/' "$CL/apps/tools/demo/route2.yaml"; rm -f "$CL/apps/tools/demo/route2.yaml.bak"; }
rule_case route-bao 'FAIL route apps/tools/demo/route2.yaml hostname' r_bao
rule_case route-argocd 'FAIL route apps/tools/demo/route2.yaml hostname' r_argocd
rule_case route-other-own 'FAIL route apps/tools/demo/route2.yaml hostname' r_otherhost
k_up() { put apps/tools/demo/kustomization.yaml 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../platform/openbao'; }
k_url() { put apps/tools/demo/kustomization.yaml 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://example.invalid/x?ref=main'; }
k_patch() { put apps/tools/demo/kustomization.yaml 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
patches:
  - path: ../other/p.yaml'; }
rule_case kust-up 'FAIL kustomize apps/tools/demo/kustomization.yaml reference' k_up
rule_case kust-url 'FAIL kustomize apps/tools/demo/kustomization.yaml reference' k_url
rule_case kust-patch 'FAIL kustomize apps/tools/demo/kustomization.yaml reference' k_patch
# address literals are built at run time: no file under tools/ may hold one (the door refuses them there)
A1=$(printf '%s.%s.1.50' 192 168)
A2=$(printf '%s.1.2.3' 10)
A3=$(printf '%s.16.4.5' 172)
A4=$(printf '%s.9.8.7' 10)
A5=$(printf '%s.%s.1.20' 192 168)
ns_other() { es_with '  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: demo
  data:
    - secretKey: k
      remoteRef:
        key: other/value
        property: x'; sed -i.bak 's/namespace: demo/namespace: other/' "$CL/apps/tools/demo/externalsecret.yaml"; rm -f "$CL/apps/tools/demo/externalsecret.yaml.bak"; }
rule_case es-ns-other 'FAIL externalsecret apps/tools/demo/externalsecret.yaml scope' ns_other
k_ns() { put apps/tools/demo/kustomization.yaml 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: other
resources:
  - configmap.yaml'; }
rule_case kust-namespace 'FAIL kustomize apps/tools/demo/kustomization.yaml namespace' k_ns
k_inline() { put apps/tools/demo/kustomization.yaml 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - externalsecret.yaml
  - route.yaml
patches:
  - target:
      kind: ExternalSecret
      name: demo
    patch: |-
      - op: replace
        path: /spec/data/0/remoteRef/key
        value: platform/cloudflare-dns'; }
rule_case kust-inline-patch 'FAIL externalsecret apps/tools/demo/kustomization.yaml scope' k_inline
j_es() { put apps/tools/demo/extra.json '{"apiVersion":"external-secrets.io/v1","kind":"ExternalSecret","metadata":{"name":"x","namespace":"demo"},"spec":{"secretStoreRef":{"kind":"ClusterSecretStore","name":"openbao"},"target":{"name":"x"},"data":[{"secretKey":"k","remoteRef":{"key":"platform/cloudflare-dns","property":"api-token"}}]}}'; }
rule_case es-json 'FAIL externalsecret apps/tools/demo/extra.json scope' j_es
k_noext() { put apps/tools/demo/sub/Kustomization 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../platform/openbao'; }
rule_case kust-noext 'FAIL kustomize apps/tools/demo/sub/Kustomization reference' k_noext
j_sonnet() { put apps/tools/demo/x.jsonnet '{}'; }
rule_case jsonnet 'FAIL apps apps/tools/demo/x.jsonnet format' j_sonnet
# the exception list: exact file and exact key only
exc_es() { # exc_es <file> <store key> [extra spec lines]
  put "apps/tools/demo/$1" "apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: exc
  namespace: demo
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: exc
  data:
    - secretKey: k
      remoteRef:
        key: $2
        property: x${3:-}"; }
mkbranch exc-ok
exc_es exc.yaml other/exc-key
commit "Read the listed path"
door --dry-run exc-ok
[[ $rc == 0 ]] && ok "a listed file with its listed key: accepted" || bad "exception ok: rc=$rc $out"
e_otherkey() { exc_es exc.yaml other/exc-other; }
rule_case exc-other-key 'FAIL externalsecret apps/tools/demo/exc.yaml scope' e_otherkey
e_otherfile() { exc_es exc2.yaml other/exc-key; }
rule_case exc-other-file 'FAIL externalsecret apps/tools/demo/exc2.yaml scope' e_otherfile
e_storekind() { exc_es exc.yaml other/exc-key; sed -i.bak 's/kind: ClusterSecretStore/kind: SecretStore/' "$CL/apps/tools/demo/exc.yaml"; rm -f "$CL/apps/tools/demo/exc.yaml.bak"; }
rule_case exc-store-kind 'FAIL externalsecret apps/tools/demo/exc.yaml scope' e_storekind
e_otherns() { exc_es exc.yaml other/exc-key; sed -i.bak 's/namespace: demo/namespace: other/' "$CL/apps/tools/demo/exc.yaml"; rm -f "$CL/apps/tools/demo/exc.yaml.bak"; }
rule_case exc-other-namespace 'FAIL externalsecret apps/tools/demo/exc.yaml scope' e_otherns
e_widen() { printf 'apps/tools/demo/exc3.yaml platform/cloudflare-dns\n' >>"$CL/tools/door/exceptions.txt"; exc_es exc3.yaml platform/cloudflare-dns; }
rule_case exc-widened-by-branch 'FAIL externalsecret apps/tools/demo/exc3.yaml scope' e_widen
# the real list: four lines, the two agentgateway and juraticker files and their two keys, nothing else
real=$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/tools/door/exceptions.txt")
[[ $(wc -l <<<"$real" | tr -d ' ') == 4 ]] && ! grep -qvE '^apps/tools/(agentgateway|juraticker)/(external-secrets|kustomization)\.yaml (juraticker/app-config|agentgateway/virtual-keys)$' <<<"$real" && ok "the real exception list: exactly the four known files with their two keys" || bad "real exception list: $real"
a_skill() { put .agents/skills/x/SKILL.md "Open the panel at $A1 and the other at $A2."; }
rule_case addr-skill 'FAIL text .agents/skills/x/SKILL.md address' a_skill
a_msg() { put docs/note.md 'plain'; }
mkbranch addr-msg
a_msg
cl add -A
cl commit -q -m "Point the docs at $A3"
door --dry-run addr-msg
[[ $rc != 0 && $out == *"FAIL text $(cl rev-parse --short=7 HEAD) address"* ]] && ok "an address in a commit message: FAIL text <short sha> address" || bad "addr msg: rc=$rc $out"
a_ok() { put apps/tools/demo/note.yaml "# an address in an app manifest is not the door's business: $A4"; }
mkbranch addr-app
a_ok
commit "Mention a pod address in the app"
door --dry-run addr-app
[[ $rc == 0 ]] && ok "an address literal outside AGENTS.md, .agents, docs and tools is not refused" || bad "addr app: rc=$rc $out"

# ---- identity, shape, gitleaks
mkbranch ident
put apps/tools/demo/id.yaml 'a: 1'
cl add -A
GIT_AUTHOR_EMAIL=someone${AT}example.com cl commit -q -m "Other identity"
door --dry-run ident
[[ $rc != 0 && $out == *"FAIL identity $(cl rev-parse --short=7 HEAD)"* ]] && ok "an unaccepted author address: FAIL identity" || bad "identity: rc=$rc $out"
mkbranch shape
printf 'x' >"$CL/apps/tools/demo/data.zip"
printf '\000\001\002' >"$CL/apps/tools/demo/blob.bin"
commit "Add archives"
door --dry-run shape
[[ $rc != 0 && $out == *'FAIL path apps/tools/demo/data.zip'* && $out == *'FAIL binary apps/tools/demo/blob.bin'* ]] && ok "a forbidden path and a binary file: FAIL path / FAIL binary" || bad "shape: rc=$rc $out"
mkbranch secret
put apps/tools/demo/leak.yaml "token: $GHP"
commit "Add a file with a token"
door --dry-run secret
[[ $rc != 0 && $out == *'FAIL gitleaks apps/tools/demo/leak.yaml:1'* && $out != *"$GHP"* ]] && ok "a token-shaped value: FAIL gitleaks <file>:<line> <rule>, the value is not printed" || bad "gitleaks: rc=$rc $out"

# ---- the extra check host: store value, private name, unreachable, source missing, canary run
mkbranch scanval
put apps/tools/demo/s.yaml "note: $STORE"
commit "Add a note"
reset_stubs
door --dry-run scanval
[[ $rc != 0 && $out == *'FAIL scan push/range.patch keys=openbao:secret/apps/canary/value:value'* && $out != *"$STORE"* ]] && ok "a store value in a commit: FAIL scan push/range.patch keys=… (no value), nothing pushed" || bad "scan value: rc=$rc $out"
mkbranch scanname
put apps/tools/demo/n.yaml 'a: 1'
cl add -A
cl commit -q -m "Mention $PRIV"
door --dry-run scanname
[[ $rc != 0 && $out == *"FAIL text $(cl rev-parse --short=7 HEAD) name"* ]] && ok "a private name in a commit message: FAIL text <short sha> name" || bad "scan name: rc=$rc $out"
cl checkout -q clean
cl branch -q -f scanok clean
reset_stubs
STUB_SSH_DOWN=1 door scanok
[[ $rc != 0 && $out == *'FAIL scan host'* && ! -e $t/endpoint.git/refs/heads/scanok ]] && ok "the check host unreachable: FAIL scan host, nothing pushed" || bad "ssh down: rc=$rc $out"
STUB_SSH_NOSTORE=1 door scanok
[[ $rc != 0 && $out == *'FAIL scan patterns openbao'* && ! -e $t/endpoint.git/refs/heads/scanok ]] && ok "the store unreadable on the host: FAIL scan patterns openbao, nothing pushed" || bad "no store: rc=$rc $out"
rc=0
out=$(cd "$CL" && env -u DOOR_SCAN_SSH_KEY GH_TOKEN="$G_TOK" "$HD" --dry-run scanok 2>&1 </dev/null) || rc=$?
[[ $rc != 0 && $out == *'FAIL entry door-scan'* && $out == *'FAIL scan host'* ]] && ok "the door-scan entry missing: FAIL entry door-scan, FAIL scan host" || bad "no entry: rc=$rc $out"
rc=0
out=$(cd "$CL" && env -u GH_TOKEN DOOR_SCAN_SSH_KEY="$KEYB" DOOR_SCAN_TARGET=o${AT}h.invalid DOOR_SCAN_KNOWN_HOST='h.invalid ssh-ed25519 AAAA' "$HD" scanok 2>&1 </dev/null) || rc=$?
[[ $rc != 0 && $out == *'FAIL entry github'* && ! -e $t/endpoint.git/refs/heads/scanok ]] && ok "a push without GH_TOKEN gives FAIL entry github, nothing pushed" || bad "no gh token, rc=$rc $out"

# ---- public routes (spec "Public routes need a live Access application")
python3 tools/door/test/stub-access "$t/state/access.json" >"$t/state/access.port" &
ACCPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $t/state/access.port ]] && break; sleep 0.3; done
port=$(head -1 "$t/state/access.port")
export DOOR_CF_API="http://127.0.0.1:$port"
printf '[{"name":"k3s-access-other.chill-town.de","domain":"other.chill-town.de"}]' >"$t/state/access.json"
pub_route() { put apps/tools/demo/public.yaml "apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: public
  namespace: demo
  annotations:
    homelab.io/public-dns: \"true\"
spec:
  parentRefs:
    - name: homelab
      namespace: gateway
      sectionName: tunnel
  hostnames:
    - \"$1\"
  rules:
    - backendRefs:
        - name: demo
          port: 80"; }
mkbranch pub-noaccess
pub_route nopub.chill-town.de
commit "Opt a route in"
door --dry-run pub-noaccess
[[ $rc != 0 && $out == *'FAIL public-dns nopub.chill-town.de no access'* ]] && ok "an opted-in route without an Access application: FAIL public-dns <host> no access" || bad "no access: rc=$rc $out"
mkbranch pub-access
pub_route other.chill-town.de
commit "Opt another route in"
door --dry-run pub-access
[[ $rc == 0 && $out == *'PLAN push pub-access'* ]] && ok "an opted-in route with k3s-access-<host> (live read): accepted" || bad "with access: rc=$rc $out"
: >"$t/state/access.json.down"
door --dry-run pub-access
[[ $rc != 0 && $out == *'FAIL public-dns access unreadable'* ]] && ok "the Access applications unreadable: FAIL public-dns access unreadable" || bad "access unreadable: rc=$rc $out"
rm -f "$t/state/access.json.down"
mkbranch pub-wild
pub_route '*.chill-town.de'
commit "Opt a wildcard in"
door --dry-run pub-wild
[[ $rc != 0 && $out == *'.chill-town.de wildcard'* && $out == *'FAIL public-dns '* ]] && ok "a wildcard opt-in: FAIL public-dns <host> wildcard" || bad "wildcard: rc=$rc $out"
# R20: a public route that only exists after rendering (a JSON manifest in the kustomization, an inline JSON6902 patch) is judged like a plain one
mkbranch pub-json
put apps/tools/demo/public.json '{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"pubjson","namespace":"demo","annotations":{"homelab.io/public-dns":"true"}},"spec":{"parentRefs":[{"name":"homelab","namespace":"gateway","sectionName":"tunnel"}],"hostnames":["nojson.chill-town.de"],"rules":[{"backendRefs":[{"name":"demo","port":80}]}]}}'
put apps/tools/demo/kustomization.yaml 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - externalsecret.yaml
  - route.yaml
  - public.json'
commit "Publish a JSON route"
door --dry-run pub-json
[[ $rc != 0 && $out == *'FAIL public-dns nojson.chill-town.de no access'* ]] && ok "a public route in a JSON manifest of the kustomization, without an Access application: FAIL public-dns <host> no access" || bad "json public: rc=$rc $out"
mkbranch pub-json6902
put apps/tools/demo/kustomization.yaml 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - externalsecret.yaml
  - route.yaml
patches:
  - target:
      kind: HTTPRoute
      name: demo
    patch: |-
      - op: add
        path: /metadata/annotations
        value: {}
      - op: add
        path: /metadata/annotations/homelab.io~1public-dns
        value: "true"
      - op: replace
        path: /spec/hostnames/0
        value: nopatch.chill-town.de
      - op: replace
        path: /spec/parentRefs/0/sectionName
        value: tunnel'
commit "Opt the route in by a patch"
door --dry-run pub-json6902
[[ $rc != 0 && $out == *'FAIL public-dns nopatch.chill-town.de no access'* ]] && ok "an opt-in added by an inline JSON6902 patch, without an Access application: FAIL public-dns <host> no access" || bad "json6902 public: rc=$rc $out"
printf '[{"name":"k3s-access-nopatch.chill-town.de","domain":"nopatch.chill-town.de"}]' >"$t/state/access.json"
door --dry-run pub-json6902
[[ $rc == 0 && $out != *'no access'* ]] && ok "the same patch with the Access application present: accepted" || bad "json6902 with access: rc=$rc $out"
printf '[{"name":"k3s-access-other.chill-town.de","domain":"other.chill-town.de"}]' >"$t/state/access.json"
mkbranch tun-nohost
put apps/tools/demo/t.yaml 'apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: t
  namespace: demo
spec:
  parentRefs:
    - name: homelab
      namespace: gateway
      sectionName: tunnel
  rules:
    - backendRefs:
        - name: demo
          port: 80'
commit "Attach a route to the tunnel without a host"
door --dry-run tun-nohost
[[ $rc != 0 && $out == *'FAIL tunnel-route demo/t no hostname'* ]] && ok "a tunnel route without hostnames: FAIL tunnel-route <ns>/<name> no hostname" || bad "tunnel nohost: rc=$rc $out"
rc=0
out=$(cd "$CL" && env GH_TOKEN="$G_TOK" DOOR_SCAN_SSH_KEY="$KEYB" DOOR_SCAN_TARGET=o${AT}h.invalid DOOR_SCAN_KNOWN_HOST='h.invalid ssh-ed25519 AAAA' HOMELAB_DOOR_TEST=1 DOOR_CF_API="$DOOR_CF_API" "$HD" --dry-run pub-access 2>&1 </dev/null) || rc=$?
[[ $rc != 0 && $out == *'FAIL public-dns access unreadable'* ]] && ok "no Access token in the environment gives FAIL public-dns access unreadable" || bad "no access token, rc=$rc $out"
door --dry-run clean
[[ $rc == 0 ]] && ok "a range without an opted-in route needs no Access read" || bad "clean again: rc=$rc $out"

# ---- merge allowlist (spec "Merge allowlist")
add_pr() { # add_pr <n> <branch>: the PR head is the branch tip, reachable at refs/pull/<n>/head of the endpoint
  local sha
  sha=$(cl rev-parse "refs/heads/$2")
  git -C "$t/endpoint.git" fetch -q "$CL" "refs/heads/$2:refs/heads/$2-pr" 2>/dev/null || git -C "$t/endpoint.git" fetch -q "$CL" "$sha"
  git -C "$t/endpoint.git" update-ref "refs/pull/$1/head" "$sha"
  python3 - "$t/state/gh-state.json" "$1" "$sha" "${3:-success}" <<'PYX'
import json, sys
p, n, sha, concl = sys.argv[1:]
s = json.load(open(p))
s["pulls"][n] = {"state": "open", "base": {"ref": "main", "repo": {"full_name": "Izzetee/homelab"}}, "head": {"sha": sha, "repo": {"full_name": "Izzetee/homelab"}}}
s["checks"][sha] = [{"name": "ci-ok", "app": {"slug": "github-actions"}, "status": "completed", "conclusion": concl}]
json.dump(s, open(p, "w"))
PYX
}
reset_stubs
add_pr 1 clean
door merge 1
[[ $rc == 0 && $out == *'OK merge 1'* && $out == *'NEXT changelog homelab#1'* && $(jq -r '.merge_method' "$t/state/gh-merged.json") == rebase && $(jq -r '.sha' "$t/state/gh-merged.json") == "$(cl rev-parse clean)" ]] && ok "an existing app's change: merged by API rebase on the checked head, NEXT changelog homelab#<n>" || bad "merge allowed: rc=$rc $out"
owner_case() { # owner_case <label> <branch> <pr>
  reset_stubs
  add_pr "$3" "$2"
  door merge "$3"
  [[ $rc != 0 && $out == *"FAIL merge $3 owner"* && ! -e $t/state/gh-merged.json && $(grep -c '^PUT' "$t/state/gh-requests.log" || true) == 0 ]] && ok "$1: FAIL merge <n> owner, no merge request" || bad "$1: rc=$rc $out"
}
mkbranch m-newapp
put apps/_argocd/x.yaml 'apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: x
spec:
  project: apps
  source:
    path: apps/tools/x'
commit "Add an application"
owner_case "a new Application" m-newapp 2
mkbranch m-project
put apps/platform/argocd/project.yaml 'apiVersion: v1
kind: ConfigMap
metadata:
  name: project2'
commit "Change the project"
owner_case "the AppProject" m-project 3
mkbranch m-ns
put networking/namespaces.yaml 'apiVersion: v1
kind: Namespace
metadata:
  name: demo2'
commit "Change the namespaces"
owner_case "networking/namespaces.yaml" m-ns 4
mkbranch m-store
put apps/platform/secret-store/cluster-secret-store.yaml 'kind: ClusterSecretStore
spec: {}'
put apps/platform/openbao/config/namespaces.txt 'demo
extra'
commit "Change the store"
owner_case "the ClusterSecretStore and namespaces.txt" m-store 5
for pth in AGENTS.md .agents/skills/a/SKILL.md tools/x.sh docs/a.md ci/a.sh .github/workflows/a.yml; do
  mkbranch m-guard
  put "$pth" 'x'
  commit "Touch $pth"
  owner_case "a change of $pth" m-guard 6
done
mkbranch m-two
put apps/tools/demo/a.yaml 'a: 1'
put apps/tools/other/b.yaml 'b: 1'
commit "Two app directories"
owner_case "a PR touching two app directories" m-two 7
mkbranch m-mixed
put apps/tools/demo/a.yaml 'a: 1'
put docs/a.md 'x'
commit "An app and a doc"
owner_case "a PR touching an app and a doc" m-mixed 8
mkbranch m-noapp
put apps/tools/ghost/a.yaml 'a: 1'
commit "An app directory that does not exist at main"
owner_case "a directory of an app that does not exist at main" m-noapp 9
mkbranch m-secret
c_otherapp
commit "A cross-app secret inside the allowed directory"
reset_stubs
add_pr 10 m-secret
door merge 10
[[ $rc != 0 && $out == *'FAIL externalsecret'* && ! -e $t/state/gh-merged.json ]] && ok "an allowed directory does not excuse a content rule: the merge is refused" || bad "merge content: rc=$rc $out"
reset_stubs
add_pr 11 clean failure
door merge 11
[[ $rc != 0 && $out == *'FAIL merge 11 ci-ok'* && ! -e $t/state/gh-merged.json ]] && ok "ci-ok not successful on the head: FAIL merge <n> ci-ok" || bad "ci-ok: rc=$rc $out"
reset_stubs
add_pr 12 clean
python3 - "$t/state/gh-state.json" <<'PYX'
import json, sys
s = json.load(open(sys.argv[1]))
s["pulls"]["12"]["head"]["sha"] = "f" * 40
json.dump(s, open(sys.argv[1], "w"))
PYX
door merge 12
[[ $rc != 0 && $out == *'FAIL merge 12 head'* && ! -e $t/state/gh-merged.json ]] && ok "the PR head the API names differs from the fetched head: FAIL merge <n> head" || bad "head differs: rc=$rc $out"
reset_stubs
door merge abc
[[ $rc != 0 && $out == *'FAIL door merge needs a PR number'* ]] && ok "merge needs a number" || bad "merge arg: $out"

# ---- Renovate's own pull requests (spec "The homelab door merges Renovate's own pull requests")
BOT="29139614+renovate[bot]${AT}users.noreply.github.com"
WEBFLOW="noreply${AT}github.com"
renovate_commit() { # renovate_commit <message> <committer email>: a commit authored by the bot address
  cl add -A
  GIT_AUTHOR_EMAIL=$BOT GIT_COMMITTER_EMAIL=$2 cl commit -q -m "$1"
}
add_renovate_pr() { # add_renovate_pr <n> <branch> <login> <type> <head ref> <verified true|false> <reason> [list|nolist]
  add_pr "$1" "$2"
  python3 - "$t/state/gh-state.json" "$1" "$(cl rev-list --reverse "refs/remotes/origin/main..refs/heads/$2" | tr '\n' ' ')" "$3" "$4" "$5" "$6" "$7" "${8:-list}" <<'PYX'
import json, sys
p, n, shas, login, typ, ref, verified, reason, lst = sys.argv[1:]
s = json.load(open(p))
s["pulls"][n]["user"] = {"login": login, "type": typ}
s["pulls"][n]["head"]["ref"] = ref
s.setdefault("commits", {})[n] = [] if lst == "nolist" else [{"sha": c, "commit": {"verification": {"verified": verified == "true", "reason": reason}}} for c in shas.split()]
json.dump(s, open(p, "w"))
PYX
}
renovate_case() { # renovate_case <label> <expected FAIL text> <pr>: refused, no merge request
  [[ $rc != 0 && $out == *"$2"* && ! -e $t/state/gh-merged.json && $(grep -c '^PUT' "$t/state/gh-requests.log" || true) == 0 ]] && ok "$1: $2, no merge request" || bad "$1: rc=$rc $out"
}
mkbranch r-ok
put apps/tools/demo/configmap.yaml 'apiVersion: v1
kind: ConfigMap
metadata:
  name: demo
  namespace: demo
data:
  mode: three'
renovate_commit "Update demo" "$WEBFLOW"
reset_stubs
add_renovate_pr 20 r-ok 'renovate[bot]' Bot renovate/demo-3.x true valid
door merge 20
[[ $rc == 0 && $out == *'OK merge 20'* && $(jq -r '.merge_method' "$t/state/gh-merged.json") == rebase && $(jq -r '.sha' "$t/state/gh-merged.json") == "$(cl rev-parse r-ok)" ]] && grep -q '^GET repos/Izzetee/homelab/pulls/20/commits?per_page=100$' "$t/state/gh-requests.log" && ok "a signed Renovate PR inside one app: merged by API rebase on the checked head (one commit-list read)" || bad "renovate merge: rc=$rc $out"
reset_stubs
add_renovate_pr 21 r-ok Izzetee User renovate/demo-3.x true valid
door merge 21
renovate_case "the bot address on a PR not opened by renovate[bot]" "FAIL identity $(cl rev-parse --short=7 r-ok)"
reset_stubs
add_renovate_pr 22 r-ok 'renovate[bot]' User renovate/demo-3.x true valid
door merge 22
renovate_case "login renovate[bot] but a user account" "FAIL identity"
reset_stubs
add_renovate_pr 23 r-ok 'renovate[bot]' Bot someone/branch true valid
door merge 23
renovate_case "renovate[bot] PR from a branch outside renovate/" "FAIL identity"
reset_stubs
add_renovate_pr 24 r-ok 'renovate[bot]' Bot renovate/demo-3.x false unsigned
door merge 24
renovate_case "a bot-authored commit GitHub reports unverified" "FAIL identity"
reset_stubs
add_renovate_pr 25 r-ok 'renovate[bot]' Bot renovate/demo-3.x false invalid
door merge 25
renovate_case "a bot-authored commit with another verification reason" "FAIL identity"
reset_stubs
add_renovate_pr 26 r-ok 'renovate[bot]' Bot renovate/demo-3.x true valid nolist
door merge 26
renovate_case "a bot-authored commit missing from GitHub's commit list" "FAIL identity"
mkbranch r-pushed
put apps/tools/demo/configmap.yaml 'apiVersion: v1
kind: ConfigMap
metadata:
  name: demo
  namespace: demo
data:
  mode: four'
renovate_commit "Update demo again" "$(printf 'someone%s' "${AT}example.com")"
reset_stubs
add_renovate_pr 27 r-pushed 'renovate[bot]' Bot renovate/demo-4.x true valid
door merge 27
renovate_case "the bot author with another committer than web-flow" "FAIL identity"
reset_stubs
door r-ok
[[ $rc != 0 && $out == *'FAIL identity'* && ! -e $t/endpoint.git/refs/heads/r-ok ]] && ok "a push of the bot-authored commit: FAIL identity (the strict rule), nothing pushed" || bad "bot push: rc=$rc $out"
mkbranch r-mixed
put apps/tools/demo/configmap.yaml 'apiVersion: v1
kind: ConfigMap
metadata:
  name: demo
  namespace: demo
data:
  mode: five'
renovate_commit "Update demo a third time" "$WEBFLOW"
put apps/tools/demo/other.yaml 'a: 1'
commit "A personal commit on top"
reset_stubs
add_renovate_pr 28 r-mixed 'renovate[bot]' Bot renovate/demo-5.x true valid
door merge 28
[[ $rc == 0 && $out == *'OK merge 28'* ]] && ok "a Renovate PR with one more personal commit: the personal commit keeps the strict rule and passes" || bad "renovate mixed: rc=$rc $out"
mkbranch r-docs
put docs/a.md 'x'
renovate_commit "Update docs" "$WEBFLOW"
reset_stubs
add_renovate_pr 29 r-docs 'renovate[bot]' Bot renovate/docs-1.x true valid
door merge 29
renovate_case "a renovate[bot] PR outside apps/tools/" "FAIL merge 29 owner"
[[ $(grep -c 'pulls/29/commits' "$t/state/gh-requests.log" || true) == 0 ]] && ok "the allowlist is checked before the commit list is read" || bad "commit list read before the allowlist"
grep -qE '^(GET|POST|PATCH|PUT) repos/Izzetee/homelab/(pulls|commits)' "$t/state/gh-requests.log" || true
! grep -qE 'contents|git/' "$t/state/gh-requests.log" && ok "no content or git/ API path was ever called" || bad "forbidden API path"

# ---- PR text
reset_stubs
printf 'Change the demo mode\n' >"$t/title.txt"
printf 'Switches the mode of the demo application.\n' >"$t/body.txt"
door pr clean "$t/title.txt" "$t/body.txt"
[[ $rc == 0 && $out == *'OK pr #101' && $(jq -r '.head' "$t/state/gh-created.json") == clean && $(jq -r '.base' "$t/state/gh-created.json") == main && $(jq -r '.title' "$t/state/gh-created.json") == 'Change the demo mode' ]] && ok "pr: checked text, created through the API (head, base, title)" || bad "pr: rc=$rc $out"
door pr-edit 101 "$t/title.txt" "$t/body.txt"
[[ $rc == 0 && $out == *'OK pr-edit #101' && -s $t/state/gh-edited.json ]] && ok "pr-edit: the checked text is sent" || bad "pr-edit: rc=$rc $out"
printf 'See %s for details\n' "$A5" >"$t/body2.txt"
reset_stubs
door pr clean "$t/title.txt" "$t/body2.txt"
[[ $rc != 0 && $out == *'FAIL text address'* && ! -e $t/state/gh-created.json ]] && ok "PR text with an address literal: FAIL text address, nothing sent" || bad "pr address: rc=$rc $out"
printf 'Mentions %s here\n' "$PRIV" >"$t/body3.txt"
door --check-text "$t/title.txt" "$t/body3.txt"
[[ $rc != 0 && $out == *'FAIL text text.txt name'* ]] && ok "PR text with a private name: refused by the extra check (FAIL text text.txt name)" || bad "pr private: rc=$rc $out"
printf 'Mentions %s here\n' "$STORE" >"$t/body4.txt"
door --check-text "$t/title.txt" "$t/body4.txt"
[[ $rc != 0 && $out == *'FAIL scan push/text.txt keys='* && $out != *"$STORE"* ]] && ok "PR text with a store value: FAIL scan push/text.txt (no value)" || bad "pr value: rc=$rc $out"
door --check-text "$t/title.txt" "$t/body.txt"
[[ $rc == 0 && $out == 'OK text' ]] && ok "clean PR text: OK text" || bad "clean text: rc=$rc $out"

# ---- the hook: a manual `git push` runs the same checks and only for the fixed endpoint
git init -q --bare "$t/elsewhere.git"
cl checkout -q clean
cl branch -q -f elsewhere clean
rc=0
out=$(cd "$CL" && entries git push "$t/elsewhere.git" elsewhere 2>&1 </dev/null) || rc=$?
[[ $rc != 0 && $out == *'FAIL door push target'* && -z $(git -C "$t/elsewhere.git" for-each-ref) ]] && ok "git push to another repository: the hook refuses the target (FAIL door push target), nothing arrives" || bad "hook target: rc=$rc $out"
cl remote set-url --push origin "$t/elsewhere.git"
rc=0
out=$(cd "$CL" && entries git push origin elsewhere 2>&1 </dev/null) || rc=$?
cl config --unset remote.origin.pushurl
[[ $rc != 0 && ( $out == *'FAIL door origin'* || $out == *'FAIL door push target'* ) && -z $(git -C "$t/elsewhere.git" for-each-ref) ]] && ok "a push URL other than the fixed endpoint: refused" || bad "hook pushurl: rc=$rc $out"
cl checkout -q scanval
rc=0
out=$(cd "$CL" && entries git push "$t/endpoint.git" scanval 2>&1 </dev/null) || rc=$?
[[ $rc != 0 && $out == *'FAIL scan push/range.patch'* && ! -e $t/endpoint.git/refs/heads/scanval ]] && ok "git push in the clone: the hook runs the door's checks and stops a bad branch" || bad "hook bad: rc=$rc $out"
cl checkout -q clean
cl branch -q -f hookok clean
cl commit -q --allow-empty -m "Another clean change"
cl branch -q -f hookok HEAD
rc=0
out=$(cd "$CL" && entries git push "$t/endpoint.git" hookok 2>&1 </dev/null) || rc=$?
[[ $rc == 0 && -n $(git -C "$t/endpoint.git" rev-parse -q --verify refs/heads/hookok || true) ]] && ok "git push in the clone: a clean branch to the endpoint passes the hook" || bad "hook ok: rc=$rc $out"
rc=0
out=$(cd "$CL" && entries git push "$t/endpoint.git" HEAD:main 2>&1 </dev/null) || rc=$?
[[ $rc != 0 && $out == *'FAIL door no push to main'* ]] && ok "git push to main: refused by the hook" || bad "hook main: rc=$rc $out"

# ---- value-free: canaries in no output, no stub argument list, no file
cl checkout -q -B canary refs/remotes/origin/main
put apps/tools/demo/c.yaml 'c: 1'
commit "A clean canary run"
reset_stubs
door canary
for c in "$G_TOK" "$A_TOK" "$KEYB" "$(printf 'canary-ssh-key-%s' "$Q")"; do
  if [[ $out == *"$c"* ]] || grep -qF -- "$c" "$t/state/ssh-argv.log" "$t/state/gh-argv.log" "$t/state/gh-requests.log" 2>/dev/null || grep -rqF -- "$c" "$t/tmp" "$CL/.git" 2>/dev/null; then bad "a canary reached the output, a stub's arguments, the clone's git directory or a temp file"; fi
done
[[ $rc == 0 ]] && ok "a clean push with canary credentials in the environment: no token, key or value in the output, any stub's arguments, a temp file or the git directory" || bad "canary run: rc=$rc $out"
[[ -z $(ls -A "$t/tmp") ]] && ok "no temp directory is left behind" || bad "temp left: $(ls "$t/tmp")"
if grep -nE 'set -x|printenv|--no-verify' tools/door/door.sh tools/door/launcher tools/door/check.py >/dev/null; then bad "tracing, printenv or --no-verify in the door"; else ok "no tracing, no printenv, no --no-verify"; fi
if grep -nE 'contents/|git/(refs|trees|blobs|commits)' tools/door/door.sh >/dev/null; then bad "a contents or git/ API path in the door"; else ok "no contents or git/ API path in the door code"; fi

[[ $fails -eq 0 ]] && echo "test-door OK" || { echo "test-door: $fails failure(s)"; exit 1; }
