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
# `cd ""` succeeds in bash and stays put, so `cd "$HOME"` with HOME unset used to
# leave real_home holding the current directory, and every comparison below then
# guarded the wrong path. The fallback names somewhere that cannot match a real
# home; an empty result would mean even that failed, and a guard with nothing to
# compare against refuses rather than waves the suite through.
real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
if [ -z "$real_home" ]; then
  printf 'FAIL  refusing to run: the real home could not be resolved\n'
  exit 1
fi
scratch_root=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || scratch_root=/tmp
case $scratch_root in "$real_home"|"$real_home"/*) scratch_root=/tmp ;; esac
SCRATCH=$(mktemp -d "$scratch_root/reeve-teardown-test.XXXXXX") || exit 1
# Installed the moment there is something to clean up, and before the guard
# below, which can exit and would otherwise leave the scratch tree behind.
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/reeve-home"
mkdir -p "$REEVE_HOME/state" || exit 1
home_p=$(cd "$REEVE_HOME" && pwd -P)
case $home_p in
  ''|"$real_home"|"$real_home"/*|*/.reeve|*/.reeve/*)
    printf 'FAIL  refusing to run: REEVE_HOME=%s is at or under the real home\n' "$home_p"
    exit 1 ;;
esac

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output should not have said [$3]" ;; *) ok "$1" ;; esac; }

# --- scene builder ----------------------------------------------------------
# One scratch repository per case, so no case can be tripped up by another.
# kind: ahead    a branch holding a commit the base does not
#       landed   the same commit, already merged into main
#       readonly a detached copy that committed something
#       clean    a detached copy that committed nothing, as a scout leaves it
# The optional fourth argument overrides the recorded writes= label; '-' leaves
# the line out of the meta file altogether, which is what a truncated or
# hand-edited record looks like.
scene() { # scene <id> <recorded-base> <kind> [writes]
  local id=$1 recorded=$2 kind=$3 override=${4:-} branch writes
  repo="$SCRATCH/$id"; wt="$SCRATCH/$id.worktrees/w"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email tester@example.invalid
  git -C "$repo" config user.name reeve-test
  printf 'one\n' > "$repo/a.txt"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'init'
  case $kind in
    readonly|clean)
      branch=''; writes=no
      git -C "$repo" worktree add -q --detach "$wt" main ;;
    *)
      branch="fix/$id"; writes=yes
      git -C "$repo" worktree add -q "$wt" -b "$branch" main ;;
  esac
  if [ "$kind" != clean ]; then
    printf 'two\n' > "$wt/b.txt"
    git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm 'work nobody wants to lose'
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
  [ "$kind" = landed ] && git -C "$repo" merge -q --ff-only "$branch"
  [ -n "$override" ] && writes=$override
  mkdir -p "$REEVE_HOME/errands/$id"
  {
    printf 'repo=%s\n'     "$repo"
    printf 'worktree=%s\n' "$wt"
    printf 'branch=%s\n'   "$branch"
    printf 'base=%s\n'     "$recorded"
    [ "$writes" = - ] || printf 'writes=%s\n' "$writes"
  } > "$REEVE_HOME/state/$id.meta"
  printf 'done: finished\n' > "$REEVE_HOME/errands/$id/status"
}

run_teardown() { # run_teardown <id> [args...]  -> sets OUT and RC
  OUT=$("$ROOT/bin/reeve-teardown" "$@" 2>&1); RC=$?
}

gone() { [ -d "$1" ] && printf 'present\n' || printf 'removed\n'; }

# The message and the exit status are not the point. The point is whether the
# commit is still there, so this asks git rather than the script: a commit held
# only by a removed copy's detached HEAD has no root left, and `gc --prune=now`
# finishes it. A copy still in place is a root, which is why a refusal preserves
# the work without needing a branch.
survives() { # survives <repo> <sha> -> survived|lost
  git -C "$1" gc --prune=now --quiet >/dev/null 2>&1
  if git -C "$1" cat-file -e "$2" 2>/dev/null; then printf 'survived\n'; else printf 'lost\n'; fi
}

# Reachability from a ref is the separate question: it is what makes work safe
# to remove a copy over, and what case 2 has to prove after a successful
# teardown.
on_a_ref() { # on_a_ref <repo> <sha> -> yes|no
  if [ -n "$(git -C "$1" for-each-ref --contains "$2" 2>/dev/null)" ]
  then printf 'yes\n'; else printf 'no\n'; fi
}

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
ck_eq  "2 the landed commit is still on a ref"      "$(on_a_ref "$repo" "$sha")" yes
ck_eq  "2 and still exists after a prune"           "$(survives "$repo" "$sha")" survived

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

# 7b. a steward that has a worktree= path recorded anyway. reeve-dispatch never
#     creates a copy for one, so in practice that path is empty or points at
#     nothing, but the guard below must not lean on either. What keeps a steward
#     out of the detached-copy check is the writes=home label itself, so this
#     records a path that does exist and expects it to be left alone regardless.
mkdir -p "$REEVE_HOME/errands/home-with-path" "$SCRATCH/steward-copy"
printf 'repo=\nworktree=%s\nbranch=\nbase=vanished-base\nwrites=home\n' "$SCRATCH/steward-copy" \
  > "$REEVE_HOME/state/home-with-path.meta"
printf 'done: memory updated\n' > "$REEVE_HOME/errands/home-with-path/status"
run_teardown home-with-path
ck_eq  "7b a steward with a worktree= path is not refused" "$RC" 0
ck_eq  "7b and that directory is left alone"        "$(gone "$SCRATCH/steward-copy")" present

# 8. THE SECOND BUG, and the one that loses commits outright. Check 5 was gated
#    on writes=no, so a DETACHED copy recorded as anything else satisfied
#    neither check 4 (which needs a branch) nor check 5. Nothing was compared,
#    the script printed "landed-work checks passed", and the copy went with its
#    commit on it: no branch held it, so it was unreachable and `git gc` took
#    it. The gate is the shape of the copy now, not the label on it.
scene detached-writes-yes main readonly yes
run_teardown detached-writes-yes
ck_eq  "8 a detached copy that committed refuses"   "$RC" 1
ck_eq  "8 its copy survives"                        "$(gone "$wt")" present
ck_has "8 it says the copy moved off the base"      "$OUT" "moved off main"
ck_has "8 the refusal names the copy's path"        "$OUT" "$wt"
ck_eq  "8 the commit is not lost"                   "$(survives "$repo" "$sha")" survived

# 8b. the same copy with no writes= line at all. meta_get returns its fallback
#     ("yes") only when the key is missing entirely, so a truncated or
#     hand-edited record is the realistic way into case 8.
scene detached-no-writes main readonly -
run_teardown detached-no-writes
ck_eq  "8b a detached copy with no writes= refuses" "$RC" 1
ck_eq  "8b its copy survives"                       "$(gone "$wt")" present
ck_eq  "8b the commit is not lost"                  "$(survives "$repo" "$sha")" survived

# 9. an unrecognised permission label. It decides which landed-work check
#    applies, so a value this script does not know is one it cannot check
#    safely. Same answer as a base that does not resolve.
scene detached-odd-writes main readonly maybe
run_teardown detached-odd-writes
ck_eq  "9 an unknown writes= value refuses"         "$RC" 1
ck_has "9 it names the label it did not recognise"  "$OUT" "writes=maybe"
ck_eq  "9 its copy survives"                        "$(gone "$wt")" present
ck_eq  "9 the commit is not lost"                   "$(survives "$repo" "$sha")" survived

# 10. a branch= naming a ref that does not exist. The verify failed and check 4
#     was skipped in silence, reporting a pass. On a detached copy that is
#     case 8 again by another door, so it refuses here too.
scene stale-branch main ahead
printf 'repo=%s\nworktree=%s\nbranch=fix/never-created\nbase=main\nwrites=yes\n' "$repo" "$wt" \
  > "$REEVE_HOME/state/stale-branch.meta"
run_teardown stale-branch
ck_eq  "10 a branch= that does not resolve refuses" "$RC" 1
ck_has "10 it names the branch it looked for"       "$OUT" "fix/never-created"
ck_eq  "10 its copy survives"                       "$(gone "$wt")" present
ck_eq  "10 the commit is not lost"                  "$(survives "$repo" "$sha")" survived

# 11. a repo= that is empty. require_base owns that refusal, but check 4 used to
#     test [ -n "$repo" ] in its own condition and short circuit before the
#     helper could speak: the operator was told the checks passed, then shown a
#     raw fatal: from git, then refused for an unrelated reason.
scene no-repo main ahead
printf 'repo=\nworktree=%s\nbranch=fix/no-repo\nbase=main\nwrites=yes\n' "$wt" \
  > "$REEVE_HOME/state/no-repo.meta"
run_teardown no-repo
ck_eq  "11 an empty repo= refuses"                  "$RC" 1
ck_not "11 it does not claim the checks passed"     "$OUT" "landed-work checks passed"
ck_has "11 it says no repository is recorded"       "$OUT" "no repository is recorded"
ck_eq  "11 its copy survives"                       "$(gone "$wt")" present

# 12. the other direction, and the whole point of widening check 5 rather than
#     refusing every detached copy: one that never committed is exactly where
#     its base left it, so it still tears down. This is what a scout or a warden
#     leaves behind, which makes it the common case, not the edge case.
scene clean-scout main clean
run_teardown clean-scout
ck_eq  "12 a detached copy that committed nothing"  "$RC" 0
ck_eq  "12 its copy is removed"                     "$(gone "$wt")" removed

# 12b. the same clean copy recorded as writes=yes. The widened gate must not
#      start refusing on the label alone, only on work it can see.
scene clean-writes-yes main clean yes
run_teardown clean-writes-yes
ck_eq  "12b a clean copy with writes=yes tears down" "$RC" 0
ck_eq  "12b its copy is removed"                     "$(gone "$wt")" removed

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
