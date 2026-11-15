#!/usr/bin/env bash
# homelab-door install [--dry-run] | uninstall | doctor | --dry-run <branch> | <branch> [--rebased] | --check-tree [<rev>] | --check <range>|--all
#              --check-text <file>... | pr <branch> <title-file> <body-file> | pr-edit <n> <title-file> <body-file> | merge <n> | --hook <remote> <url>
# Started by the launcher, which provides DOOR_SHA, DOOR_URL, DOOR_CODE, DOOR_SRC, DOOR_CLONE and DOOR_LAUNCHER.
set -euo pipefail
umask 077

: "${DOOR_SHA:?}" "${DOOR_URL:?}" "${DOOR_CODE:?}" "${DOOR_CLONE:?}" "${DOOR_LAUNCHER:?}"
HL=$DOOR_CLONE
CHK=$DOOR_CODE/tools/door/check.py
OWN_EMAIL='18075479+Izzetee@users.noreply.github.com'
EXPECT_CRED=$'\n!gh auth git-credential'
CRED_KEY='credential.https://github.com.helper'
ZERO=0000000000000000000000000000000000000000
REPO=Izzetee/homelab
TMP=$(mktemp -d "${TMPDIR:-/tmp}/homelab-door-run.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM HUP

die() { echo "FAIL door $1"; exit 1; }
hl() { git -C "$HL" "$@"; }
# objects fetched during a run go to a throwaway directory; the clone's own objects are read through an alternate
if [[ ${1:-} != install && ${1:-} != uninstall ]]; then
  mkdir -p "$TMP/objects"
  GIT_ALTERNATE_OBJECT_DIRECTORIES=$(git -C "$HL" rev-parse --absolute-git-dir)/objects
  export GIT_OBJECT_DIRECTORY=$TMP/objects GIT_ALTERNATE_OBJECT_DIRECTORIES
fi
gitdir() { hl rev-parse --absolute-git-dir; }
hook_text() { printf '#!/bin/sh\nexec "%s" --hook "$@"' "$1"; }
bin_dir() { echo "${HOME:?}/.local/bin"; }
installed_launcher() { # a path only: nothing is created (dry runs change no state)
  local d
  d=$(bin_dir)
  if [[ -d $d ]]; then d=$(cd "$d" && pwd -P); fi
  echo "$d/homelab-door"
}
need_entry() { # need_entry <name> <var>...: the store entry's variables are in the environment
  local n=$1 v
  shift
  for v in "$@"; do [[ -n ${!v:-} ]] || { echo "FAIL entry $n"; return 1; }; done
}
cred_values() { hl config --local --get-all "$CRED_KEY" 2>/dev/null || true; }
preflight() {
  [[ $(cred_values) == "$EXPECT_CRED" ]] || die "credential helper differs"
  [[ $(hl config --local --get user.name 2>/dev/null || true) == Izzetee && $(hl config --local --get user.email 2>/dev/null || true) == "$OWN_EMAIL" ]] || die "identity differs"
}
# the objects of main are fetched into the run's throwaway object directory; no ref, no FETCH_HEAD and no clone object changes
fetch_base() { hl fetch -q --no-tags --no-write-fetch-head "$DOOR_URL" "$DOOR_SHA" >/dev/null 2>&1 || die "source"; }
AT=@
legit_target() { # legit_target <url>: the fixed endpoint in its HTTPS and SSH forms, or what a local rewrite rule makes of it
  local u=$1 rewritten
  [[ -n $u ]] || return 1
  [[ $u == "$DOOR_URL" || $u == "${DOOR_URL%.git}" || $u == "git${AT}github.com:Izzetee/homelab.git" || $u == "ssh://git${AT}github.com/Izzetee/homelab.git" ]] && return 0
  rewritten=$(git ls-remote --get-url "$DOOR_URL" 2>/dev/null || true)
  [[ -n $rewritten && $u == "$rewritten" ]]
}

# ---- install, uninstall, doctor ---------------------------------------------------------------------------------------------------------
install_main() {
  local dry=0 bin want hook gd launcher
  [[ ${1:-} != --dry-run ]] || dry=1
  [[ -z $(hl config --get core.hooksPath 2>/dev/null || true) ]] || die "hooksPath"
  bin=$(bin_dir)
  [[ $dry == 1 ]] || mkdir -p "$bin"
  launcher=$(installed_launcher)
  gd=$(gitdir)
  hook=$gd/hooks/pre-push
  want=$(hook_text "$launcher")
  if [[ -f $launcher ]] && cmp -s "$launcher" "$DOOR_CODE/tools/door/launcher"; then echo "SKIP launcher"
  elif [[ $dry == 1 ]]; then echo "PLAN install launcher $bin/homelab-door"
  else install -m 0755 "$DOOR_CODE/tools/door/launcher" "$launcher"; echo "OK   launcher installed"; fi
  if [[ -f $hook && $(cat "$hook") == "$want" && -x $hook ]]; then echo "SKIP hook"
  elif [[ $dry == 1 ]]; then echo "PLAN install hook$([[ -f $hook ]] && echo ' (the previous hook is recorded)')"
  else
    mkdir -p "$gd/hooks"
    if [[ -f $hook && ! -e $gd/hooks/pre-push.previous ]]; then cp -p "$hook" "$gd/hooks/pre-push.previous"; echo "OK   previous hook recorded"; fi
    printf '%s' "$want" >"$hook"
    chmod 755 "$hook"
    echo "OK   hook installed"
  fi
  if [[ $(hl config --local --get user.name 2>/dev/null || true) == Izzetee && $(hl config --local --get user.email 2>/dev/null || true) == "$OWN_EMAIL" ]]; then echo "SKIP identity"
  elif [[ $dry == 1 ]]; then echo "PLAN set identity"
  else hl config --local user.name Izzetee; hl config --local user.email "$OWN_EMAIL"; echo "OK   identity set"; fi
  if [[ $(cred_values) == "$EXPECT_CRED" ]]; then echo "SKIP credential helper"
  elif [[ $dry == 1 ]]; then echo "PLAN set credential helper"
  else
    hl config --local --unset-all "$CRED_KEY" 2>/dev/null || true
    hl config --local --add "$CRED_KEY" ""
    hl config --local --add "$CRED_KEY" '!gh auth git-credential'
    echo "OK   credential helper set"
  fi
}

uninstall_main() {
  local gd hook
  gd=$(gitdir)
  hook=$gd/hooks/pre-push
  if [[ -f $gd/hooks/pre-push.previous ]]; then mv -f "$gd/hooks/pre-push.previous" "$hook"; echo "OK   previous hook restored"
  elif [[ -f $hook ]]; then rm -f "$hook"; echo "OK   hook removed"
  else echo "SKIP no hook"; fi
}

doctor_main() {
  local rc=0 gd launcher
  gd=$(gitdir)
  launcher=$(installed_launcher)
  echo "OK door fixed endpoint ${DOOR_SHA:0:12}"
  echo "OK door push URL"
  if [[ -f $launcher ]] && cmp -s "$launcher" "$DOOR_CODE/tools/door/launcher"; then echo "OK door launcher"; else echo "FAIL launcher stale"; rc=1; fi
  if [[ -x $gd/hooks/pre-push && $(cat "$gd/hooks/pre-push") == "$(hook_text "$launcher")" ]]; then echo "OK door hook"; else echo "FAIL hook"; rc=1; fi
  if need_entry door-scan DOOR_SCAN_SSH_KEY DOOR_SCAN_TARGET DOOR_SCAN_KNOWN_HOST; then
    printf 'doctor probe\n' >"$TMP/probe.txt"
    if scan_host push/text.txt "$TMP/probe.txt" >/dev/null; then echo "OK door scan host"; else echo "FAIL scan host"; rc=1; fi
  else rc=1; fi
  need_entry github GH_TOKEN && echo "OK entry github" || rc=1
  return "$rc"
}

# ---- extra checks -----------------------------------------------------------------------------------------------------------------------
# scan_host <member> <file>: sends the file for the extra checks; 0 only with `OK scan files=1`
scan_host() {
  local member=$1 f=$2 d=$TMP/scan out
  need_entry door-scan DOOR_SCAN_SSH_KEY DOOR_SCAN_TARGET DOOR_SCAN_KNOWN_HOST || { echo "FAIL scan host"; return 1; }
  rm -rf "$d"
  mkdir -p "$d/tar/$(dirname "$member")"
  cp "$f" "$d/tar/$member"
  COPYFILE_DISABLE=1 tar -C "$d/tar" -cf "$d/in.tar" "${member%%/*}"
  printf '%s' "$DOOR_SCAN_SSH_KEY" | base64 -d >"$d/key" 2>/dev/null || { echo "FAIL scan host"; return 1; }
  printf '%s\n' "$DOOR_SCAN_KNOWN_HOST" >"$d/known"
  chmod 600 "$d/key" "$d/known"
  out=$(ssh -i "$d/key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$d/known" \
    "$DOOR_SCAN_TARGET" <"$d/in.tar" 2>/dev/null) || true
  rm -rf "$d"
  if grep -qE '^OK scan files=1 patterns=[0-9]+$' <<<"$out" && ! grep -q '^FAIL ' <<<"$out"; then return 0; fi
  grep -E '^FAIL (scan|text) ' <<<"$out" || echo "FAIL scan host"
  return 1
}

# ---- checks -------------------------------------------------------------------------------------------------------------------------------
REVS=() TIP="" N=0
check_gitleaks() {
  rm -f "$TMP/gl.json"
  gitleaks git --log-opts="${REVS[*]}" --config "$DOOR_CODE/.gitleaks.toml" --redact --no-banner --log-level error --exit-code 0 \
    --report-format json --report-path "$TMP/gl.json" "$HL" >/dev/null 2>&1 || { echo "FAIL gitleaks run"; return 1; }
  [[ -f $TMP/gl.json ]] || { echo "FAIL gitleaks report missing"; return 1; }
  python3 "$CHK" gitleaks "$TMP/gl.json" || return 1
}
# patch_frame <outfile> <ref>...: message-free log, one msg line per commit, one ref line per ref
patch_frame() {
  local out=$1 c
  shift
  : >"$out"
  if [[ $N -gt 0 ]]; then
    hl log -p --no-color --root --no-ext-diff --no-textconv --format='commit %H' "${REVS[@]}" >"$out" 2>/dev/null || { echo "FAIL door range patch"; return 1; }
    for c in $(hl rev-list "${REVS[@]}"); do printf 'msg %s %s\n' "$c" "$(hl log -1 --format=%B "$c" | base64 | tr -d '\n')" >>"$out"; done
  fi
  for c in "$@"; do printf 'ref %s\n' "$c" >>"$out"; done
  [[ -s $out ]] || { echo "FAIL door range patch"; return 1; }
}
# run_checks <skip-scan 0|1> [--all-mode] <ref name>...: REVS and TIP are set; prints the lines; 0 = every check passed
run_checks() {
  local skip=$1 mode=${2:-} fail=0 out rc r
  shift 2 || shift $#
  fetch_base
  rc=0
  out=$(python3 "$CHK" commits "$HL" "${REVS[@]}" ${mode:+"$mode"}) || rc=$?
  grep '^FAIL ' <<<"$out" || true
  N=$(sed -n 's/^STAT commits=//p' <<<"$out")
  [[ $N =~ ^[0-9]+$ ]] || { echo "FAIL door check could not run"; return 1; }
  [[ $rc == 0 ]] || fail=1
  rc=0
  out=$(python3 "$CHK" tree "$HL" "$DOOR_SHA" "$TIP") || rc=$?
  grep '^FAIL ' <<<"$out" || true
  grep -q '^STAT routes=' <<<"$out" || { echo "FAIL door tree check could not run"; return 1; }
  [[ $rc == 0 ]] || fail=1
  for r in "$@"; do python3 "$CHK" ref "$r" || fail=1; done
  if [[ $N -gt 0 ]]; then check_gitleaks || fail=1; fi
  [[ $fail == 0 ]] || return 1
  if [[ $skip != 1 ]]; then
    patch_frame "$TMP/range.patch" "$@" || return 1
    scan_host push/range.patch "$TMP/range.patch" || return 1
  fi
  [[ $N -gt 0 ]] || { echo "SKIP door no new commits"; return 0; }
  echo "OK door commits=$N"
}

# ---- push ---------------------------------------------------------------------------------------------------------------------------------
REMOTE_SHA=""
branch_range() { # branch_range <branch> <rebased 0|1>
  local b=$1 rebased=$2
  [[ $b =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $b != *..* ]] || die "bad branch name"
  [[ $b != main ]] || die "no push to main"
  TIP=$(hl rev-parse --verify -q "refs/heads/$b^{commit}" 2>/dev/null) || die "branch $b missing"
  REMOTE_SHA=$(hl ls-remote "$DOOR_URL" "refs/heads/$b" 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -n $REMOTE_SHA && $REMOTE_SHA != "$TIP" && $rebased == 0 ]]; then
    hl cat-file -e "$REMOTE_SHA^{commit}" 2>/dev/null && hl merge-base --is-ancestor "$REMOTE_SHA" "$TIP" 2>/dev/null || die "not a fast-forward (use --rebased on a PR branch)"
  fi
  fetch_base
  REVS=("$DOOR_SHA..$TIP")
}
stamp_file() { echo "$(gitdir)/homelab-door.checked"; }
push_main() { # push_main <branch> <real|dry> [--rebased]
  local b=$1 mode=$2 rebased=0 lease=() rc=0
  [[ ${3:-} != --rebased ]] || rebased=1
  preflight
  branch_range "$b" "$rebased"
  if [[ $REMOTE_SHA == "$TIP" ]]; then echo "SKIP $b up to date"; return 0; fi
  run_checks 0 "" "refs/heads/$b" || exit 1
  if [[ $mode == dry ]]; then echo "PLAN push $b commits=$N"; return 0; fi
  need_entry github GH_TOKEN || exit 1
  [[ $rebased == 0 || -z $REMOTE_SHA ]] || lease=("--force-with-lease=refs/heads/$b:$REMOTE_SHA")
  printf '%s' "$TIP" >"$(stamp_file)"
  hl push ${lease[@]+"${lease[@]}"} "$DOOR_URL" "refs/heads/$b:refs/heads/$b" >"$TMP/push.out" 2>&1 || rc=$?
  rm -f "$(stamp_file)"
  if [[ $rc != 0 ]]; then
    ! grep -q 'GH006' "$TMP/push.out" || echo "FAIL door protected branch"
    die "git push failed"
  fi
  echo "OK pushed $b commits=$N"
}

hook_main() { # hook_main <remote> <url>; stdin: <local ref> <local sha> <remote ref> <remote sha> per line
  local lref lsha rref fail=0 skip st
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  legit_target "${2:-}" || die "push target"
  st=$(stamp_file)
  fetch_base
  while read -r lref lsha rref _; do
    [[ -n ${lref:-} ]] || continue
    if [[ $lsha == "$ZERO" ]]; then echo "SKIP $rref delete"; continue; fi
    if [[ $rref == refs/heads/main ]]; then echo "FAIL door no push to main"; fail=1; continue; fi
    TIP=$lsha
    REVS=("$DOOR_SHA..$lsha")
    skip=0
    [[ -f $st && $(cat "$st") == "$lsha" ]] && skip=1
    run_checks "$skip" "" "$rref" || fail=1
  done
  [[ $fail == 0 ]] || exit 1
}

check_tree_main() { # check_tree_main [<rev>]
  local rev=${1:-HEAD} out rc=0
  [[ $rev =~ ^[0-9A-Za-z._/^~@-]+$ ]] || die "bad revision"
  TIP=$(hl rev-parse --verify -q "$rev^{commit}" 2>/dev/null) || die "revision missing"
  fetch_base
  out=$(python3 "$CHK" tree "$HL" "$DOOR_SHA" "$TIP" --all) || rc=$?
  grep '^FAIL ' <<<"$out" || true
  grep -q '^STAT routes=' <<<"$out" || { echo "FAIL door tree check could not run"; exit 1; }
  [[ $rc == 0 ]] || exit 1
  echo "OK door tree ${TIP:0:7}"
}

check_main() { # check_main <range>|--all
  local mode=""
  if [[ ${1:-} == --all ]]; then REVS=(--all); mode=--all-mode; TIP=HEAD
  else
    [[ ${1:-} =~ ^[0-9A-Za-z._/^~@:-]+(\.\.[0-9A-Za-z._/^~@:-]+)?$ ]] || die "bad range"
    REVS=("$1")
    TIP=${1##*..}
  fi
  fetch_base
  local out rc=0
  out=$(python3 "$CHK" commits "$HL" "${REVS[@]}" ${mode:+"$mode"}) || rc=$?
  grep '^FAIL ' <<<"$out" || true
  N=$(sed -n 's/^STAT commits=//p' <<<"$out")
  [[ $N =~ ^[0-9]+$ ]] || { echo "FAIL door check could not run"; exit 1; }
  [[ $N == 0 ]] || check_gitleaks || rc=1
  [[ $rc == 0 ]] || exit 1
  echo "OK door commits=$N"
}

check_text() { # check_text <file>...
  local f
  [[ $# -ge 1 ]] || die "check-text needs a file"
  for f in "$@"; do [[ -f $f ]] || die "text file missing"; done
  python3 "$CHK" text "$@" || return 1
  cat "$@" >"$TMP/text.txt"
  scan_host push/text.txt "$TMP/text.txt" || return 1
  echo "OK text"
}

# ---- GitHub API (the only paths of this tool: no contents, no git/) ---------------------------------------------------------------------
gh_api_allowed() { # gh_api_allowed <method> <path>
  local m=$1 p=$2 base="repos/$REPO"
  [[ $m == GET && $p =~ ^$base/pulls/[0-9]+$ ]] && return 0
  [[ $m == GET && $p =~ ^$base/commits/[0-9a-f]{40}/check-runs$ ]] && return 0
  [[ $m == POST && $p == "$base/pulls" ]] && return 0
  [[ $m == PATCH && $p =~ ^$base/pulls/[0-9]+$ ]] && return 0
  [[ $m == PUT && $p =~ ^$base/pulls/[0-9]+/merge$ ]] && return 0
  return 1
}
gh_call() { # gh_call <method> <path> [stdin json]
  local m=$1 p=$2
  gh_api_allowed "$m" "$p" || die "endpoint not allowed"
  need_entry github GH_TOKEN || exit 1
  if [[ -n ${3:-} ]]; then printf '%s' "$3" | gh api --method "$m" --input - "$p"; else gh api --method "$m" "$p"; fi
}

pr_main() { # pr_main <branch> <title-file> <body-file>
  local b=$1 tf=$2 bf=$3 body json n
  [[ $b =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $b != *..* ]] || die "bad branch name"
  [[ -f $tf && -f $bf ]] || die "pr text file missing"
  [[ $(wc -l <"$tf" | tr -d ' ') -le 1 ]] || die "pr title must be one line"
  python3 "$CHK" ref "$b" || exit 1
  check_text "$tf" "$bf" || exit 1
  cp "$bf" "$TMP/body.txt"
  json=$(jq -nc --rawfile t "$tf" --rawfile b "$TMP/body.txt" --arg h "$b" '{title: ($t | rtrimstr("\n")), body: $b, head: $h, base: "main"}')
  body=$(gh_call POST "repos/$REPO/pulls" "$json" 2>/dev/null) || die "pr create failed"
  n=$(jq -r '.number // empty' <<<"$body")
  [[ $n =~ ^[0-9]+$ ]] || die "pr create failed"
  echo "OK pr #$n"
}
pr_edit_main() { # pr_edit_main <n> <title-file> <body-file>
  local n=$1 tf=$2 bf=$3 json
  [[ $n =~ ^[0-9]+$ ]] || die "pr-edit needs a PR number"
  [[ -f $tf && -f $bf ]] || die "pr text file missing"
  [[ $(wc -l <"$tf" | tr -d ' ') -le 1 ]] || die "pr title must be one line"
  check_text "$tf" "$bf" || exit 1
  cp "$bf" "$TMP/body.txt"
  json=$(jq -nc --rawfile t "$tf" --rawfile b "$TMP/body.txt" '{title: ($t | rtrimstr("\n")), body: $b}')
  gh_call PATCH "repos/$REPO/pulls/$n" "$json" >/dev/null 2>&1 || die "pr edit failed"
  echo "OK pr-edit #$n"
}

merge_main() { # merge_main <n>
  local n=${1:-} p pr sha got ok msg
  [[ $n =~ ^[0-9]+$ ]] || die "merge needs a PR number"
  p="repos/$REPO/pulls/$n"
  pr=$(gh_call GET "$p" 2>/dev/null) || { echo "FAIL merge $n unreadable"; exit 1; }
  [[ $(jq -r '.state' <<<"$pr") == open && $(jq -r '.base.ref' <<<"$pr") == main ]] || { echo "FAIL merge $n not an open PR into main"; exit 1; }
  [[ $(jq -r '.head.repo.full_name // "none"' <<<"$pr") == "$(jq -r '.base.repo.full_name' <<<"$pr")" ]] || { echo "FAIL merge $n fork"; exit 1; }
  sha=$(jq -r '.head.sha' <<<"$pr")
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL merge $n head"; exit 1; }
  fetch_base
  got=$(hl ls-remote "$DOOR_URL" "refs/pull/$n/head" 2>/dev/null | awk '{print $1}' | head -1)
  [[ $got == "$sha" ]] || { echo "FAIL merge $n head"; exit 1; }
  hl fetch -q --no-tags --no-write-fetch-head "$DOOR_URL" "pull/$n/head" >/dev/null 2>&1 || { echo "FAIL merge $n head"; exit 1; }
  hl cat-file -e "$sha^{commit}" 2>/dev/null || { echo "FAIL merge $n head"; exit 1; }
  # the allowlist first: the paths of every commit of the PR (a path inside one existing app directory only)
  hl log -z --name-only --no-renames --format= "$DOOR_SHA..$sha" | tr '\0' '\n' >"$TMP/paths.txt"
  python3 "$CHK" merge-paths "$HL" "$DOOR_SHA" "$n" <"$TMP/paths.txt" || exit 1
  TIP=$sha
  REVS=("$DOOR_SHA..$sha")
  run_checks 0 "" "refs/heads/pull-$n" || exit 1
  ok=$(gh_call GET "repos/$REPO/commits/$sha/check-runs" 2>/dev/null | jq -r '[.check_runs[] | select(.name == "ci-ok" and .app.slug == "github-actions" and .status == "completed" and .conclusion == "success")] | length') || ok=0
  [[ ${ok:-0} -ge 1 ]] || { echo "FAIL merge $n ci-ok"; exit 1; }
  if ! gh_call PUT "$p/merge" "$(jq -nc --arg s "$sha" '{merge_method: "rebase", sha: $s}')" >/dev/null 2>"$TMP/merge.err"; then
    msg=$(sed -n 's/^.*gh: //p' "$TMP/merge.err" | head -n 1 | tr -cd '[:print:]' | cut -c1-120)
    echo "FAIL merge $n api${msg:+: $msg}"
    exit 1
  fi
  echo "OK merge $n"
  echo "NEXT changelog homelab#$n"
}

# ---- dispatch -------------------------------------------------------------------------------------------------------------------------
[[ $# -ge 1 ]] || { sed -n '2,20p' "$0"; exit 2; }
case $1 in
  install) shift; install_main "$@" ;;
  uninstall) uninstall_main ;;
  doctor) doctor_main ;;
  --dry-run) [[ $# -eq 2 ]] || die "usage: --dry-run <branch>"; push_main "$2" dry ;;
  --hook) hook_main "${2:-}" "${3:-}" ;;
  --check-tree) [[ $# -le 2 ]] || die "usage: --check-tree [<rev>]"; check_tree_main "${2:-HEAD}" ;;
  --check) [[ $# -eq 2 ]] || die "usage: --check <range>|--all"; check_main "$2" ;;
  --check-text) shift; check_text "$@" || exit 1 ;;
  pr) [[ $# -eq 4 ]] || die "usage: pr <branch> <title-file> <body-file>"; pr_main "$2" "$3" "$4" ;;
  pr-edit) [[ $# -eq 4 ]] || die "usage: pr-edit <n> <title-file> <body-file>"; pr_edit_main "$2" "$3" "$4" ;;
  merge) [[ $# -eq 2 ]] || die "usage: merge <n>"; merge_main "$2" ;;
  -*) die "unknown mode" ;;
  *) [[ $# -le 2 && ( $# -eq 1 || $2 == --rebased ) ]] || die "usage: <branch> [--rebased]"; push_main "$1" real "${2:-}" ;;
esac
