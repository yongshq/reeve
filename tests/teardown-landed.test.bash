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

# The same question asked of the whole repository rather than one commit, and
# the one assertion every case can make: after a correct run, nothing at all is
# orphaned. A copy's HEAD is a root while the copy exists, so a refusal shows
# clean here; the moment a copy is removed over work that was only its own, the
# commit it held appears. Reflogs are excluded deliberately: they would keep an
# orphan alive for ninety days and hide exactly the loss this suite is for.
unreachable() { # unreachable <repo> -> none|<sha ...>
  local out
  out=$(git -C "$1" fsck --unreachable --no-reflogs 2>/dev/null \
        | sed -n 's/^unreachable commit //p')
  if [ -n "$out" ]; then printf '%s\n' "$out" | tr '\n' ' '; else printf 'none\n'; fi
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

# --- the state matrix -------------------------------------------------------
# What the record CLAIMS and what the copy actually IS are two independent
# facts, and the guard has to ask both. Every hole this file exists to close
# lived in the cell where they disagree: the record chose which check ran, so a
# copy examined through the half that looked safe was removed with its commits
# on it. This builder varies them separately, which the scene builder above
# cannot do.
#
# branch state: empty    no branch recorded, as a scout or warden is dispatched
#               landed   a real branch the base already contains
#               unlanded a real branch holding a commit the base does not
#               missing  a branch= naming a ref that was never created
# head state:   at-base  the detached copy is where its base left it
#               off-ref  the copy committed, so its HEAD is on no ref at all
cell() { # cell <id> <branch-state> <head-state> <writes> [recorded-base]
  local id=$1 bstate=$2 hstate=$3 writes=$4 recorded=${5:-main} branch=''
  repo="$SCRATCH/$id"; wt="$SCRATCH/$id.worktrees/w"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email tester@example.invalid
  git -C "$repo" config user.name reeve-test
  printf 'one\n' > "$repo/a.txt"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'init'
  case $bstate in
    landed)   branch="fix/$id"; git -C "$repo" branch "$branch" main ;;
    unlanded) branch="fix/$id"
              git -C "$repo" checkout -q -b "$branch"
              printf 'branch work\n' > "$repo/c.txt"
              git -C "$repo" add -A >/dev/null
              git -C "$repo" commit -qm 'work that never landed'
              git -C "$repo" checkout -q main ;;
    missing)  branch="fix/$id-never-created" ;;
  esac
  git -C "$repo" worktree add -q --detach "$wt" main
  if [ "$hstate" = off-ref ]; then
    printf 'two\n' > "$wt/b.txt"
    git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm 'work nobody wants to lose'
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
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

# 13. All twenty four cells, executed. The expected column is the invariant
#     restated as a table: remove only when everything the copy holds is already
#     on the base, refuse otherwise, and never orphan a commit either way. One
#     cell changed meaning deliberately: landed/off-ref used to remove and lose
#     the commit, and now refuses, because the record and the copy disagree.
n=0
while read -r bstate hstate w rc_want copy_want <&3; do
  case $bstate in ''|'#'*) continue ;; esac
  n=$((n+1))
  id="m$n-$bstate-$hstate-$w"
  cell "$id" "$bstate" "$hstate" "$w"
  c_repo=$repo c_wt=$wt c_sha=$sha
  run_teardown "$id"
  ck_eq "13 $bstate/$hstate/$w rc"           "$RC" "$rc_want"
  ck_eq "13 $bstate/$hstate/$w copy"         "$(gone "$c_wt")" "$copy_want"
  ck_eq "13 $bstate/$hstate/$w orphans none" "$(unreachable "$c_repo")" none
  ck_eq "13 $bstate/$hstate/$w commit kept"  "$(survives "$c_repo" "$c_sha")" survived
done 3<<'CELLS'
# branch    head     writes  rc  copy
empty       at-base  yes     0   removed
empty       at-base  no      0   removed
empty       at-base  home    0   present
empty       off-ref  yes     1   present
empty       off-ref  no      1   present
empty       off-ref  home    0   present
landed      at-base  yes     0   removed
landed      at-base  no      0   removed
landed      at-base  home    0   present
landed      off-ref  yes     1   present
landed      off-ref  no      1   present
landed      off-ref  home    0   present
unlanded    at-base  yes     1   present
unlanded    at-base  no      1   present
unlanded    at-base  home    1   present
unlanded    off-ref  yes     1   present
unlanded    off-ref  no      1   present
unlanded    off-ref  home    1   present
missing     at-base  yes     1   present
missing     at-base  no      1   present
missing     at-base  home    1   present
missing     off-ref  yes     1   present
missing     off-ref  no      1   present
missing     off-ref  home    1   present
CELLS

# 13b. THE THIRD HOLE, named, because a table of twenty four rows is easy to
#      read past. A record naming a branch that really did land, and a copy left
#      detached on a commit that is on nothing. Check 4 passed on the branch,
#      check 5 never ran because branch= was not empty, and the copy went with
#      its commit on it. Both facts are asked of every copy now, so the branch
#      passing no longer excuses the copy.
cell third-hole landed off-ref yes
run_teardown third-hole
ck_eq  "13b a landed branch does not excuse the copy" "$RC" 1
ck_eq  "13b its copy survives"                        "$(gone "$wt")" present
ck_has "13b the refusal names the copy's path"        "$OUT" "$wt"
ck_has "13b it says record and copy disagree"         "$OUT" "the record and the copy disagree"
ck_eq  "13b nothing is orphaned"                      "$(unreachable "$repo")" none
ck_eq  "13b the commit is not lost"                   "$(survives "$repo" "$sha")" survived

# 13c. the base still has to resolve for either fact. A copy that committed
#      nothing looks safe, and is, but only against a base the script can
#      actually compare with: a check that cannot run refuses.
cell cell-missing-base landed at-base yes vanished-base
run_teardown cell-missing-base
ck_eq  "13c a clean copy with an unresolvable base refuses" "$RC" 1
ck_eq  "13c its copy survives"                              "$(gone "$wt")" present
ck_has "13c it refuses on the base"                         "$OUT" "vanished-base"

# 13d. the same, with nothing recorded but the copy. The branch fact is the one
#      that used to consult the base first, so this proves the copy fact does
#      not quietly skip a base it cannot resolve.
cell cell-missing-base-detached empty at-base no vanished-base
run_teardown cell-missing-base-detached
ck_eq  "13d a detached clean copy with no base refuses"     "$RC" 1
ck_eq  "13d its copy survives"                              "$(gone "$wt")" present
ck_has "13d it refuses on the base"                         "$OUT" "does not name a commit"

# 14. THE OVER-REFUSAL. A scout's copy that committed nothing, and unrelated
#     work lands on the base afterwards, which it always does. Asking whether
#     HEAD EQUALS the base refused this the moment anything landed on main, from
#     a sentry run whose output is discarded, and the contract promises that a
#     scout disappears completely. The question is whether the copy's HEAD is
#     REACHABLE FROM the base, and it is: nothing it holds is its own.
cell over-refusal empty at-base no
printf 'unrelated\n' > "$repo/c.txt"
git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'unrelated work lands on main'
run_teardown over-refusal
ck_eq  "14 a clean copy behind an advanced base tears down" "$RC" 0
ck_eq  "14 its copy is removed"                             "$(gone "$wt")" removed
ck_eq  "14 nothing is orphaned"                             "$(unreachable "$repo")" none
ck_eq  "14 the base commit is untouched"                    "$(survives "$repo" "$sha")" survived

# 14b. the same shape with a landed branch recorded, which is what an artificer
#      leaves behind once its work is in. The base moving on afterwards must not
#      turn that into a refusal either.
cell over-refusal-branch landed at-base yes
printf 'unrelated\n' > "$repo/c.txt"
git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'unrelated work lands on main'
run_teardown over-refusal-branch
ck_eq  "14b a landed errand behind an advanced base tears down" "$RC" 0
ck_eq  "14b its copy is removed"                                "$(gone "$wt")" removed
ck_eq  "14b nothing is orphaned"                                "$(unreachable "$repo")" none

# 15. a copy sitting ON a branch rather than detached, which the matrix cannot
#     express. When the record and the copy agree and the branch has landed,
#     nothing has changed: it tears down.
scene on-its-branch main landed
git -C "$wt" checkout -q "fix/on-its-branch"
run_teardown on-its-branch
ck_eq  "15 a copy on its own landed branch tears down" "$RC" 0
ck_eq  "15 its copy is removed"                        "$(gone "$wt")" removed
ck_eq  "15 nothing is orphaned"                        "$(unreachable "$repo")" none

# 15b. the strict reading, chosen deliberately. The recorded branch landed, but
#      the copy is on a DIFFERENT branch holding work that did not. Nothing is
#      lost by removing it, because that other branch keeps the commit, so the
#      loose reading would wave it through. This script is the landed-work test,
#      not a loss-prevention test: a copy whose record and reality disagree is
#      something the liege wants to hear about, not something to tidy away.
scene other-branch main landed
git -C "$wt" checkout -q -b fix/other-branch-actual
printf 'three\n' > "$wt/c.txt"
git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm 'unlanded work on another branch'
other_sha=$(git -C "$wt" rev-parse HEAD)
other_meta=$REEVE_HOME/state/other-branch.meta
run_teardown other-branch
ck_eq  "15b a copy on another branch refuses"       "$RC" 1
ck_eq  "15b its copy survives"                      "$(gone "$wt")" present
ck_has "15b the refusal says they disagree"         "$OUT" "the record and the copy disagree"
ck_has "15b it names the line to correct"           "$OUT" "branch= line in $other_meta"
ck_eq  "15b the other branch's commit is kept"      "$(survives "$repo" "$other_sha")" survived

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
