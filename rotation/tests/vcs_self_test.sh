#!/usr/bin/env bash
#
# rotation kernel — the version-control adapter (vcs.sh) and the alt backend.
#
# The kernel runs `"$ROTATION_VCS_BIN" -C <dir> <git arguments>` for both
# backends, alt taking git's arguments and printing git's output. Three parts:
#   1  detection: the nearest .git or .alt from a directory up, git when both
#      are at one level and when neither is found; ROTATION_VCS overrides it
#   2  the core flows (HEAD, the TRIG-1 commit count, the round measures,
#      trig_gate, check INV-2, the doctor's tree check, init) run once on git
#      and once with ROTATION_VCS=alt and an `alt` that is git underneath:
#      every answer must be the same, and in the alt run no call may reach
#      `git` directly (a `git` first on PATH records any that do)
#   3  the same flows against a real alt repository with the installed alt;
#      skipped, naming what is missing, while alt lacks a form the kernel uses
#
# exit: 0 every case passed (skips included) · 1 otherwise

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KBIN="$(cd "$SCRIPT_DIR/../bin" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP=$(mktemp -d)
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
pass=0
fail=0
skip=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     | /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
expect_has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1 (wanted /$3/)" "$2"; fi; }
REALGIT=$(command -v git)

# ── 1 detection ─────────────────────────────────────────────────────────
detect() { (. "$KBIN/vcs.sh"; rotation_vcs_detect "$1"); }
D="$TMP/detect"
mkdir -p "$D/g/.git" "$D/a/.alt" "$D/af" "$D/both/.git" "$D/both/.alt" "$D/outer/.git" "$D/outer/inner/.alt" "$D/outer/plain/deep" "$D/none"
: > "$D/af/.alt"
expect_eq "a .git directory is git" "$(detect "$D/g")" git
expect_eq "an .alt directory is alt" "$(detect "$D/a")" alt
expect_eq "an .alt file (a workspace) is alt" "$(detect "$D/af")" alt
expect_eq ".git and .alt at one level: git" "$(detect "$D/both")" git
expect_eq "the nearest wins: .alt under a .git tree" "$(detect "$D/outer/inner")" alt
expect_eq "a subdirectory finds the level above" "$(detect "$D/outer/plain/deep")" git
# $TMP sits under a system temporary directory with no repository above it
expect_eq "no repository at all: git, which fails as before" "$(detect "$D/none")" git
sel() { (. "$KBIN/vcs.sh"; rotation_vcs_select "$@" && printf '%s %s\n' "$ROTATION_VCS_KIND" "$ROTATION_VCS_BIN"); }
expect_eq "select on a git tree" "$(sel "$D/g")" "git git"
expect_eq "select on an alt tree" "$(sel "$D/a")" "alt alt"
expect_eq "the override names alt on a git tree" "$(sel "$D/g" alt)" "alt alt"
expect_eq "the override names git on an alt tree" "$(sel "$D/a" git)" "git git"
expect_eq "ROTATION_ALT_BIN is the alt command" "$(ROTATION_ALT_BIN=/opt/x/alt sel "$D/a")" "alt /opt/x/alt"
(. "$KBIN/vcs.sh"; rotation_vcs_select "$D/g" svn) 2>/dev/null
expect_eq "an unknown backend is refused" "$?" 2

# ── 2 git, and alt speaking git ─────────────────────────────────────────
# an `alt` that is git underneath, logging its calls; a `git` first on PATH that logs every direct call
mkdir -p "$TMP/pathbin"
printf '#!/bin/sh\necho "$*" >> "%s/shim.log"\nexec "%s" "$@"\n' "$TMP" "$REALGIT" > "$TMP/alt-shim"
printf '#!/bin/sh\necho "$*" >> "%s/direct.log"\nexec "%s" "$@"\n' "$TMP" "$REALGIT" > "$TMP/pathbin/git"
chmod +x "$TMP/alt-shim" "$TMP/pathbin/git"

REPO="$TMP/repo"
mkdir -p "$REPO/.claude" "$TMP/state" "$TMP/stamps"
g() { "$REALGIT" -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b develop
printf '.claude/\nscratch\n' > "$REPO/.gitignore"
g add .gitignore && g commit -q -m 'chore: seed'
C1=$(g rev-parse --short HEAD)
for i in 2 3 4 5; do echo "$i" > "$REPO/f$i"; g add "f$i"; g commit -q -m "feat: change $i"; done
echo x > "$REPO/fx"; g add fx; g commit -q -m $'feat: by a worker\n\nAgent-Origin: w1'
g switch -q -c side
for i in 1 2; do echo "$i" > "$REPO/s$i"; g add "s$i"; g commit -q -m "feat: side $i"; done
g switch -q develop
g merge -q --no-ff -m 'merge: side into develop' side
echo 6 > "$REPO/f6"; g add f6; g commit -q -m 'feat: change 6'
C6=$(g rev-parse --short HEAD)
# the first-parent line after C1: c2..c5, the worker's commit, the merge, c6; the worker's is not counted
WANT_COMMITS=6
printf '{"rotationId":"r-vcs-1","at":"x","ts":%s,"project":"repo","trigger":"self","prevHead":"%s"}\n' \
  "$(( $(date +%s) - 3600 ))" "$C1" > "$TMP/rot.jsonl"
printf '%s\n' '## rotate-trigger' '' 'axis: A' "closed: $C6 change 6" 'gate: 10/0/0' 'reason: a' > "$TMP/handoff.md"
printf '{"tool":"sweep","headSha":"%s","verdict":"ok"}\n' "$(g rev-parse HEAD)" > "$TMP/stamps/sweep-latest.json"
mk_conf() {  # mk_conf <name> [extra lines…]
  local n=$1; shift
  printf '%s\n' ROTATION_CONF_KERNEL=1 ROTATION_TRIG1_MIN_COMMITS=3 ROTATION_TRIG1_MIN_CLOSED=1 \
    ROTATION_TRIG2_MIN_WALL_SEC=60 ROTATION_TRIG2_MAX_WALL_SEC=99999 ROTATION_TRIG5_SAME_AXIS_MAX=8 \
    ROTATION_TRIG5_BENCH_MAX_AGE_DAYS=14 ROTATION_AXES=A,B ROTATION_STAMPS=sweep "$@" > "$TMP/conf.$n"
}
mk_conf git
mk_conf alt ROTATION_VCS=alt
mk_conf bad ROTATION_VCS=svn

kenv() {  # kenv <git|alt|bad> <command…>
  local mode=$1; shift
  env PATH="$TMP/pathbin:$PATH" ROTATION_ALT_BIN="$TMP/alt-shim" \
    ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF="$TMP/conf.$mode" ROTATION_PROJECT_SH=/dev/null \
    ROTATION_STATE_DIR="$TMP/state" HARDEV_ROTATIONS_LOG="$TMP/rot.jsonl" HARDEV_EVENTS_LOG="$TMP/events.jsonl" \
    HARDEV_HANDOFF_FILE="$TMP/handoff.md" ROTATION_STAMP_DIR="$TMP/stamps" "$@"
}
probe_lib() {
  # shellcheck disable=SC2016
  kenv "$1" bash -c '. "$1/lib.sh"; echo "kind=$ROTATION_VCS_KIND"; echo "head=$(autorun_git_head)"
    echo "commits=$(autorun_commits_since_last_self)"; echo "measures=$(autorun_round_measures | cut -f2)"
    echo "error=$ROTATION_CONF_ERROR"' _ "$KBIN" 2>&1
}
gate_lines() { kenv "$1" bash "$KBIN/trig_gate.sh" 2>&1 | grep -E '^TRIG-(1|3|6) '; }
inv2() { kenv "$1" bash "$KBIN/check.sh" 2>&1 | grep -E '^INV-2 '; }
doctor_tree() { kenv "$1" bash "$KBIN/doctor.sh" 2>&1 | grep -E '^(PASS|FAIL) git(\.base)? '; }

: > "$TMP/direct.log"
lib_git=$(probe_lib git)
# the recorder itself works: the git run is seen there
expect_has "git: the direct-call recorder sees the git run" "$(cat "$TMP/direct.log")" 'rev-list --first-parent'
expect_has "git: the backend is git" "$lib_git" '^kind=git$'
expect_has "git: HEAD" "$lib_git" "^head=$C6\$"
expect_has "git: the TRIG-1 count leaves out the worker and the merged branch" "$lib_git" "^commits=$WANT_COMMITS\$"
gate_git=$(gate_lines git)
expect_has "git: TRIG-1 counts the session" "$gate_git" "^TRIG-1 PASS commits=$WANT_COMMITS "
expect_has "git: TRIG-3 finds the closed sha in the range" "$gate_git" '^TRIG-3 PASS '
inv2_git=$(inv2 git)
expect_has "git: INV-2 clean" "$inv2_git" '^INV-2 PASS tree clean'
doc_git=$(doctor_tree git)
expect_has "git: the doctor's tree check" "$doc_git" '^PASS git\.base develop'

: > "$TMP/direct.log"; : > "$TMP/shim.log"
lib_alt=$(probe_lib alt)
expect_has "alt: rotation.conf ROTATION_VCS=alt selects alt" "$lib_alt" '^kind=alt$'
expect_eq "alt: HEAD, the count and the round measures match git's" \
  "$(printf '%s\n' "$lib_alt" | grep -v '^kind=')" "$(printf '%s\n' "$lib_git" | grep -v '^kind=')"
expect_eq "alt: trig_gate TRIG-1/3/6 lines match git's" "$(gate_lines alt)" "$gate_git"
expect_eq "alt: INV-2 matches git's" "$(inv2 alt)" "$inv2_git"
expect_eq "alt: the doctor's tree check matches git's" "$(doctor_tree alt)" "$doc_git"
echo dirt > "$REPO/f2"
expect_eq "alt: a dirty tree fails INV-2 as on git" "$(inv2 alt)" "$(inv2 git)"
expect_has "alt: the dirty line" "$(inv2 alt)" '^INV-2 FAIL tree dirty: 1 entry'
g checkout -q -- f2
: > "$TMP/direct.log"; : > "$TMP/shim.log"
probe_lib alt >/dev/null; gate_lines alt >/dev/null; inv2 alt >/dev/null; doctor_tree alt >/dev/null
expect_eq "alt: no call reached git directly" "$(sort -u "$TMP/direct.log")" ""
expect_has "alt: the calls went through ROTATION_ALT_BIN with git's arguments" "$(cat "$TMP/shim.log")" \
  '^-C .*/repo rev-list --first-parent --invert-grep -E --grep=\^Agent-Origin: '
expect_has "a bad ROTATION_VCS is a conf error" "$(probe_lib bad)" "^error=ROTATION_VCS must be git or alt, got 'svn'"

# init.sh in an alt tree: `.alt` marks it, the shim keeps the history elsewhere
AT="$TMP/alt-tree"
mkdir -p "$AT/.alt"
"$REALGIT" init -q --separate-git-dir="$TMP/alt-tree.data" "$TMP/alt-tree.wt" && rm -f "$TMP/alt-tree.wt/.git" && rmdir "$TMP/alt-tree.wt"
printf '#!/bin/sh\nexec "%s" --git-dir="%s" --work-tree="%s" "$@"\n' "$REALGIT" "$TMP/alt-tree.data" "$AT" > "$TMP/alt-tree-shim"
chmod +x "$TMP/alt-tree-shim"
"$TMP/alt-tree-shim" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
: > "$TMP/direct.log"
out=$(cd "$AT" && env PATH="$TMP/pathbin:$PATH" ROTATION_ALT_BIN="$TMP/alt-tree-shim" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --shims none 2>&1)
expect_eq "init.sh accepts an alt tree" "$?" 0
expect_eq "init.sh writes kernel.path in the alt tree" "$(cat "$AT/.claude/rotation/kernel.path" 2>/dev/null)" "$ROOT"
expect_eq "init.sh on alt calls no git" "$(cat "$TMP/direct.log")" ""
out=$(cd "$D/none" && env PATH="$TMP/pathbin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" 2>&1)
expect_eq "init.sh outside any repository still refuses" "$?" 1

# ── 3 the installed alt ─────────────────────────────────────────────────
ALT=$(command -v alt || true)
if [ -z "$ALT" ]; then
  skip=$((skip + 1)); echo "SKIP real alt: no alt on PATH"
else
  AR="$TMP/alt-real"
  mkdir -p "$AR"
  (cd "$AR" && "$ALT" init >/dev/null 2>&1 && echo a > a && "$ALT" add a >/dev/null 2>&1 && "$ALT" commit -m 'chore: seed' >/dev/null 2>&1)
  # every form the kernel sends, as `-C <dir> <git arguments>`
  missing=()
  try() { "$ALT" -C "$AR" "$@" >/dev/null 2>&1 || missing+=("$*"); }
  try rev-parse --show-toplevel
  try rev-parse --short HEAD
  try rev-parse --is-inside-work-tree
  try rev-parse --abbrev-ref HEAD
  try rev-parse --path-format=absolute --git-common-dir
  try symbolic-ref --short -q HEAD
  try status --porcelain
  try cat-file -e 'HEAD^{commit}'
  try log -1 --format=%ct HEAD
  try rev-list HEAD
  try rev-list --first-parent --invert-grep -E --grep=^Agent-Origin: HEAD
  try rev-list --first-parent --reverse --parents HEAD
  try rev-list --first-parent --invert-grep -E --grep=^Agent-Origin: --format=%ct HEAD
  try merge-base --is-ancestor HEAD HEAD
  try workspace list --porcelain
  if [ "${#missing[@]}" -gt 0 ]; then
    skip=$((skip + 1))
    echo "SKIP real alt ($("$ALT" --version 2>/dev/null)): waiting for alt to provide:"
    printf '       alt -C <dir> %s\n' "${missing[@]}"
  else
    (cd "$AR" && for i in 2 3; do echo "$i" > "f$i"; "$ALT" add "f$i" >/dev/null 2>&1; "$ALT" commit -m "feat: change $i" >/dev/null 2>&1; done
     echo x > fx; "$ALT" add fx >/dev/null 2>&1; "$ALT" commit -m $'feat: by a worker\n\nAgent-Origin: w1' >/dev/null 2>&1
     echo 4 > f4; "$ALT" add f4 >/dev/null 2>&1; "$ALT" commit -m 'feat: change 4' >/dev/null 2>&1)
    first=$("$ALT" -C "$AR" rev-list HEAD | tail -1 | cut -c1-9)
    printf '{"rotationId":"r-vcs-2","at":"x","ts":%s,"project":"alt-real","trigger":"self","prevHead":"%s"}\n' \
      "$(( $(date +%s) - 3600 ))" "$first" > "$TMP/rot-real.jsonl"
    # shellcheck disable=SC2016
    real=$(env -u ROTATION_ALT_BIN ROTATION_PROJECT_DIR="$AR" ROTATION_CONF="$TMP/conf.git" ROTATION_PROJECT_SH=/dev/null \
      ROTATION_STATE_DIR="$TMP/state-real" HARDEV_ROTATIONS_LOG="$TMP/rot-real.jsonl" HARDEV_EVENTS_LOG="$TMP/events-real.jsonl" \
      bash -c '. "$1/lib.sh"; echo "kind=$ROTATION_VCS_KIND"; echo "commits=$(autorun_commits_since_last_self)"' _ "$KBIN" 2>&1)
    expect_has "real alt: detected from .alt" "$real" '^kind=alt$'
    expect_has "real alt: the TRIG-1 count leaves out the worker" "$real" '^commits=3$'
    st=$(env ROTATION_PROJECT_DIR="$AR" ROTATION_CONF="$TMP/conf.git" ROTATION_PROJECT_SH=/dev/null ROTATION_STATE_DIR="$TMP/state-real" \
      HARDEV_ROTATIONS_LOG="$TMP/rot-real.jsonl" HARDEV_EVENTS_LOG="$TMP/events-real.jsonl" bash "$KBIN/check.sh" 2>&1 | grep '^INV-2 ')
    expect_has "real alt: INV-2" "$st" '^INV-2 PASS tree clean'
    dt=$(env ROTATION_PROJECT_DIR="$AR" ROTATION_CONF="$TMP/conf.git" ROTATION_PROJECT_SH=/dev/null ROTATION_STATE_DIR="$TMP/state-real" \
      HARDEV_ROTATIONS_LOG="$TMP/rot-real.jsonl" HARDEV_EVENTS_LOG="$TMP/events-real.jsonl" bash "$KBIN/doctor.sh" 2>&1 | grep -E '^(PASS|FAIL) git ')
    expect_has "real alt: the doctor's tree check" "$dt" '^PASS git '
  fi
fi

echo "vcs_self_test: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
