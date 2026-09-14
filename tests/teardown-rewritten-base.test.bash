#!/usr/bin/env bash
# A base that moved AFTER the errand went out looks exactly like work that never
# landed: `merge-base --is-ancestor` fails either way. bin/reeve-teardown used to
# report both as the copy having moved off the base, which is false in one of
# them (the copy never moved) and sends the reader to the branch= line when the
# line that went stale is base=.
#
# Two things are under test, and the second matters more than the first. The
# DIAGNOSIS must tell the two apart. The GATE must not notice: every case here
# refuses, keeps its copy and keeps its commit, exactly as it did before, because
# a rewritten base is a reason to say something true and never a reason to remove
# anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# --- safety -----------------------------------------------------------------
# Same guard as tests/teardown-landed.test.bash, and for the same reason: this
# suite builds throwaway git repositories and tears them down for real, so it
# refuses to run at all unless REEVE_HOME is demonstrably scratch.
real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
if [ -z "$real_home" ]; then
  printf 'FAIL  refusing to run: the real home could not be resolved\n'
  exit 1
fi
scratch_root=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || scratch_root=/tmp
case $scratch_root in "$real_home"|"$real_home"/*) scratch_root=/tmp ;; esac
SCRATCH=$(mktemp -d "$scratch_root/reeve-rewritten-base-test.XXXXXX") || exit 1
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

# Which of two lines comes first, for the one part of a refusal whose ORDER is
# the claim: the advice that ends in a removal must not be read before the
# safeguard that makes acting on it survivable.
order() { # order <text> <first> <second> -> before|after|missing
  local a b
  a=$(printf '%s\n' "$1" | grep -n -F -- "$2" | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$1" | grep -n -F -- "$3" | head -1 | cut -d: -f1)
  if [ -z "$a" ] || [ -z "$b" ]; then printf 'missing\n'
  elif [ "$a" -lt "$b" ]; then printf 'before\n'
  else printf 'after\n'; fi
}

# --- scene builder ----------------------------------------------------------
# One scratch repository per case. `mk` leaves a copy that has committed
# something; what happens to the base afterwards is each case's own business,
# because that is the variable this suite exists to vary.
#
# Where a scene has to move the base backwards it parks a keep/ branch on the
# position being left, so that the only thing unreachable in any of these
# repositories is something the script under test put there. That keeps
# `unreachable` a real assertion rather than a scene artefact.
#
# shape: branch    the copy sits on fix/<id>, as an artificer's does
#        detached  no branch at all, as a scout's or a warden's does
#        clean     detached and committed nothing, as a scout leaves it
mk() { # mk <id> <shape>
  local id=$1 shape=$2
  repo="$SCRATCH/$id"; wt="$SCRATCH/$id.worktrees/w"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email tester@example.invalid
  git -C "$repo" config user.name reeve-test
  printf 'one\n' > "$repo/a.txt"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'init'
  init_sha=$(git -C "$repo" rev-parse main)
  if [ "$shape" = branch ]; then
    br="fix/$id"
    git -C "$repo" worktree add -q "$wt" -b "$br" main
  else
    br=''
    git -C "$repo" worktree add -q --detach "$wt" main
  fi
  if [ "$shape" != clean ]; then
    printf 'two\n' > "$wt/b.txt"
    git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm 'work nobody wants to lose'
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
}

land() { git -C "$repo" merge -q --ff-only "$sha"; }   # the work reaches the base

# n further positions of the base, none of them holding the copy's work, so that
# the entry that DOES hold it can be put at a chosen reflog index. Plumbing
# rather than commits, because what this needs is where main has BEEN, not what
# is in it, and moving the base branch under its own checkout is the point.
filler() { # filler <n>
  local n=$1 i c tree prev
  tree=$(git -C "$repo" rev-parse "$init_sha^{tree}")
  prev=$init_sha
  for i in $(seq 1 "$n"); do
    c=$(git -C "$repo" commit-tree "$tree" -p "$prev" -m "filler $i")
    git -C "$repo" update-ref -m "filler $i" refs/heads/main "$c"
    prev=$c
  done
}

record() { # record <id> [recorded-base]
  local id=$1 recorded=${2:-main}
  mkdir -p "$REEVE_HOME/errands/$id"
  {
    printf 'repo=%s\n'     "$repo"
    printf 'worktree=%s\n' "$wt"
    printf 'branch=%s\n'   "$br"
    printf 'base=%s\n'     "$recorded"
    printf 'writes=yes\n'
  } > "$REEVE_HOME/state/$id.meta"
  printf 'done: finished\n' > "$REEVE_HOME/errands/$id/status"
}

run_teardown() { OUT=$("$ROOT/bin/reeve-teardown" "$@" 2>&1); RC=$?; }

gone() { [ -d "$1" ] && printf 'present\n' || printf 'removed\n'; }
torn() {
  if grep -q '^tornDown=' "$REEVE_HOME/state/$1.meta" 2>/dev/null
  then printf 'yes\n'; else printf 'no\n'; fi
}
survives() { # survives <repo> <sha> -> survived|lost
  git -C "$1" gc --prune=now --quiet >/dev/null 2>&1
  if git -C "$1" cat-file -e "$2" 2>/dev/null; then printf 'survived\n'; else printf 'lost\n'; fi
}
unreachable() { # unreachable <repo> -> none|<sha ...>
  local out
  out=$(git -C "$1" fsck --unreachable --no-reflogs 2>/dev/null \
        | sed -n 's/^unreachable commit //p')
  if [ -n "$out" ]; then printf '%s\n' "$out" | tr '\n' ' '; else printf 'none\n'; fi
}

# The gate's half of every case, asserted separately from the message so that a
# wording change can never quietly take the safety with it.
kept() { # kept <label> <id> <repo> <wt> <sha>
  ck_eq "$1 refuses"           "$RC" 1
  ck_eq "$1 the copy survives" "$(gone "$4")" present
  ck_eq "$1 not marked torn"   "$(torn "$2")" no
  ck_eq "$1 nothing orphaned"  "$(unreachable "$3")" none
  ck_eq "$1 commit not lost"   "$(survives "$3" "$5")" survived
}

# The diagnosis in one phrase, and it is deliberately not a claim about WHEN the
# base moved. The walk proves that the base has held a position containing this
# work and nothing at all about the order of that against the dispatch, so a base
# force-moved before the errand existed reaches the same message.
MOVED='has held a position that does contain that work'
DATED='after this errand went out'          # what it must no longer assert

# 1. THE DEFECT. An artificer's branch that landed, and then main was reset back
#    under it. Before this fix the refusal said the branch had commits main does
#    not have and told the reader to rebase or merge it, which is advice about a
#    branch that already landed.
mk reset-branch branch
land
git -C "$repo" reset -q --hard HEAD~1
old=$(git -C "$repo" rev-parse 'main@{1}')
record reset-branch
run_teardown reset-branch
kept "1" reset-branch "$repo" "$wt" "$sha"
ck_has "1 it says the base moved"            "$OUT" "$MOVED"
ck_has "1 it names the branch, not the copy" "$OUT" "fix/reset-branch is not on main"
ck_has "1 it names the old position"         "$OUT" "$old"
ck_has "1 it names the position now"         "$OUT" "$(git -C "$repo" rev-parse main)"
ck_has "1 it names the move that did it"     "$OUT" "reset: moving to HEAD~1"
ck_has "1 it names the line to correct"      "$OUT" "base= line in $REEVE_HOME/state/reset-branch.meta"
ck_not "1 it does not blame the copy"        "$OUT" "has moved off main"
ck_not "1 it does not say rebase or merge"   "$OUT" "Rebase or merge it first"
ck_not "1 it does not date the move"         "$OUT" "$DATED"

# 2. the same shape with an amended base, which is the common half: the work IS
#    on main, under another sha. Patch equivalence is allowed to say so, as a
#    guess, and is never why anything is removed. The gate assertions above are
#    what prove the second half.
mk amended-branch branch
land
git -C "$repo" commit -q --amend -m 'work nobody wants to lose, reworded'
record amended-branch
run_teardown amended-branch
kept "2" amended-branch "$repo" "$wt" "$sha"
ck_has "2 it says the base moved"            "$OUT" "$MOVED"
ck_has "2 it offers the patch-text guess"    "$OUT" "has an equivalent on main by patch text"
ck_has "2 it labels the guess as a guess"    "$OUT" "a guess for you to confirm"

# 3. the copy's own HEAD, which is the fact the original wording was about. A
#    scout-shaped errand with no branch recorded: check 4a cannot run at all, so
#    this is check 4b reaching the diagnosis on its own.
mk reset-detached detached
land
git -C "$repo" reset -q --hard HEAD~1
record reset-detached
run_teardown reset-detached
kept "3" reset-detached "$repo" "$wt" "$sha"
ck_has "3 it says the base moved"            "$OUT" "$MOVED"
ck_has "3 it names the copy's path"          "$OUT" "the copy at $wt"
ck_has "3 it names where the copy is"        "$OUT" "detached at $sha"
ck_not "3 it does not blame the copy"        "$OUT" "has moved off main"
# Correcting base= to a position the base no longer holds ends in a removal, and
# for a detached copy nothing else is holding that commit. The refusal has to say
# so, or its own advice is the way the work is lost. It also has to say it FIRST:
# a safeguard read after the edit it protects against has already been read too
# late, and this is the one paragraph in the file where that is true.
ck_has "3 it says how to give the work a ref" "$OUT" "git -C $repo branch <name> $sha"
ck_eq  "3 the ref comes before the base= advice" \
       "$(order "$OUT" "branch <name> $sha" "correct the base= line")" before

# 3b. the same, with the copy's directory gone out of band. The base moving does
#     not make git's entry under .git/worktrees/ any less the last root holding
#     that commit, so that warning has to survive the new diagnosis.
mk absent-reset detached
land
git -C "$repo" reset -q --hard HEAD~1
record absent-reset
rm -rf "$wt"
run_teardown absent-reset
ck_eq  "3b refuses"                          "$RC" 1
ck_eq  "3b not marked torn"                  "$(torn absent-reset)" no
ck_eq  "3b nothing orphaned"                 "$(unreachable "$repo")" none
ck_eq  "3b commit not lost"                  "$(survives "$repo" "$sha")" survived
ck_has "3b it says the base moved"           "$OUT" "$MOVED"
ck_has "3b it still warns about the prune"   "$OUT" "git worktree prune"
ck_has "3b it says the directory is absent"  "$OUT" "Its directory is not there"

# 3c. the base moved AND the copy moved, which is one scene rather than two. The
#     branch landed; the copy then detached and committed on top of it; the base
#     took that in and was reset back. So check 4a passes on the branch, check 4b
#     fails on the copy, and the base's reflog does hold a position containing
#     the copy's HEAD. The new diagnosis fires, and it must not swallow the other
#     half: a copy sitting off a branch that DID land is the disagreement the
#     unmoved-base refusal reports, and the base having moved as well does not
#     make it any less true. Saying only that the base moved points the reader at
#     base=, which here is not the only line that went stale.
mk branch-landed-copy-off branch
land
git -C "$wt" checkout -q --detach
printf 'three\n' > "$wt/c.txt"
git -C "$wt" add -A >/dev/null; git -C "$wt" commit -qm 'work on top of the landed branch'
later=$(git -C "$wt" rev-parse HEAD)
git -C "$repo" merge -q --ff-only "$later"
git -C "$repo" reset -q --hard "$sha"
record branch-landed-copy-off
run_teardown branch-landed-copy-off
kept "3c" branch-landed-copy-off "$repo" "$wt" "$later"
ck_has "3c it says the base moved"           "$OUT" "$MOVED"
ck_has "3c it names the branch that landed"  "$OUT" "fix/branch-landed-copy-off, which did land"
ck_has "3c it keeps the disagreement too"    "$OUT" "The record and the copy disagree"
ck_not "3c it does not say nothing moved"    "$OUT" "So nothing this errand holds has moved"

# --- the refusals that must NOT change --------------------------------------
# Everything below arrives at the same two checks with the same failure, and
# each must keep the wording it had. A diagnosis that fires when it cannot
# prove itself is worse than the one it replaced.

# 4. work that genuinely never landed, on a base that never moved.
mk unlanded branch
record unlanded
run_teardown unlanded
kept "4" unlanded "$repo" "$wt" "$sha"
ck_has "4 it keeps the original wording"     "$OUT" "1 commit(s) that main does not have"
ck_not "4 it does not claim the base moved"  "$OUT" "$MOVED"

# 4b. work that never landed, on a base that HAS moved, twice, for reasons of
#     its own. The reflog is full of other positions and not one of them holds
#     this work, so the walk must come back with nothing.
mk unlanded-busy-base branch
printf 'unrelated\n' > "$repo/c.txt"
git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'unrelated work'
git -C "$repo" branch keep/unrelated main
git -C "$repo" reset -q --hard HEAD~1
printf 'unrelated again\n' > "$repo/d.txt"
git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'unrelated work, again'
record unlanded-busy-base
run_teardown unlanded-busy-base
kept "4b" unlanded-busy-base "$repo" "$wt" "$sha"
ck_has "4b it keeps the original wording"    "$OUT" "1 commit(s) that main does not have"
ck_not "4b it does not claim the base moved" "$OUT" "$MOVED"

# 4c. the detached shape of the same thing, which is the wording the defect was
#     reported against: here "the copy at X has moved off main" is TRUE, and has
#     to stay.
mk unlanded-detached detached
record unlanded-detached
run_teardown unlanded-detached
kept "4c" unlanded-detached "$repo" "$wt" "$sha"
ck_has "4c it keeps the original wording"    "$OUT" "has moved off main"
ck_not "4c it does not claim the base moved" "$OUT" "$MOVED"

# 5. cannot tell: the reflog is gone. A fresh clone has no reflog for main
#    beyond its own creation, and core.logAllRefUpdates is off by default in a
#    bare repository, so this is the ordinary state rather than a curiosity.
mk no-reflog branch
land
git -C "$repo" reset -q --hard HEAD~1
rm -f "$repo/.git/logs/refs/heads/main"
record no-reflog
run_teardown no-reflog
kept "5" no-reflog "$repo" "$wt" "$sha"
ck_has "5 it falls back to the old wording"  "$OUT" "1 commit(s) that main does not have"
ck_not "5 it does not claim the base moved"  "$OUT" "$MOVED"

# 5a. cannot tell: the reflog expired rather than being deleted, which is a
#     different mechanism from case 5 and lands in a different place in the walk.
#     The log FILE is still there and git still answers; it just answers with
#     nothing, so the emptiness has to be caught as its own "cannot tell".
mk expired-reflog branch
land
git -C "$repo" reset -q --hard HEAD~1
git -C "$repo" reflog expire --expire=now --all
record expired-reflog
run_teardown expired-reflog
kept "5a" expired-reflog "$repo" "$wt" "$sha"
ck_has "5a it falls back to the old wording" "$OUT" "1 commit(s) that main does not have"
ck_not "5a it does not claim the base moved" "$OUT" "$MOVED"

# 5a2. cannot tell: the reflog is there and cannot be read. Whether git errors or
#      returns nothing is git's business and has varied; either way this is a
#      question that was not answered, and an unanswered question is the original
#      refusal. Asserted as a fallback, never as a particular git behaviour.
mk unreadable-reflog branch
land
git -C "$repo" reset -q --hard HEAD~1
chmod 000 "$repo/.git/logs/refs/heads/main"
record unreadable-reflog
run_teardown unreadable-reflog
chmod 644 "$repo/.git/logs/refs/heads/main"
kept "5a2" unreadable-reflog "$repo" "$wt" "$sha"
if [ "$(id -u)" = 0 ]; then
  # The scene is still built and the gate still asserted above, so case 7 below
  # keeps its count; only the claim this mode cannot make is withheld.
  ok "5a2 wording not asserted as root, where a mode of 000 stops no read"
else
  ck_has "5a2 it falls back to the old wording" "$OUT" "1 commit(s) that main does not have"
  ck_not "5a2 it does not claim the base moved" "$OUT" "$MOVED"
fi

# 5a3. cannot tell: the move is further back than the walk looks. And 5a4, its
#      control: the same scene one entry nearer, where the diagnosis does fire.
#      Both halves or neither, because a bound is a claim about an edge and one
#      side of it alone says nothing about where that edge is. BASE_REFLOG_DEPTH
#      entries are read, indices 0 to 39, so the work at index 40 is outside.
mk reflog-depth-40 branch
land
filler 40
record reflog-depth-40
run_teardown reflog-depth-40
kept "5a3" reflog-depth-40 "$repo" "$wt" "$sha"
ck_has "5a3 past the bound it falls back"    "$OUT" "1 commit(s) that main does not have"
ck_not "5a3 past the bound it says nothing"  "$OUT" "$MOVED"

mk reflog-depth-39 branch
land
filler 39
record reflog-depth-39
run_teardown reflog-depth-39
kept "5a4" reflog-depth-39 "$repo" "$wt" "$sha"
ck_has "5a4 at the bound it still diagnoses" "$OUT" "$MOVED"
ck_has "5a4 it names the entry it found"     "$OUT" "main@{39}"

# 5b. cannot tell: base= recorded as a sha. It resolves, so the invariant runs,
#     but a sha has no reflog of its own and nothing says which ref it came
#     from. Guessing one would be the fail-open this file exists to refuse.
mk sha-base branch
land
git -C "$repo" reset -q --hard HEAD~1
record sha-base "$(git -C "$repo" rev-parse main)"
run_teardown sha-base
kept "5b" sha-base "$repo" "$wt" "$sha"
ck_not "5b it does not claim the base moved" "$OUT" "$MOVED"

# 5c. cannot tell: base= is HEAD and the repository's HEAD is detached, so it
#     resolves to a commit and to no ref at all.
mk detached-base branch
land
git -C "$repo" reset -q --hard HEAD~1
git -C "$repo" checkout -q --detach
record detached-base HEAD
run_teardown detached-base
kept "5c" detached-base "$repo" "$wt" "$sha"
ck_not "5c it does not claim the base moved" "$OUT" "$MOVED"

# 5d. cannot tell, and nothing to tell it with: repo= naming a directory that is
#     not a repository. require_base owns that refusal and keeps it.
mk not-a-repo branch
land
git -C "$repo" reset -q --hard HEAD~1
bad_repo=$SCRATCH/not-a-repo-plain; mkdir -p "$bad_repo"
real_repo=$repo
printf 'repo=%s\nworktree=%s\nbranch=%s\nbase=main\nwrites=yes\n' "$bad_repo" "$wt" "$br" \
  > "$REEVE_HOME/state/not-a-repo.meta"
mkdir -p "$REEVE_HOME/errands/not-a-repo"
printf 'done: finished\n' > "$REEVE_HOME/errands/not-a-repo/status"
run_teardown not-a-repo
ck_eq  "5d a repo= that is not a repository refuses" "$RC" 1
ck_eq  "5d the copy survives"                "$(gone "$wt")" present
ck_has "5d it refuses on the base"           "$OUT" "does not name a commit"
ck_not "5d it does not claim the base moved" "$OUT" "$MOVED"
ck_eq  "5d the commit is not lost"           "$(survives "$real_repo" "$sha")" survived

# --- the teardowns that must still happen -----------------------------------
# The diagnosis is only reached from inside a refusal. These prove it is not
# consulted anywhere else, which is what keeps a rewritten base from turning
# into a new way to refuse a cleanup that was always fine.

# 6. the ordinary artificer: landed, and main moved on afterwards, which it
#    always does. The base moving FORWARD is not a rewrite and must not read as
#    one.
mk landed-advanced branch
land
printf 'unrelated\n' > "$repo/c.txt"
git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'unrelated work lands on main'
record landed-advanced
run_teardown landed-advanced
ck_eq  "6 a landed errand still tears down"  "$RC" 0
ck_eq  "6 its copy is removed"               "$(gone "$wt")" removed
ck_eq  "6 the errand is marked cleaned up"   "$(torn landed-advanced)" yes
ck_eq  "6 nothing is orphaned"               "$(unreachable "$repo")" none
ck_eq  "6 the commit is kept"                "$(survives "$repo" "$sha")" survived

# 6b. a scout's copy, which committed nothing, under a base that was rewritten
#     anyway. Its HEAD is still reachable from where main points now, so there
#     is nothing to diagnose and nothing to refuse.
mk clean-scout clean
printf 'later\n' > "$repo/c.txt"
git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm 'later work'
git -C "$repo" branch keep/pre-amend main
git -C "$repo" commit -q --amend -m 'later work, reworded'
record clean-scout
run_teardown clean-scout
ck_eq  "6b a clean copy under a rewritten base tears down" "$RC" 0
ck_eq  "6b its copy is removed"              "$(gone "$wt")" removed
ck_eq  "6b nothing is orphaned"              "$(unreachable "$repo")" none

# 7. THE BOUNDARY, stated as its own case rather than left to the cases above.
#    Every scene in this file that the gate refused before the diagnosis existed
#    is refused after it, with its copy and its commit intact. The diagnosis
#    changes the words and nothing else, so a future change that lets one of
#    these through has broken the guard, whatever its message says.
n=0
while read -r id <&3; do
  case $id in ''|'#'*) continue ;; esac
  n=$((n+1))
  ck_eq "7 $id was not removed"              "$(gone "$SCRATCH/$id.worktrees/w")" present
  ck_eq "7 $id was not marked torn down"     "$(torn "$id")" no
done 3<<'IDS'
reset-branch
amended-branch
reset-detached
branch-landed-copy-off
unlanded
unlanded-busy-base
unlanded-detached
no-reflog
expired-reflog
unreadable-reflog
reflog-depth-40
reflog-depth-39
sha-base
detached-base
IDS
ck_eq "7 every refused scene was checked"    "$n" 14

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
