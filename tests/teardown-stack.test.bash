#!/usr/bin/env bash
# The stack case in bin/reeve-teardown. An errand based on another errand's
# branch records that branch as base=, and once the whole stack lands on main
# the recorded branch sits behind it: the copy's commits are on main and not on
# base=, so the landed-work test refused work that had landed, every time, and
# the reeve cleared it by hand. The holding's default branch is now asked as
# well. These cases prove the pass, and that nothing which has not landed passes
# with it.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# --- safety -----------------------------------------------------------------
# Real teardowns against throwaway repositories, so it refuses to run unless
# REEVE_HOME is demonstrably scratch. Same guard as teardown-landed.test.bash.
real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
if [ -z "$real_home" ]; then
  printf 'FAIL  refusing to run: the real home could not be resolved\n'
  exit 1
fi
scratch_root=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || scratch_root=/tmp
case $scratch_root in "$real_home"|"$real_home"/*) scratch_root=/tmp ;; esac
SCRATCH=$(mktemp -d "$scratch_root/reeve-stack-test.XXXXXX") || exit 1
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
# A stack of two errands in one repository: A branched off the default branch,
# B branched off A, each with one commit. B is the errand under test, so B is
# the one with a copy and a record, and its record says base=fix/<id>-a, which
# is what bin/reeve-brief writes for `--base fix/<id>-a`.
#
# land: both   A and B fast-forwarded onto the default branch, as the liege
#              lands a stack
#       a      only A, so B still holds a commit nothing else does
#       none   neither
# trunk names the default branch, so a holding whose default is not main can
# be built. holding= is recorded only when one is given.
stack() { # stack <id> <land> [trunk] [holding]
  local id=$1 land=$2 trunk=${3:-main} holding=${4:-}
  repo="$SCRATCH/$id"; wt="$SCRATCH/$id.worktrees/b"
  a_br="fix/$id-a"; b_br="fix/$id-b"
  mkdir -p "$repo"
  git -C "$repo" init -q -b "$trunk"
  git -C "$repo" config user.email tester@example.invalid
  git -C "$repo" config user.name reeve-test
  printf 'one\n' > "$repo/a.txt"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'init'
  git -C "$repo" branch "$a_br" "$trunk"
  git -C "$repo" checkout -q "$a_br"
  printf 'a\n' > "$repo/stack-a.txt"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'the lower errand'
  git -C "$repo" checkout -q "$trunk"
  git -C "$repo" worktree add -q "$wt" -b "$b_br" "$a_br"
  printf 'b\n' > "$wt/stack-b.txt"
  git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm 'the upper errand'
  sha=$(git -C "$wt" rev-parse HEAD)
  case $land in
    both) git -C "$repo" merge -q --ff-only "$b_br" ;;
    a)    git -C "$repo" merge -q --ff-only "$a_br" ;;
  esac
  mkdir -p "$REEVE_HOME/errands/$id"
  {
    printf 'repo=%s\n'     "$repo"
    printf 'worktree=%s\n' "$wt"
    printf 'branch=%s\n'   "$b_br"
    printf 'base=%s\n'     "$a_br"
    printf 'writes=yes\n'
    [ -n "$holding" ] && printf 'holding=%s\n' "$holding"
  } > "$REEVE_HOME/state/$id.meta"
  printf 'done: finished\n' > "$REEVE_HOME/errands/$id/status"
}

# The lower errand's own record, <id>-a: A's branch on the default branch, no
# copy of its own, so tearing it down with --drop-branch deletes base= out from
# under B, the way the reeve cleans up a landed stack.
lower() { # lower <id> [trunk]
  mkdir -p "$REEVE_HOME/errands/$1-a"
  {
    printf 'repo=%s\n'   "$repo"
    printf 'branch=%s\n' "$a_br"
    printf 'base=%s\n'   "${2:-main}"
    printf 'writes=yes\n'
  } > "$REEVE_HOME/state/$1-a.meta"
  printf 'done: finished\n' > "$REEVE_HOME/errands/$1-a/status"
}

register() { # register <holding> <path> <base>
  printf -- '- holding: %s | manor: test | path: %s | instructions: AGENTS.md | base: %s\n' \
    "$1" "$2" "$3" >> "$REEVE_HOME/manors.md"
}

run_teardown() { # run_teardown <id> [args...]  -> sets OUT and RC
  OUT=$("$ROOT/bin/reeve-teardown" "$@" 2>&1); RC=$?
}

gone() { [ -d "$1" ] && printf 'present\n' || printf 'removed\n'; }

# Nothing orphaned, asked of git rather than the script. Reflogs excluded, as in
# teardown-landed.test.bash, so a lost commit cannot hide behind one.
unreachable() { # unreachable <repo> -> none|<sha ...>
  local out
  out=$(git -C "$1" fsck --unreachable --no-reflogs 2>/dev/null \
        | sed -n 's/^unreachable commit //p')
  if [ -n "$out" ]; then printf '%s\n' "$out" | tr '\n' ' '; else printf 'none\n'; fi
}
survives() { # survives <repo> <sha> -> survived|lost
  git -C "$1" gc --prune=now --quiet >/dev/null 2>&1
  if git -C "$1" cat-file -e "$2" 2>/dev/null; then printf 'survived\n'; else printf 'lost\n'; fi
}

# 1. THE STACK CASE. A and B both landed on main by fast-forward, base= still
#    names A, which now sits one commit behind main. Refused before the fix,
#    on work that is plainly on main.
stack landed both
run_teardown landed
ck_eq  "1 a landed stack tears down"                  "$RC" 0
ck_has "1 it says the checks passed"                  "$OUT" "landed-work checks passed"
ck_eq  "1 the copy is removed"                        "$(gone "$wt")" removed
ck_eq  "1 nothing is orphaned"                        "$(unreachable "$repo")" none
ck_eq  "1 the upper commit survives"                  "$(survives "$repo" "$sha")" survived

# 1b. the same, with --drop-branch, which is how the reeve finishes a landed
#     errand. -d deletes it because main holds it.
stack landed-drop both
run_teardown landed-drop --drop-branch
ck_eq  "1b a landed stack tears down with its branch" "$RC" 0
ck_eq  "1b the branch is gone"                        \
       "$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$b_br" >/dev/null && echo kept || echo dropped)" dropped
ck_eq  "1b nothing is orphaned"                       "$(unreachable "$repo")" none

# 2. the stack's lower half landed, its upper half did not. B holds a commit
#    that neither A nor main has, so it refuses, and says which two refs it
#    asked: a refusal naming only base= reads exactly like the old false one.
stack upper-unlanded a
run_teardown upper-unlanded
ck_eq  "2 an unlanded upper errand refuses"           "$RC" 3
ck_eq  "2 the copy survives"                          "$(gone "$wt")" present
ck_has "2 it counts the unlanded commit"              "$OUT" "1 commit(s)"
ck_has "2 it names both refs it checked"              "$OUT" "neither $a_br nor main has"
ck_has "2 it names the commit"                        "$OUT" "the upper errand"
ck_eq  "2 the commit is not lost"                     "$(survives "$repo" "$sha")" survived

# 2b. nothing landed at all. Same answer.
stack nothing-landed none
run_teardown nothing-landed
ck_eq  "2b an unlanded stack refuses"                 "$RC" 3
ck_eq  "2b the copy survives"                         "$(gone "$wt")" present
ck_has "2b it names both refs it checked"             "$OUT" "neither $a_br nor main has"

# 2c. the copy's own HEAD, the second fact. The branch is landed, but the copy
#     sits detached on a commit that is on nothing. The refusal names both refs
#     there too.
stack copy-off both
git -C "$wt" checkout -q --detach
printf 'c\n' > "$wt/stack-c.txt"
git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm 'work on no ref'
off_sha=$(git -C "$wt" rev-parse HEAD)
run_teardown copy-off
ck_eq  "2c a copy off a landed stack refuses"         "$RC" 1
ck_eq  "2c the copy survives"                         "$(gone "$wt")" present
ck_has "2c it names both refs it checked"             "$OUT" "moved off $a_br or main"
ck_eq  "2c nothing is orphaned"                       "$(unreachable "$repo")" none
ck_eq  "2c the commit is not lost"                    "$(survives "$repo" "$off_sha")" survived

# 3. the default branch comes from the holding's base: in manors.md, the same
#    place bin/reeve-brief reads it. A repository whose default is trunk, with
#    no main at all, registered as such: the landed stack passes.
stack trunk-registered both trunk trunk-holding
register trunk-holding "$repo" trunk
run_teardown trunk-registered
ck_eq  "3 a registered default branch is asked"       "$RC" 0
ck_eq  "3 the copy is removed"                        "$(gone "$wt")" removed
ck_eq  "3 nothing is orphaned"                        "$(unreachable "$repo")" none

# 4. THE DEFAULT DOES NOT RESOLVE. The same trunk repository, unregistered, so
#    the default falls back to main, which does not exist there. Behaves exactly
#    as before the fix: refuses on base= alone and names only base=.
stack trunk-unregistered both trunk
run_teardown trunk-unregistered
ck_eq  "4 an unresolvable default refuses as before"  "$RC" 3
ck_eq  "4 the copy survives"                          "$(gone "$wt")" present
ck_has "4 it refuses on base= alone"                  "$OUT" "1 commit(s) that $a_br does not have"
ck_not "4 it does not claim main was checked"         "$OUT" "nor main"
ck_eq  "4 the commit is not lost"                     "$(survives "$repo" "$sha")" survived

# 4b. registered, but naming a branch that is not there. Same: as before.
stack bad-registered both trunk bad-holding
register bad-holding "$repo" no-such-branch
run_teardown bad-registered
ck_eq  "4b a registered default that does not resolve refuses" "$RC" 3
ck_eq  "4b the copy survives"                         "$(gone "$wt")" present
ck_not "4b it does not name the missing default"      "$OUT" "no-such-branch"

# 5. base= deleted once it landed, which is the order a stack is normally
#    cleaned up in. The default branch is asked alone, and B is on it, so it
#    passes. Refused before, on work plainly on main.
stack deleted-base both
git -C "$repo" branch -q -D "$a_br"
run_teardown deleted-base
ck_eq  "5 a deleted base= over a landed stack tears down" "$RC" 0
ck_has "5 it says the checks passed"                  "$OUT" "landed-work checks passed"
ck_eq  "5 the copy is removed"                        "$(gone "$wt")" removed
ck_eq  "5 nothing is orphaned"                        "$(unreachable "$repo")" none
ck_eq  "5 the upper commit survives"                  "$(survives "$repo" "$sha")" survived

# 5b. the same reached the way the reeve actually gets there: the lower errand
#     torn down first with --drop-branch, then the upper one.
stack lower-first both
lower lower-first
run_teardown lower-first-a --drop-branch
ck_eq  "5b the lower errand tears down first"         "$RC" 0
ck_eq  "5b its branch is gone"                        \
       "$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$a_br" >/dev/null && echo kept || echo dropped)" dropped
run_teardown lower-first
ck_eq  "5b then the upper errand tears down"          "$RC" 0
ck_eq  "5b the copy is removed"                       "$(gone "$wt")" removed
ck_eq  "5b nothing is orphaned"                       "$(unreachable "$repo")" none
ck_eq  "5b the upper commit survives"                 "$(survives "$repo" "$sha")" survived

# 5c. the same order, but only the lower errand landed. B holds a commit main
#     does not, so it refuses, and says base= was missing rather than reading as
#     though it had been asked.
stack lower-only a
lower lower-only
run_teardown lower-only-a --drop-branch
ck_eq  "5c the lower errand tears down"               "$RC" 0
run_teardown lower-only
ck_eq  "5c the unlanded upper errand refuses"         "$RC" 1
ck_eq  "5c the copy survives"                         "$(gone "$wt")" present
ck_has "5c it names the ref it asked"                 "$OUT" "1 commit(s) that main does not have"
ck_has "5c it says base= was missing"                 "$OUT" "The recorded base '$a_br' does not name a commit"
ck_has "5c it says only the default was asked"        "$OUT" "main was asked. If the work belongs"
ck_not "5c it does not claim base= was asked"         "$OUT" "neither"
ck_eq  "5c the commit is not lost"                    "$(survives "$repo" "$sha")" survived

# 5d. base= deleted with nothing landed. Its commit is held by B alone now, and
#     both are off main.
stack deleted-unlanded none
git -C "$repo" branch -q -D "$a_br"
run_teardown deleted-unlanded
ck_eq  "5d a deleted base= over unlanded work refuses" "$RC" 1
ck_eq  "5d the copy survives"                         "$(gone "$wt")" present
ck_has "5d it counts both unlanded commits"           "$OUT" "2 commit(s) that main does not have"
ck_eq  "5d the commit is not lost"                    "$(survives "$repo" "$sha")" survived

# 5e. base= deleted and the default does not resolve either. Nothing left to
#     ask, so it is require_base's refusal, exactly as before.
stack deleted-no-default both trunk
git -C "$repo" branch -q -D "$a_br"
run_teardown deleted-no-default
ck_eq  "5e no base= and no default refuses"           "$RC" 1
ck_has "5e it says the base does not resolve"         "$OUT" "does not name a commit"
ck_not "5e it does not claim main was asked"          "$OUT" "main was asked."
ck_eq  "5e the copy survives"                         "$(gone "$wt")" present

# 5f. base= deleted, the stack landed, the copy detached on work that is on
#     nothing. The second fact refuses, naming the default and the missing base.
stack deleted-copy-off both
git -C "$repo" branch -q -D "$a_br"
git -C "$wt" checkout -q --detach
printf 'c\n' > "$wt/stack-c.txt"
git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm 'work on no ref'
off_sha=$(git -C "$wt" rev-parse HEAD)
run_teardown deleted-copy-off
ck_eq  "5f a copy off a landed stack refuses"         "$RC" 1
ck_has "5f it names the default"                      "$OUT" "moved off main ("
ck_has "5f it says base= was missing"                 "$OUT" "main was asked. If the work belongs"
ck_eq  "5f the commit is not lost"                    "$(survives "$repo" "$off_sha")" survived

# 6. the default is a branch, refs/heads/<default>, and nothing else. A base:
#    line naming a tag, a sha or the errand's own branch, each sitting on B's
#    commit, would pass B unlanded if any revision were taken. Nothing landed in
#    any of these, so each must refuse on base= alone.
stack tag-default none main tag-holding
git -C "$repo" tag v1 "$sha"
register tag-holding "$repo" v1
run_teardown tag-default
ck_eq  "6 a default naming a tag is not asked"        "$RC" 3
ck_eq  "6 the copy survives"                          "$(gone "$wt")" present
ck_not "6 it does not name the tag"                   "$OUT" "nor v1"

stack sha-default none main sha-holding
register sha-holding "$repo" "$sha"
run_teardown sha-default
ck_eq  "6b a default naming a sha is not asked"       "$RC" 3
ck_eq  "6b the copy survives"                         "$(gone "$wt")" present

stack own-default none main own-holding
register own-holding "$repo" "$b_br"
run_teardown own-default
ck_eq  "6c a default naming the errand's own branch is not asked" "$RC" 3
ck_eq  "6c the copy survives"                         "$(gone "$wt")" present
ck_not "6c it does not name its own branch as asked"  "$OUT" "nor $b_br"

# 6d. a tag named main, on B, shadowing the branch main, which holds only A.
#     The branch is what is asked, so it refuses.
stack shadow-main a
git -C "$repo" tag main "$sha"
run_teardown shadow-main
ck_eq  "6d a tag shadowing main is not asked"         "$RC" 3
ck_eq  "6d the copy survives"                         "$(gone "$wt")" present
ck_has "6d it asked the branch main"                  "$OUT" "neither $a_br nor main has"

# 7. a rewritten base= in a stack: B fast-forwarded into A, A reset back, B not
#    on main. The diagnosis is about base=, and it says main was asked too.
stack rewritten-a none
git -C "$repo" checkout -q "$a_br"
git -C "$repo" merge -q --ff-only "$b_br"
git -C "$repo" reset -q --hard HEAD~1
git -C "$repo" checkout -q main
run_teardown rewritten-a
ck_eq  "7 a rewritten stacked base refuses"           "$RC" 1
ck_eq  "7 the copy survives"                          "$(gone "$wt")" present
ck_has "7 it diagnoses the base"                      "$OUT" "$b_br is not on $a_br"
ck_has "7 it says main was asked too"                 "$OUT" "(main was asked too and does not hold it.)"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
