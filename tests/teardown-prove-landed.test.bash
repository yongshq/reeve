#!/usr/bin/env bash
# bin/reeve-teardown --prove-landed, the proof behind hard rule 3's standing
# proven-delete grant. `git cherry` marking every commit `-` is not proof on its
# own, and a review reproduced each case below in which it passed unlanded work:
# a default branch that does not exist, a tag shadowing it, content that only a
# merge commit carries. These prove each one is now `not proven`, and that the
# cases the grant exists for still prove. The grant covers only the very ref an
# errand's dispatch made for that holding, by its reflog birth, and nothing since
# dropped, so every scene records br's birth as made; case 13 takes the record
# away, 14 and 15 the made and the not dropped. 16 and 17 are --delete-proven,
# the grant's own delete. 18 to 20 are a name reused after a delete by hand, and
# a reflog gone. 21 is a forced rename or copy onto the name on reftable, which
# keeps the overwritten ref's reflog.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# --- safety -----------------------------------------------------------------
# Reads a manors.md, so REEVE_HOME must be demonstrably scratch. Same guard as
# teardown-stack.test.bash.
real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
if [ -z "$real_home" ]; then
  printf 'FAIL  refusing to run: the real home could not be resolved\n'
  exit 1
fi
scratch_root=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || scratch_root=/tmp
case $scratch_root in "$real_home"|"$real_home"/*) scratch_root=/tmp ;; esac
SCRATCH=$(mktemp -d "$scratch_root/reeve-prove-test.XXXXXX") || exit 1
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
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output [$2] did not mention [$3]" ;; esac; }

# --- scene builder ----------------------------------------------------------
# A repository with one commit on <trunk> and a branch `br` off it holding one
# commit that adds file a, then one more commit on <trunk>, and an errand record
# naming br, as born, for it. Each case then lands br, or not, its own way. The trunk moves
# first because a cherry-pick onto the same parent in the same second recreates
# the very same commit id.
G() { git -C "$repo" "$@" >/dev/null 2>&1; }
record() { # record <id> <repo> <branch>: the errand record the scope check reads
  local made
  made=$(. "$ROOT/bin/reeve-lib.sh"; branch_birth "$2" "$3")
  printf 'office=artificer\nrepo=%s\nbranch=%s\nbranchMade=%s\n' "$2" "$3" \
    "${made:-0000000000000000000000000000000000000000 0}" > "$REEVE_HOME/state/$1.meta"
}
scene() { # scene <name> [trunk] [ref format]
  repo="$SCRATCH/$1"; local trunk=${2:-main}
  mkdir -p "$repo"
  git -C "$repo" init -q -b "$trunk" ${3:+--ref-format="$3"}
  G config user.email tester@example.invalid; G config user.name tester
  G config commit.gpgsign false
  echo base > "$repo/base"; G add base; G commit -m base
  G checkout -b br
  record "$1" "$repo" br
  echo a > "$repo/a"; G add a; G commit -m a
  G checkout "$trunk"
  echo t > "$repo/t"; G add t; G commit -m trunk
}
prove() { # prove <holding> <branch> -> sets OUT and RC
  OUT=$("$ROOT/bin/reeve-teardown" --prove-landed "$1" "$2" 2>&1); RC=$?
}

# 1 cherry-picked: the case the grant exists for.
scene pick; G cherry-pick br
prove "$repo" br
ck_eq  "1 cherry-picked branch proves"          "$RC" 0
ck_has "1 verdict line says proven"             "$OUT" "proven: all 1 commit(s) on br"
ck_eq  "1 one line only"                        "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1
ck_eq  "1 changes nothing, branch still there"  "$(git -C "$repo" branch --list br)" "  br"

# 2 squash-landed: two commits, landed as one, so neither has an equivalent.
scene squash
G checkout br; echo b > "$repo/b"; G add b; G commit -m b; G checkout main
G merge --squash br; G commit -m squashed
prove "$repo" br
ck_eq  "2 squash-landed branch does not prove"  "$RC" 1
ck_has "2 names the + commits"                  "$OUT" "2 of 2 commit(s) on br have no patch"

# 3 not landed at all.
scene none
prove "$repo" br
ck_eq  "3 unlanded branch does not prove"       "$RC" 1

# 4 wrong default: the holding's default is master, main does not exist. By
# name, `git cherry -v main br` exits 128 with nothing on stdout.
scene master master
prove "$repo" br
ck_eq  "4 missing default does not prove"       "$RC" 1
ck_has "4 says the default branch is missing"   "$OUT" "no branch refs/heads/main"

# 5 the same repository registered with base: master, by name and by path.
G cherry-pick br
printf -- '- holding: mst | manor: m | path: %s | base: master\n' "$repo" \
  > "$REEVE_HOME/manors.md"
prove mst br
ck_eq  "5 registered base: master proves by name" "$RC" 0
prove "$repo" br
ck_eq  "5 and by path"                            "$RC" 0
rm -f "$REEVE_HOME/manors.md"

# 6 tag shadow: a tag named main on the branch tip. By name, `git cherry -v main
# br` warns the refname is ambiguous, takes the tag, and prints nothing at exit 0.
scene tag; G tag main br
prove "$repo" br
ck_eq  "6 tag named main does not shadow the branch" "$RC" 1
ck_has "6 asks refs/heads/main, sees the + line"     "$OUT" "1 of 1 commit(s) on br"

# 7 merge-only content: br merges side with a merge commit that also adds g, and
# main cherry-picks both plain commits. git cherry prints only `-` lines, and g
# is on no branch but br.
scene merge
G checkout -b side main; echo s > "$repo/s"; G add s; G commit -m s
G checkout br; G merge --no-ff --no-commit side
echo g > "$repo/g"; G add g; G commit -m merge-with-g
G checkout main; G cherry-pick "br^2"; G cherry-pick "br^1"
ck_eq  "7 setup: cherry is all -"  "$(git -C "$repo" cherry main br | grep -c '^+')" 0
prove "$repo" br
ck_eq  "7 merge-carrying branch does not prove"  "$RC" 1
ck_has "7 names the merge commit"                "$OUT" "1 merge commit(s)"

# 8 nothing to prove: br is an ancestor of main, so -d is the tool.
scene ancestor; G merge --no-edit br
prove "$repo" br
ck_eq  "8 ancestor does not prove under -D"     "$RC" 1
ck_has "8 says nothing to prove"                "$OUT" "nothing to prove"
ck_has "8 points at the drop that marks the record" "$OUT" "reeve-teardown ancestor --drop-branch"

# 9 checked out in a copy, and in the primary checkout.
scene wt; G cherry-pick br; G worktree add "$SCRATCH/wt-copy" br
prove "$repo" br
ck_eq  "9 branch checked out in a copy does not prove" "$RC" 1
ck_has "9 names the copy"                              "$OUT" "checked out at"
G worktree remove "$SCRATCH/wt-copy"; G checkout br
prove "$repo" br
ck_eq  "9 nor checked out in the primary checkout"     "$RC" 1

# 10 the branch is the default itself, and a branch that does not exist.
scene self
prove "$repo" main
ck_eq  "10 the default branch never proves"     "$RC" 1
prove "$repo" no-such
ck_eq  "10 a missing branch never proves"       "$RC" 1
prove "$SCRATCH/not-a-repo" br
ck_eq  "10 an unresolvable holding never proves" "$RC" 1

# 11 the limit named in the contract: patch ids ignore whitespace. Pinned here so
# a change in either direction is a decision, not an accident.
scene ws
G checkout br; printf 'def z():\nreturn 1\n' > "$repo/p.py"; G add p.py; G commit -m p
G checkout main; G cherry-pick "br~1"
printf 'def z():\n    return 1\n' > "$repo/p.py"; G add p.py; G commit -m p
prove "$repo" br
ck_eq  "11 a whitespace-only difference still proves (named limit)" "$RC" 0

# 13 scope: only a branch an errand record names for this holding. A torn-down
# record still counts, since a kept branch outlives its copy.
scene scope; G cherry-pick br
printf 'tornDown=2026-01-01T00:00:00\n' >> "$REEVE_HOME/state/scope.meta"
prove "$repo" br
ck_eq  "13 recorded branch proves"                     "$RC" 0
rm -f "$REEVE_HOME/state/scope.meta"
prove "$repo" br
ck_eq  "13 unrecorded branch does not prove"           "$RC" 1
ck_has "13 says no errand record names it"             "$OUT" "no errand record names br"
mkdir -p "$SCRATCH/other"; git -C "$SCRATCH/other" init -q
record scope-other "$SCRATCH/other" br
prove "$repo" br
ck_eq  "13 recorded for another holding does not prove" "$RC" 1
record scope-other "$repo" other-branch
prove "$repo" br
ck_eq  "13 a record for another branch does not prove"  "$RC" 1

# 14 a record only a brief wrote: dispatch never made the branch, and refuses one
# that already exists, so br may be the liege's own. Reproduces the review's scene.
scene briefonly; G cherry-pick br
printf 'office=artificer\nrepo=%s\nbranch=br\n' "$repo" > "$REEVE_HOME/state/briefonly.meta"
prove "$repo" br
ck_eq  "14 a brief-only record does not prove"         "$RC" 1
ck_has "14 says no record shows it made"               "$OUT" "no errand record names br"

# 15 a dropped branch: torn down with --drop-branch, the record is marked, and a
# liege branch later reusing the name does not prove on it.
scene dropped; G merge --no-edit br
printf 'repo=%s\nbranch=br\nbase=main\nwrites=yes\n' "$repo" >> "$REEVE_HOME/state/dropped.meta"
mkdir -p "$REEVE_HOME/errands/dropped"
printf 'done: finished\n' > "$REEVE_HOME/errands/dropped/status"
OUT=$("$ROOT/bin/reeve-teardown" dropped --drop-branch 2>&1); RC=$?
ck_eq  "15 setup: teardown --drop-branch succeeds"     "$RC" 0
ck_eq  "15 the branch is gone"                         "$(git -C "$repo" branch --list br)" ""
ck_has "15 the record is marked dropped"               "$(cat "$REEVE_HOME/state/dropped.meta")" \
       "branchDropped="
G checkout -b br; echo l > "$repo/l"; G add l; G commit -m liege; G checkout main
G cherry-pick br
prove "$repo" br
ck_eq  "15 a liege branch reusing the name does not prove" "$RC" 1
ck_has "15 says no record shows it made"               "$OUT" "no errand record names br"

# 16 --delete-proven: the grant's delete. It deletes and marks every record that
# vouched, so a liege branch later reusing the name does not prove on them.
scene delprove; G cherry-pick br
record delprove-twin "$repo" br
OUT=$("$ROOT/bin/reeve-teardown" --delete-proven "$repo" br 2>&1); RC=$?
ck_eq  "16 a proven branch is deleted"                 "$RC" 0
ck_has "16 says deleted"                               "$OUT" "deleted: br in"
ck_eq  "16 the branch is gone"                         "$(git -C "$repo" branch --list br)" ""
ck_has "16 its record is marked dropped"               "$(cat "$REEVE_HOME/state/delprove.meta")" \
       "branchDropped="
ck_has "16 every vouching record is marked"            \
       "$(cat "$REEVE_HOME/state/delprove-twin.meta")" "branchDropped="
G checkout -b br; echo l > "$repo/l"; G add l; G commit -m liege; G checkout main
G cherry-pick br
prove "$repo" br
ck_eq  "16 a reused name does not prove"               "$RC" 1
ck_has "16 says no record shows it made"               "$OUT" "no errand record names br"
OUT=$("$ROOT/bin/reeve-teardown" --delete-proven "$repo" br 2>&1); RC=$?
ck_eq  "16 nor does it delete"                         "$RC" 1
ck_eq  "16 the reused branch is untouched"             "$(git -C "$repo" branch --list br)" "  br"

# 17 --delete-proven on a branch that does not prove changes nothing.
scene delunproven
OUT=$("$ROOT/bin/reeve-teardown" --delete-proven "$repo" br 2>&1); RC=$?
ck_eq  "17 an unlanded branch is refused"              "$RC" 1
ck_has "17 with the not proven verdict"                "$OUT" "not proven: 1 of 1 commit(s)"
ck_eq  "17 the branch is untouched"                    "$(git -C "$repo" branch --list br)" "  br"
case $(cat "$REEVE_HOME/state/delunproven.meta") in
  *branchDropped=*) bad "17 the record is not marked" ;;
  *) ok "17 the record is not marked" ;;
esac

# 18 the review's scene: a household branch fast-forward landed, so nothing to
# prove, then dropped with plain `git branch -d` as git allows, which marks no
# record. A liege branch reusing the name, landed but for whitespace, must not
# prove on the old record: it is another ref, born again.
scene handd; G merge --no-edit br
born_before=$(. "$ROOT/bin/reeve-lib.sh"; branch_birth "$repo" br)
G branch -d br
ck_eq  "18 setup: br dropped by hand"                  "$(git -C "$repo" branch --list br)" ""
case $(cat "$REEVE_HOME/state/handd.meta") in
  *branchDropped=*) bad "18 setup: the record is not marked" ;;
  *) ok "18 setup: the record is not marked" ;;
esac
G checkout -b br; printf 'y =  2\n' > "$repo/y.py"; G add y.py; G commit -m y
G checkout main; printf 'y = 2\n' > "$repo/y.py"; G add y.py; G commit -m y
ck_eq  "18 setup: the reuse is born again" \
       "$( [ "$(. "$ROOT/bin/reeve-lib.sh"; branch_birth "$repo" br)" != "$born_before" ] \
           && echo yes)" yes
prove "$repo" br
ck_eq  "18 a name reused after a plain -d does not prove" "$RC" 1
ck_has "18 says no record names that ref"              "$OUT" "no errand record names br"
OUT=$("$ROOT/bin/reeve-teardown" --delete-proven "$repo" br 2>&1); RC=$?
ck_eq  "18 nor does it delete"                         "$RC" 1
ck_eq  "18 the liege's branch is untouched"            "$(git -C "$repo" branch --list br)" "  br"

# 19 the same with -D by hand: a cherry-picked household branch, deleted by the
# liege, the name reused by a branch of their own that also lands by pick.
scene handforce; G cherry-pick br
G branch -D br
G checkout -b br; echo l > "$repo/l"; G add l; G commit -m liege; G checkout main
G cherry-pick br
prove "$repo" br
ck_eq  "19 a name reused after a -D by hand does not prove" "$RC" 1
ck_has "19 says no record names that ref"              "$OUT" "no errand record names br"

# 20 the reflog gone: expired, then its file removed. No birth, no proof, even
# for the very ref the record names; and the original ref, reflog intact, still
# proves (case 1 too, every scene does).
scene noreflog; G cherry-pick br
prove "$repo" br
ck_eq  "20 setup: the original ref proves"             "$RC" 0
G reflog expire --expire=now --expire-unreachable=now refs/heads/br
prove "$repo" br
ck_eq  "20 an expired reflog does not prove"           "$RC" 1
ck_has "20 says it has no birth"                       "$OUT" "no reflog"
rm -f "$repo/.git/logs/refs/heads/br"
prove "$repo" br
ck_eq  "20 a removed reflog does not prove"            "$RC" 1
ck_eq  "20 the branch is untouched"                    "$(git -C "$repo" branch --list br)" "  br"

# 21 the reftable scene: a forced rename (-M) or copy (-C) of a liege branch onto
# a live household branch keeps br's old reflog entries under the new ref, so the
# oldest is still the household's birth. Any rename or copy onto the name is no
# birth, so neither proves. Skipped where git has no reftable.
if git init -q --ref-format=reftable "$SCRATCH/rtprobe" >/dev/null 2>&1; then
  for how in M C; do
    scene "rt$how" main reftable; G cherry-pick br
    prove "$repo" br
    ck_eq  "21 -$how setup: the household ref proves on reftable" "$RC" 0
    G checkout -b mine; printf 'y =  2\n' > "$repo/y.py"; G add y.py; G commit -m y
    G checkout main; printf 'y = 2\n' > "$repo/y.py"; G add y.py; G commit -m y
    mine=$(git -C "$repo" rev-parse mine)
    G branch "-$how" mine br
    ck_eq  "21 -$how setup: br is now the liege's" "$(git -C "$repo" rev-parse br)" "$mine"
    ck_eq  "21 -$how a rename or copy onto br has no birth" \
           "$(. "$ROOT/bin/reeve-lib.sh"; branch_birth "$repo" br)" ""
    prove "$repo" br
    ck_eq  "21 -$how onto a household branch does not prove" "$RC" 1
    ck_has "21 -$how says no record names that ref"         "$OUT" "no errand record names br"
    OUT=$("$ROOT/bin/reeve-teardown" --delete-proven "$repo" br 2>&1); RC=$?
    ck_eq  "21 -$how nor does it delete"                    "$RC" 1
    ck_eq  "21 -$how the liege's branch is untouched"       "$(git -C "$repo" branch --list br)" "  br"
  done
else
  printf 'skip  21 this git has no reftable (git init --ref-format=reftable refused)\n'
fi

# 12 usage errors are not verdicts.
OUT=$("$ROOT/bin/reeve-teardown" --prove-landed only-one 2>&1); RC=$?
ck_eq  "12 wrong arity exits 1"                 "$RC" 1
ck_has "12 and prints usage"                    "$OUT" "usage: reeve-teardown --prove-landed"
OUT=$("$ROOT/bin/reeve-teardown" --delete-proven only-one 2>&1); RC=$?
ck_eq  "12 delete-proven wrong arity exits 1"   "$RC" 1
ck_has "12 and prints its usage"                "$OUT" "usage: reeve-teardown --delete-proven"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
