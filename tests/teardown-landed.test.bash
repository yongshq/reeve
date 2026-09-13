#!/usr/bin/env bash
# The landed-work test in bin/reeve-teardown is the only thing standing between
# the liege and the loss of committed work, so it must fail CLOSED. It once did
# not: `rev-list --count` fell back to 0 when the recorded base no longer
# resolved, and 0 reads as "nothing unlanded", so the copy was removed with its
# commits still on it. Cases 3 and 4 are that bug; case 1 is the behaviour the
# fix must not break.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# --- safety -----------------------------------------------------------------
# This suite builds throwaway git repositories and tears them down for real. A
# test for a data-loss bug that causes data loss is not acceptable, so it
# refuses to run at all unless REEVE_HOME is demonstrably scratch.
real_home=$(cd "$HOME" && pwd -P)
scratch_root=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || scratch_root=/tmp
case $scratch_root in "$real_home"|"$real_home"/*) scratch_root=/tmp ;; esac
SCRATCH=$(mktemp -d "$scratch_root/reeve-teardown-test.XXXXXX") || exit 1
export REEVE_HOME="$SCRATCH/reeve-home"
mkdir -p "$REEVE_HOME/state" || exit 1
home_p=$(cd "$REEVE_HOME" && pwd -P)
case $home_p in
  ''|"$real_home"|"$real_home"/*|*/.reeve|*/.reeve/*)
    printf 'FAIL  refusing to run: REEVE_HOME=%s is at or under the real home\n' "$home_p"
    exit 1 ;;
esac
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]" ;; esac; }

# --- scene builder ----------------------------------------------------------
# One scratch repository per case, so no case can be tripped up by another.
# kind: ahead    a branch holding a commit the base does not
#       landed   the same commit, already merged into main
#       readonly a detached copy that committed something it was forbidden to
scene() { # scene <id> <recorded-base> <kind>
  local id=$1 recorded=$2 kind=$3 branch writes
  repo="$SCRATCH/$id"; wt="$SCRATCH/$id.worktrees/w"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email tester@example.invalid
  git -C "$repo" config user.name reeve-test
  printf 'one\n' > "$repo/a.txt"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'init'
  if [ "$kind" = readonly ]; then
    branch=''; writes=no
    git -C "$repo" worktree add -q --detach "$wt" main
  else
    branch="fix/$id"; writes=yes
    git -C "$repo" worktree add -q "$wt" -b "$branch" main
  fi
  printf 'two\n' > "$wt/b.txt"
  git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm 'work nobody wants to lose'
  [ "$kind" = landed ] && git -C "$repo" merge -q --ff-only "$branch"
  mkdir -p "$REEVE_HOME/errands/$id"
  {
    printf 'repo=%s\n'     "$repo"
    printf 'worktree=%s\n' "$wt"
    printf 'branch=%s\n'   "$branch"
    printf 'base=%s\n'     "$recorded"
    printf 'writes=%s\n'   "$writes"
  } > "$REEVE_HOME/state/$id.meta"
  printf 'done: finished\n' > "$REEVE_HOME/errands/$id/status"
}

run_teardown() { # run_teardown <id> [args...]  -> sets OUT and RC
  OUT=$("$ROOT/bin/reeve-teardown" "$@" 2>&1); RC=$?
}

gone() { [ -d "$1" ] && printf 'present\n' || printf 'removed\n'; }

# 1. a branch ahead of a base that does exist: refuses, as it always has.
scene ahead-real-base main ahead
run_teardown ahead-real-base
ck_eq  "1 ahead of an existing base refuses"        "$RC" 1
ck_has "1 refusal counts the unlanded commits"      "$OUT" "1 commit(s) that main does not have"
ck_eq  "1 the copy is left alone"                   "$(gone "$wt")" present

# 2. the same work, already in the base: passes and the copy goes.
scene landed main landed
run_teardown landed
ck_eq  "2 a landed branch tears down"               "$RC" 0
ck_eq  "2 the copy is removed"                      "$(gone "$wt")" removed

# 3. THE BUG. Unlanded commits, and a recorded base that no longer resolves.
#    Before the fix this printed "landed-work checks passed" and removed the
#    copy, because the failed count was read as zero commits ahead.
scene missing-base vanished-base ahead
meta=$REEVE_HOME/state/missing-base.meta
run_teardown missing-base
ck_eq  "3 a base that does not resolve refuses"     "$RC" 1
ck_eq  "3 the unlanded copy survives"               "$(gone "$wt")" present
ck_has "3 it does not claim the checks passed"      "$OUT" "REFUSED"

# 5. a refusal nobody can act on is only half a fix.
ck_has "5 the refusal names the missing base"       "$OUT" "vanished-base"
ck_has "5 it says which line to correct"            "$OUT" "base= line in $meta"
ck_has "5 it says what to correct it to"            "$OUT" "the branch the work actually landed on"

# 4. a read-only errand that committed, with a base that does not resolve. The
#    old check compared HEAD against `rev-parse $base` and skipped itself when
#    that came back empty. It refuses either way now, and on the base rather
#    than on a comparison it could not make.
scene readonly-missing-base vanished-base readonly
run_teardown readonly-missing-base
ck_eq  "4 read-only with a missing base refuses"    "$RC" 1
ck_eq  "4 its copy survives"                        "$(gone "$wt")" present
ck_has "4 it refuses on the base, not silently"     "$OUT" "vanished-base"

# 4b. the empty recorded base is where that check actually fell open. A missing
#     branch NAME left a non-empty string behind, because `git rev-parse gone`
#     prints "gone" on stdout before it fails, so the comparison ran on garbage
#     and refused by accident. An empty base leaves nothing, the guard skipped,
#     and a copy forbidden to commit was removed with its commit on it.
scene readonly-empty-base '' readonly
run_teardown readonly-empty-base
ck_eq  "4b read-only with an empty base refuses"    "$RC" 1
ck_eq  "4b its copy survives"                       "$(gone "$wt")" present
ck_has "4b it says the base does not resolve"       "$OUT" "does not name a commit"

# 4c. the same errand with a base that does resolve still trips the old check.
scene readonly-real-base main readonly
run_teardown readonly-real-base
ck_eq  "4c read-only that committed still refuses"  "$RC" 1
ck_has "4c it names the forbidden commit"           "$OUT" "moved off main"

# 6. --dismiss-only frees the session and stops before any of this. Nothing
#    committed is at risk on that path, so a base it cannot resolve must not
#    block it: refusing there would strand a pane over stale metadata.
scene dismiss-missing-base vanished-base ahead
run_teardown dismiss-missing-base --dismiss-only
ck_eq  "6 --dismiss-only ignores the base"          "$RC" 0
ck_eq  "6 --dismiss-only keeps the copy"            "$(gone "$wt")" present

# 7. an errand that writes only to the reeve's home has no branch and no copy,
#    so neither check consults the base. Resolving it lazily is what keeps a
#    stale base from refusing a teardown that never needed one.
mkdir -p "$REEVE_HOME/errands/home-only"
printf 'repo=\nworktree=\nbranch=\nbase=vanished-base\nwrites=home\n' \
  > "$REEVE_HOME/state/home-only.meta"
printf 'done: memory updated\n' > "$REEVE_HOME/errands/home-only/status"
run_teardown home-only
ck_eq  "7 a home-only errand is not refused"        "$RC" 0

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
