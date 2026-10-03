#!/usr/bin/env bash
# A rebase, merge, cherry-pick, revert or bisect that stops halfway leaves its
# state in the copy's own git directory, and often leaves the tree clean while
# doing it. Before check 2c in bin/reeve-teardown nothing saw it: the landed-work
# test passed on a HEAD that was already landed, `git worktree remove` did not
# object, and the half-finished operation went with the copy without a word.
# Each case below builds the operation for real in a scratch repository, with
# HEAD landed and, wherever git allows, the tree clean, so the only thing
# standing between it and a removal is the guard under test. Then it finishes or
# aborts the operation and proves the same copy now tears down.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# --- safety -----------------------------------------------------------------
# Real teardowns of real copies, so it refuses to run unless REEVE_HOME is
# demonstrably scratch. Same guard as teardown-landed.test.bash.
real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
if [ -z "$real_home" ]; then
  printf 'FAIL  refusing to run: the real home could not be resolved\n'
  exit 1
fi
scratch_root=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || scratch_root=/tmp
case $scratch_root in "$real_home"|"$real_home"/*) scratch_root=/tmp ;; esac
SCRATCH=$(mktemp -d "$scratch_root/reeve-in-progress-test.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/reeve-home"
mkdir -p "$REEVE_HOME/state" || exit 1
home_p=$(cd "$REEVE_HOME" && pwd -P)
case $home_p in
  ''|"$real_home"|"$real_home"/*|*/.reeve|*/.reeve/*)
    printf 'FAIL  refusing to run: REEVE_HOME=%s is at or under the real home\n' "$home_p"
    exit 1 ;;
esac

# A stubbed code root, so the --dismiss-only cases free a session without ever
# opening one, and every kill is countable.
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_launch()          { return 0; }
reeve_backend_stub_agent_state()     { printf 'alive\n'; }
reeve_backend_stub_attention_state() { printf 'settled\n'; }
reeve_backend_stub_wait_change()     { return 2; }
reeve_backend_stub_kill()            { printf '%s\n' "$1" >> "$STUB_KILLS"; return 0; }
ADAPTER
export REEVE_ROOT="$STUB" STUB_KILLS="$SCRATCH/kills"
: > "$STUB_KILLS"

# Hermetic git: no user or system config, no signing, no editor, no hooks.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_EDITOR=: GIT_MERGE_AUTOEDIT=no
export GIT_AUTHOR_NAME=reeve-test GIT_AUTHOR_EMAIL=tester@example.invalid
export GIT_COMMITTER_NAME=reeve-test GIT_COMMITTER_EMAIL=tester@example.invalid

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]: $2" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output should not have said [$3]" ;; *) ok "$1" ;; esac; }

# A rebase -i editor that stops before the first pick, so the rebase is in
# progress with nothing applied, HEAD on the base and the tree clean.
BREAKER="$SCRATCH/break-first"
printf '#!/bin/sh\n{ printf '"'"'break\\n'"'"'; cat "$1"; } > "$1.new" && mv "$1.new" "$1"\n' > "$BREAKER"
chmod +x "$BREAKER"

# --- scene builder ----------------------------------------------------------
# One scratch repository per case. main holds init and then the copy's own two
# commits, already landed, so the landed-work test passes on its own. `side`
# branches from init and rewrites the same line, so anything taken from it
# conflicts. The copy sits on fix/<id> at main, clean.
scene() { # scene <id>  -> sets repo, wt, br
  local id=$1
  repo="$SCRATCH/$id"; wt="$SCRATCH/$id.worktrees/w"; br="fix/$id"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  printf 'one\n' > "$repo/a.txt"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm init
  git -C "$repo" branch side
  git -C "$repo" worktree add -q "$wt" -b "$br" main
  printf 'copy one\n' > "$wt/a.txt"; git -C "$wt" commit -qam 'copy one'
  printf 'copy two\n' > "$wt/a.txt"; git -C "$wt" commit -qam 'copy two'
  git -C "$repo" merge -q --ff-only "$br"
  git -C "$repo" checkout -q side
  printf 'side one\n' > "$repo/a.txt"; git -C "$repo" commit -qam 'side one'
  printf 'side two\n' > "$repo/a.txt"; git -C "$repo" commit -qam 'side two'
  git -C "$repo" checkout -q main
  mkdir -p "$REEVE_HOME/errands/$id"
  printf 'repo=%s\nworktree=%s\nbranch=%s\nbase=main\nwrites=yes\n' "$repo" "$wt" "$br" \
    > "$REEVE_HOME/state/$id.meta"
  printf 'done: finished\n' > "$REEVE_HOME/errands/$id/status"
}

run_teardown() { # run_teardown <id> [args...]  -> sets OUT and RC
  OUT=$("$ROOT/bin/reeve-teardown" "$@" 2>&1); RC=$?
}
gone()  { [ -d "$1" ] && printf 'present\n' || printf 'removed\n'; }
clean() { [ -z "$(git -C "$1" status --porcelain)" ] && printf 'clean\n' || printf 'dirty\n'; }

# refuses_then_passes <n> <id> <kind> <tree> <head> <cleanup command...>
# The scene must already hold the operation. <tree> and <head> say what else
# would have stopped the teardown without the guard: a clean tree with HEAD
# landed is the case where nothing did. Asserts the refusal and that the copy
# survived it, then runs the cleanup in the copy and asserts the same errand
# now tears down.
refuses_then_passes() {
  local n=$1 id=$2 kind=$3 tree=$4 head=$5 at a=a; shift 5
  [ "$kind" = am ] && a=an
  ck_eq  "$n the $kind leaves the tree $tree"           "$(clean "$wt")" "$tree"
  at=moved
  git -C "$repo" merge-base --is-ancestor "$(git -C "$wt" rev-parse HEAD)" main && at=landed
  ck_eq  "$n the $kind leaves HEAD $head"               "$at" "$head"
  run_teardown "$id"
  ck_eq  "$n $a $kind in progress refuses"               "$RC" 1
  ck_has "$n it names the $kind and where"              "$OUT" "this copy has $a $kind in progress: finish or abort it in $wt first"
  ck_not "$n it does not report the checks passed"      "$OUT" "landed-work checks passed"
  ck_eq  "$n the copy is kept"                          "$(gone "$wt")" present
  "$@" >/dev/null 2>&1 || bad "$n the cleanup ran: $*"
  run_teardown "$id"
  ck_eq  "$n after it, the copy tears down"             "$RC" 0
  ck_eq  "$n and is removed"                            "$(gone "$wt")" removed
}

# 1. rebase, stopped at a break before anything applied: tree clean, HEAD on main.
scene rebase-break
GIT_SEQUENCE_EDITOR="$BREAKER" git -C "$wt" rebase -q -i HEAD~1 >/dev/null 2>&1
ck_eq "1 the rebase is really stopped" "$([ -d "$(git -C "$wt" rev-parse --absolute-git-dir)/rebase-merge" ] && echo yes)" yes
refuses_then_passes 1 rebase-break rebase clean landed git -C "$wt" rebase --abort

# 2. rebase stopped on a conflict: the tree is dirty and HEAD is on side, and
# the rebase still has to be what the refusal names, not "uncommitted changes".
scene rebase-conflict
git -C "$wt" rebase -q side >/dev/null 2>&1
refuses_then_passes 2 rebase-conflict rebase dirty moved git -C "$wt" rebase --abort
ck_not "2 the refusal was not the uncommitted-changes one" "$OUT" "uncommitted changes"

# 3. rebase-apply as a rebase leaves it, the apply backend.
scene rebase-apply
git -C "$wt" rebase -q --apply side >/dev/null 2>&1
refuses_then_passes 3 rebase-apply rebase dirty moved git -C "$wt" rebase --abort

# 4. git am, which shares rebase-apply and must not be called a rebase. A patch
# that does not apply leaves the tree untouched, so this one is clean.
scene am
git -C "$repo" format-patch -q -1 side -o "$SCRATCH/am-patches" >/dev/null
git -C "$wt" am -q "$SCRATCH"/am-patches/*.patch >/dev/null 2>&1
refuses_then_passes 4 am am clean landed git -C "$wt" am --abort

# 5. merge stopped before committing, clean tree: -s ours changes nothing.
scene merge-clean
git -C "$wt" merge -q --no-commit -s ours side >/dev/null 2>&1
refuses_then_passes 5 merge-clean merge clean landed git -C "$wt" merge --abort

# 6. merge stopped on a conflict.
scene merge-conflict
git -C "$wt" merge -q side >/dev/null 2>&1
refuses_then_passes 6 merge-conflict merge dirty landed git -C "$wt" merge --abort

# 7. cherry-pick stopped on a conflict.
scene pick-conflict
git -C "$wt" cherry-pick side >/dev/null 2>&1
refuses_then_passes 7 pick-conflict cherry-pick dirty landed git -C "$wt" cherry-pick --abort

# 8. a multi-commit cherry-pick whose stop was reset away: no CHERRY_PICK_HEAD,
# a clean tree, and a sequencer still holding the rest of the list.
scene pick-sequencer
git -C "$wt" cherry-pick side~1 side >/dev/null 2>&1
git -C "$wt" reset -q --hard
refuses_then_passes 8 pick-sequencer cherry-pick clean landed git -C "$wt" cherry-pick --abort

# 9. revert stopped on a conflict.
scene revert-conflict
git -C "$wt" revert --no-edit HEAD~1 >/dev/null 2>&1
refuses_then_passes 9 revert-conflict revert dirty landed git -C "$wt" revert --abort

# 10. a multi-commit revert reduced to its sequencer, read from the todo.
scene revert-sequencer
git -C "$wt" revert --no-edit HEAD~1 HEAD >/dev/null 2>&1
git -C "$wt" reset -q --hard
refuses_then_passes 10 revert-sequencer revert clean landed git -C "$wt" revert --abort

# 11. bisect started and marked, tree clean, HEAD where it was.
scene bisect
git -C "$wt" bisect start >/dev/null 2>&1
git -C "$wt" bisect bad HEAD >/dev/null 2>&1
refuses_then_passes 11 bisect bisect clean landed git -C "$wt" bisect reset
ck_has "11 the advice is the reset, not a --continue" "$(
  scene bisect-advice; git -C "$wt" bisect start >/dev/null 2>&1
  "$ROOT/bin/reeve-teardown" bisect-advice 2>&1)" "bisect reset"

# 12. a bisect ref with no bisect log is still the bisect's.
scene bisect-ref
git -C "$wt" update-ref refs/bisect/bad HEAD
refuses_then_passes 12 bisect-ref bisect clean landed git -C "$wt" update-ref -d refs/bisect/bad

# 13. the copy's own ref namespaces, deleted with it.
for ns in worktree rewritten; do
  scene "ref-$ns"
  git -C "$wt" update-ref "refs/$ns/keep" HEAD
  run_teardown "ref-$ns"
  ck_eq  "13 a refs/$ns ref refuses"                  "$RC" 1
  ck_has "13 it says the refs go with the copy"       "$OUT" "this copy holds refs of its own, which are deleted with it"
  ck_has "13 it names the ref"                        "$OUT" "refs/$ns/keep"
  ck_eq  "13 the copy is kept"                        "$(gone "$wt")" present
  git -C "$wt" update-ref -d "refs/$ns/keep"
  run_teardown "ref-$ns"
  ck_eq  "13 deleted, it tears down"                  "$RC" 0
done

# 14. --dismiss-only frees the session and keeps the copy, so an operation in
# progress is no reason to refuse it, with a session to free or without one.
scene dismiss-rebase
GIT_SEQUENCE_EDITOR="$BREAKER" git -C "$wt" rebase -q -i HEAD~1 >/dev/null 2>&1
printf 'target=stub:1\nbackend=stub\n' >> "$REEVE_HOME/state/dismiss-rebase.meta"
run_teardown dismiss-rebase --dismiss-only
ck_eq  "14 --dismiss-only does not refuse"           "$RC" 0
ck_eq  "14 it frees the session"                     "$(grep -c . "$STUB_KILLS" | tr -d ' ')" 1
ck_eq  "14 the copy is kept"                         "$(gone "$wt")" present
ck_eq  "14 and so is the rebase"                     "$([ -d "$(git -C "$wt" rev-parse --absolute-git-dir)/rebase-merge" ] && echo yes)" yes
scene dismiss-merge
git -C "$wt" merge -q side >/dev/null 2>&1
run_teardown dismiss-merge --dismiss-only
ck_eq  "14 with no session it does not refuse either" "$RC" 0
ck_eq  "14 the copy is kept"                          "$(gone "$wt")" present
run_teardown dismiss-merge
ck_eq  "14 a full teardown afterwards still refuses"  "$RC" 1

# 15. a copy whose directory is gone: unchanged, there is nothing to finish and
# nothing to remove, and the landed-work test decides on git's record alone.
scene absent
GIT_SEQUENCE_EDITOR="$BREAKER" git -C "$wt" rebase -q -i HEAD~1 >/dev/null 2>&1
rm -rf "$wt"
run_teardown absent
ck_eq  "15 an absent copy tears down as before"      "$RC" 0
ck_not "15 nothing is said about the rebase"         "$OUT" "in progress"

# 16. --dry-run is a teardown too, and refuses the same way.
scene dry
git -C "$wt" merge -q --no-commit -s ours side >/dev/null 2>&1
run_teardown dry --dry-run
ck_eq  "16 a dry run refuses as well"                "$RC" 1
ck_has "16 with the same refusal"                    "$OUT" "this copy has a merge in progress"

# 17. clean cases are unchanged: a landed copy and a scout's detached copy go.
scene landed
run_teardown landed
ck_eq  "17 a landed, idle copy tears down"           "$RC" 0
ck_eq  "17 and is removed"                           "$(gone "$wt")" removed
scene scout
git -C "$repo" worktree remove "$wt"
git -C "$repo" worktree add -q --detach "$wt" main
printf 'repo=%s\nworktree=%s\nbranch=\nbase=main\nwrites=no\n' "$repo" "$wt" > "$REEVE_HOME/state/scout.meta"
run_teardown scout
ck_eq  "17 a detached scout copy tears down"         "$RC" 0
ck_eq  "17 and is removed"                           "$(gone "$wt")" removed

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
