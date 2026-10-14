#!/usr/bin/env bash
# bin/reeve-land and bin/reeve-teardown --sweep: a land leaves nothing behind.
#
# Landings used to stop at the fast-forward. Every errand of a chain (an
# original and the mends based on it) kept its branch, and often its copy,
# because the reeve ran `reeve-teardown <id>`, which keeps the branch, and
# never swept the rest; the liege cleaned up by hand, again and again. These
# pin the structural fix: the land itself sweeps the holding, the sweep touches
# only finished errands' own branches that have landed, and a watch that tears
# down a finished errand drops its branch once that branch is already landed.
#
#   1  the land with the default in the primary checkout, which is clean apart
#      from an untracked file
#   2  the land with the default checked out nowhere, HEAD on another branch
#   3  every refusal says `branch ready:` and changes nothing
#   4  a chain of an original and three mends, each based on the one before:
#      the last refuses while the one under it stands, and landing them in turn
#      drops all four branches and copies, beside a liege branch, an in-flight
#      errand, a dirty copy, a ported branch and a branch no record names
#   5  --sweep --dry-run writes nothing, and the sweep is idempotent
#   6  a watch's teardown drops a branch already landed, keeps one that is not
#   7  what the sweep never takes, and a ported branch kept without the grant
#   8  a dev errand lands on dev, never on main, in both forms
#   9  siblings: one rebased and landed, the original and its copy dropped
#   10 another reeve's finish not yet reported to it is kept
#   11 the -d upstream fallback never touches a branch checked out elsewhere
#   12 a chain fast-forwarded onto dev by hand: teardown and sweep take both
#   13 the doctor shows the grant
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# --- safety -----------------------------------------------------------------
# Builds throwaway repositories and removes copies and branches for real, so
# REEVE_HOME must be demonstrably scratch. Same guard as teardown-landed.
real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
if [ -z "$real_home" ]; then
  printf 'FAIL  refusing to run: the real home could not be resolved\n'
  exit 1
fi
scratch_root=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || scratch_root=/tmp
case $scratch_root in "$real_home"|"$real_home"/*) scratch_root=/tmp ;; esac
SCRATCH=$(mktemp -d "$scratch_root/reeve-land-test.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
fresh_home() {
  export REEVE_HOME="$SCRATCH/home-$1"
  mkdir -p "$REEVE_HOME/state" || exit 1
  local home_p; home_p=$(cd "$REEVE_HOME" && pwd -P)
  case $home_p in
    ''|"$real_home"|"$real_home"/*|*/.reeve|*/.reeve/*)
      printf 'FAIL  refusing to run: REEVE_HOME=%s is at or under the real home\n' "$home_p"
      exit 1 ;;
  esac
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output [$2] did not mention [$3]" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output should not have said [$3]" ;; *) ok "$1" ;; esac; }

# --- scene builder ----------------------------------------------------------
# holding <name>: a registered holding on main with one commit.
holding() {
  repo="$SCRATCH/$1"
  git init -q -b main "$repo"
  printf 'a\n' > "$repo/README"; printf 'local.env\n' > "$repo/.gitignore"
  git -C "$repo" add . && git -C "$repo" commit -qm init
  printf -- '- holding: %s | manor: m | path: %s | base: main\n' "$1" "$repo" \
    >> "$REEVE_HOME/manors.md"
}
# errand <id> <base> [status line]: what bin/reeve-dispatch leaves for an
# artificer, a copy on a new branch off <base> and the record naming it as
# born, then one commit in the copy. The status line defaults to done.
errand() {
  local id=$1 base=$2 line=${3:-done: built}
  local wt="$SCRATCH/$(basename "$repo").worktrees/$id" br="feat/$id"
  git -C "$repo" worktree add -q "$wt" -b "$br" "$base"
  mkdir -p "$REEVE_HOME/errands/$id"
  printf 'office=artificer\nholding=%s\nrepo=%s\nworktree=%s\nbranch=%s\nbase=%s\n' \
    "$(basename "$repo")" "$repo" "$wt" "$br" "$base" > "$REEVE_HOME/state/$id.meta"
  printf 'writes=yes\ndispatched=2026-10-14T10:00:00\nsession=%s\nbranchMade=%s\n' \
    "${OWNER:-}" "$(. "$ROOT/bin/reeve-lib.sh"; branch_birth "$repo" "$br")" \
    >> "$REEVE_HOME/state/$id.meta"
  printf '%s\n' "$line" > "$REEVE_HOME/errands/$id/status"
  printf '%s\n' "$id" > "$wt/$id.txt"
  git -C "$wt" add . && git -C "$wt" commit -qm "$id"
}
wt_of()   { printf '%s\n' "$SCRATCH/$(basename "$repo").worktrees/$1"; }
has_br()  { git -C "$repo" rev-parse --verify --quiet "refs/heads/$1" >/dev/null && echo yes || echo no; }
present() { [ -d "$1" ] && echo present || echo removed; }
tip()     { git -C "$repo" rev-parse "refs/heads/$1"; }
meta_of() { grep -m1 "^$2=" "$REEVE_HOME/state/$1.meta" | sed "s/^$2=//"; }
# Everything a refusal could have changed: refs, copies, the tree, the records.
snapshot() {
  git -C "$repo" for-each-ref --format='%(refname) %(objectname)'
  git -C "$repo" worktree list --porcelain
  git -C "$repo" status --porcelain
  (cd "$REEVE_HOME" && find . -type f | sort | xargs cat)
}
land()  { OUT=$("$ROOT/bin/reeve-land" "$@" 2>&1); RC=$?; }
# The liege's standing proven-delete grant, as this machine records it.
grant() { mkdir -p "$REEVE_HOME/config" && echo granted > "$REEVE_HOME/config/proven-delete"; }
sweep() { OUT=$("$ROOT/bin/reeve-teardown" --sweep "$@" 2>&1); RC=$?; }

echo "--- 1. default in the primary checkout ---"
fresh_home one; holding one
errand a main
echo mine > "$repo/notes.txt"
want=$(tip feat/a)
land a
ck_eq  "1 lands"                              "$RC" 0
ck_has "1 says what landed"                   "$OUT" "landed: feat/a onto main"
ck_eq  "1 main is the branch tip"             "$(tip main)" "$want"
ck_eq  "1 the checkout has the incoming file" "$(cat "$repo/a.txt" 2>/dev/null)" a
ck_eq  "1 the untracked file is intact"       "$(cat "$repo/notes.txt")" mine
ck_has "1 cleans the errand"                  "$OUT" "cleaned: a"
ck_has "1 drops its branch"                   "$OUT" "dropped: feat/a"
ck_eq  "1 the branch is gone"                 "$(has_br feat/a)" no
ck_eq  "1 the copy is gone"                   "$(present "$(wt_of a)")" removed
ck_has "1 the record says it was dropped"     "$(meta_of a branchDropped)" 2026
land a
ck_eq  "1 a second land refuses, nothing left" "$RC" 1
ck_has "1 and says why"                       "$OUT" "branch ready:"

echo "--- 2. default checked out nowhere ---"
fresh_home two; holding two
errand b main
git -C "$repo" checkout -q -b side
side=$(tip side)
want=$(tip feat/b)
land b
ck_eq  "2 lands"                              "$RC" 0
ck_eq  "2 main is the branch tip"             "$(tip main)" "$want"
ck_eq  "2 the checkout stays on side"         "$(git -C "$repo" branch --show-current)" side
ck_eq  "2 side did not move"                  "$(tip side)" "$side"
ck_eq  "2 the branch is gone, though HEAD lacks it" "$(has_br feat/b)" no
ck_eq  "2 the copy is gone"                   "$(present "$(wt_of b)")" removed

echo "--- 3. refusals change nothing ---"
fresh_home three; holding three
errand w main "working: still at it"
before=$(snapshot); land w
ck_eq  "3 an errand still working refuses"    "$RC" 1
ck_has "3 says branch ready"                  "$OUT" "branch ready: w has not reported done"
ck_eq  "3 and changed nothing"                "$(snapshot)" "$before"

errand q main "needs-decision [key=k]: which way"
printf 'done: built\n' >> "$REEVE_HOME/errands/q/status"
before=$(snapshot); land q
ck_eq  "3 done with a question open refuses"  "$RC" 1
ck_has "3 names the question"                 "$OUT" "1 question(s) never answered"
ck_eq  "3 and changed nothing"                "$(snapshot)" "$before"

errand d main
echo edited > "$repo/README"
before=$(snapshot); land d
ck_eq  "3 a dirty primary checkout refuses"   "$RC" 1
ck_has "3 names the tracked change"           "$OUT" "has changes to tracked files"
ck_eq  "3 and changed nothing"                "$(snapshot)" "$before"
git -C "$repo" checkout -q README

errand n main
echo t > "$repo/t"; git -C "$repo" add t; git -C "$repo" commit -qm moved
before=$(snapshot); land n
ck_eq  "3 a branch that does not fast-forward refuses" "$RC" 1
ck_has "3 says so"                            "$OUT" "does not fast-forward main"
ck_eq  "3 and changed nothing"                "$(snapshot)" "$before"

errand o main
git -C "$repo" checkout -q --detach
git -C "$repo" worktree add -q "$SCRATCH/elsewhere" main
before=$(snapshot); land o
ck_eq  "3 main checked out in another copy refuses" "$RC" 1
ck_has "3 names where"                        "$OUT" "main is checked out at"
ck_eq  "3 and changed nothing"                "$(snapshot)" "$before"
git -C "$repo" worktree remove "$SCRATCH/elsewhere"; git -C "$repo" checkout -q main

git -C "$repo" branch liege/x main
printf 'office=artificer\nholding=three\nrepo=%s\nbranch=liege/x\nbranchMade=%s\n' "$repo" \
  "0000000000000000000000000000000000000000 0" > "$REEVE_HOME/state/forged.meta"
mkdir -p "$REEVE_HOME/errands/forged"; printf 'done: x\n' > "$REEVE_HOME/errands/forged/status"
before=$(snapshot); land forged
ck_eq  "3 a branch the record did not make refuses" "$RC" 1
ck_has "3 says it is the liege's call"        "$OUT" "landing it is the liege's call"
ck_eq  "3 and changed nothing"                "$(snapshot)" "$before"

before=$(snapshot); land nosuch
ck_eq  "3 no record refuses"                  "$RC" 1
ck_has "3 says so"                            "$OUT" "branch ready: no errand record"
ck_eq  "3 and changed nothing"                "$(snapshot)" "$before"

echo "--- 4. a chain of four, landed in turn ---"
fresh_home four; holding four; grant
git -C "$repo" branch liege/wip main          # the liege's, on main already
git -C "$repo" branch stray main              # no record names it
errand busy main "working: just started"      # in flight, its commit not landed
git -C "$(wt_of busy)" reset -q --hard main   # so it sits on main, landed by ancestry
errand dirty main
git -C "$(wt_of dirty)" reset -q --hard main
echo wip > "$(wt_of dirty)/scratch.txt"       # uncommitted work in its copy
errand port main                              # landed later under another commit id
port_sha=$(tip feat/port)
git -C "$repo" worktree remove "$(wt_of port)"
errand orig main
errand mend-1 feat/orig
errand mend-2 feat/mend-1
errand mend-3 feat/mend-2
git -C "$(wt_of mend-3)" cherry-pick "$port_sha" >/dev/null
before=$(snapshot); land mend-3
ck_eq  "4 the last refuses while the one under it stands" "$RC" 1
ck_has "4 and says which to land first"       "$OUT" \
  "branch ready: based on errand branch feat/mend-2, land that first or rebuild on main"
ck_eq  "4 and changed nothing"                "$(snapshot)" "$before"
ALL=''
for e in orig mend-1 mend-2 mend-3; do
  land "$e"
  ck_eq  "4 $e lands"                         "$RC" 0
  ck_has "4 $e lands on main"                 "$OUT" "landed: feat/$e onto main"
  ALL="$ALL
$OUT"
done
for e in orig mend-1 mend-2 mend-3; do
  ck_has "4 cleans $e"                        "$ALL" "cleaned: $e"
  ck_eq  "4 feat/$e is gone"                  "$(has_br "feat/$e")" no
  ck_eq  "4 its copy is gone"                 "$(present "$(wt_of "$e")")" removed
done
ck_has "4 the ported branch goes by the proven route" \
  "$OUT" "dropped: feat/port (landed under other commit ids)"
ck_eq  "4 feat/port is gone"                  "$(has_br feat/port)" no
ck_eq  "4 the liege's branch is untouched"    "$(has_br liege/wip)" yes
ck_not "4 and not mentioned"                  "$OUT" "liege/wip"
ck_eq  "4 the branch no record names is untouched" "$(has_br stray)" yes
ck_has "4 the in-flight errand is kept, with why" "$OUT" "kept: busy feat/busy: still in flight"
ck_eq  "4 its branch stays"                   "$(has_br feat/busy)" yes
ck_eq  "4 its copy stays"                     "$(present "$(wt_of busy)")" present
ck_has "4 the dirty copy is kept, with why"   "$OUT" "kept: dirty feat/dirty: uncommitted work"
ck_eq  "4 its work is intact"                 "$(cat "$(wt_of dirty)/scratch.txt")" wip
ck_eq  "4 its branch stays"                   "$(has_br feat/dirty)" yes
ck_has "4 the last land's tally"              "$OUT" "2 cleaned, 2 dropped, 2 kept"

echo "--- 5. dry run and idempotence ---"
fresh_home five; holding five
errand x main
errand y feat/x
git -C "$repo" merge -q --ff-only feat/y      # landed by hand, as the liege might
before=$(snapshot); sweep five --dry-run
ck_eq  "5 a dry run exits 0"                  "$RC" 0
ck_has "5 says what it would clean"           "$OUT" "would clean: x"
ck_has "5 and what it would drop"             "$OUT" "would drop: feat/y"
ck_has "5 and that nothing changed"           "$OUT" "dry run, nothing changed"
ck_eq  "5 and wrote nothing"                  "$(snapshot)" "$before"
sweep five
ck_has "5 the sweep cleans both"              "$OUT" "2 cleaned, 2 dropped, 0 kept"
before=$(snapshot); sweep five
ck_eq  "5 a second sweep exits 0"             "$RC" 0
ck_has "5 finds nothing left"                 "$OUT" "0 cleaned, 0 dropped, 0 kept"
ck_eq  "5 and changes nothing"                "$(snapshot)" "$before"
sweep "$repo"
ck_has "5 a holding given by path sweeps too" "$OUT" "swept $repo"

echo "--- 6. a watch drops a branch already landed ---"
fresh_home six; holding six
OWNER=sess-S
git -C "$repo" branch dev main
errand s main
errand u main
errand t main
OWNER=''
git -C "$repo" merge -q --ff-only feat/s
git -C "$repo" fetch -q . feat/t:dev
OUT=''
for n in 1 2 3; do
  OUT="$OUT
$(REEVE_SESSION=sess-S "$ROOT/bin/reeve-sentry" --once --poll 1 2>&1)"
done
ck_has "6 the landed one: copy and branch go"  "$OUT" "landed branch feat/s dropped"
ck_eq  "6 feat/s is gone"                      "$(has_br feat/s)" no
ck_eq  "6 its copy is gone"                    "$(present "$(wt_of s)")" removed
ck_has "6 the unlanded one is kept as before"  "$OUT" "feat/u kept with 1 commit(s)"
ck_eq  "6 feat/u stays"                        "$(has_br feat/u)" yes
ck_has "6 one landed on dev goes too"         "$OUT" "landed branch feat/t dropped"
ck_eq  "6 feat/t is gone"                      "$(has_br feat/t)" no

echo "--- 7. what the sweep never takes ---"
fresh_home seven; holding seven
errand r main
git -C "$repo" worktree remove "$(wt_of r)"
git -C "$repo" branch -D feat/r >/dev/null     # deleted by hand
# The name reused, landed, at another sha: a reuse at the same sha in the same
# second has the same birth, the limit --prove-landed names.
echo s > "$repo/s"; git -C "$repo" add s; git -C "$repo" commit -qm trunk-s
git -C "$repo" branch feat/r main
errand m main
sed 's|^branch=.*|branch=main|' "$REEVE_HOME/state/m.meta" > "$REEVE_HOME/state/m.t" \
  && mv "$REEVE_HOME/state/m.t" "$REEVE_HOME/state/m.meta"
errand c main                                  # landed by patch, copy still on it
c_sha=$(tip feat/c)
# The trunk moves first: a pick onto the same parent in the same second is the
# very same commit, landed by ancestry.
echo t > "$repo/t"; git -C "$repo" add t; git -C "$repo" commit -qm trunk
git -C "$repo" cherry-pick "$c_sha" >/dev/null
sweep seven
ck_eq  "7 sweeps"                              "$RC" 0
ck_has "7 a reused name is kept as the liege's" \
  "$OUT" "kept: r feat/r: not provably the ref its dispatch made"
ck_eq  "7 and the reused branch stays"         "$(has_br feat/r)" yes
ck_not "7 a record naming main is not acted on" "$OUT" "m main"
ck_eq  "7 main stays"                          "$(has_br main)" yes
# No grant recorded, as on a fresh machine: the proven route is never taken.
ck_has "7 a ported branch is kept without the grant" \
  "$OUT" "kept: c feat/c: landed under other commit ids; the proven-delete grant is not recorded on this machine"
ck_eq  "7 its copy stays"                      "$(present "$(wt_of c)")" present
ck_eq  "7 its branch stays"                    "$(has_br feat/c)" yes
OUT=$("$ROOT/bin/reeve-teardown" c --drop-proven 2>&1); RC=$?
ck_eq  "7 --drop-proven refuses without the grant" "$RC" 1
ck_has "7 and says the grant is not recorded"  "$OUT" "it is not recorded on this machine"
ck_eq  "7 the copy still stays"                "$(present "$(wt_of c)")" present

echo "--- 8. a dev errand lands on dev ---"
fresh_home eight; holding eight
git -C "$repo" checkout -q -b dev
echo d > "$repo/d"; git -C "$repo" add d; git -C "$repo" commit -qm "dev-only unreleased"
main0=$(tip main)
errand e dev
want=$(tip feat/e)
land e
ck_eq  "8 lands"                               "$RC" 0
ck_has "8 onto dev, in the primary checkout"   "$OUT" "landed: feat/e onto dev"
ck_eq  "8 dev gains the work"                  "$(tip dev)" "$want"
ck_eq  "8 main is untouched"                   "$(tip main)" "$main0"
ck_has "8 the sweep measures against dev"      "$OUT" "cleaned: e"
ck_eq  "8 feat/e is gone"                      "$(has_br feat/e)" no
ck_eq  "8 its copy is gone"                    "$(present "$(wt_of e)")" removed
git -C "$repo" checkout -q main
errand f dev
want=$(tip feat/f)
land f
ck_eq  "8 lands with dev checked out nowhere"  "$RC" 0
ck_has "8 by the fetch form, onto dev"         "$OUT" "landed: feat/f onto dev"
ck_eq  "8 dev gains the work"                  "$(tip dev)" "$want"
ck_eq  "8 main is still untouched"             "$(tip main)" "$main0"
ck_eq  "8 feat/f is gone, though HEAD lacks it" "$(has_br feat/f)" no
ck_eq  "8 and no upstream is left behind"      "$(git -C "$repo" config branch.feat/f.merge || echo none)" none
errand g dev
errand h feat/g
before=$(snapshot); land h
ck_eq  "8 a mend on an unlanded dev errand refuses" "$RC" 1
ck_has "8 land that first"                     "$OUT" "based on errand branch feat/g, land that first"
ck_eq  "8 and changed nothing"                 "$(snapshot)" "$before"
land g
ck_has "8 its original lands on dev"           "$OUT" "landed: feat/g onto dev"
land h
ck_has "8 then the mend lands on dev, not main" "$OUT" "landed: feat/h onto dev"
ck_eq  "8 main is still untouched"             "$(tip main)" "$main0"
ck_has "8 and is cleaned, its errand base gone" "$OUT" "cleaned: h"
ck_eq  "8 feat/h is gone"                      "$(has_br feat/h)" no
errand j dev
errand l main
OUT=$("$ROOT/bin/reeve-teardown" l --drop-branch --onto feat/j 2>&1); RC=$?
ck_eq  "8 a teardown --onto an errand's branch refuses" "$RC" 1
ck_has "8 and says why"                        "$OUT" "is errand j's branch, not a place work lands"
ck_eq  "8 and its copy stays"                  "$(present "$(wt_of l)")" present

echo "--- 9. siblings, one rebased ---"
for withgrant in yes no; do
  fresh_home "nine-$withgrant"; holding "nine-$withgrant"
  [ "$withgrant" = yes ] && grant
  errand p main
  errand s1 feat/p
  errand s2 feat/p
  land p
  land s1
  ck_eq  "9 ($withgrant) s1 lands after p"     "$RC" 0
  land s2
  ck_has "9 ($withgrant) s2 no longer fast-forwards" "$OUT" "does not fast-forward main"
  errand s2r main
  git -C "$(wt_of s2r)" reset -q --hard main
  git -C "$(wt_of s2r)" cherry-pick "$(tip feat/s2)" >/dev/null
  land s2r
  ck_eq  "9 ($withgrant) s2r lands"            "$RC" 0
  if [ "$withgrant" = yes ]; then
    ck_has "9 the original is cleaned"         "$OUT" "cleaned: s2"
    ck_has "9 its branch dropped by the proof" "$OUT" "dropped: feat/s2 (landed under other commit ids)"
    ck_eq  "9 feat/s2 is gone"                 "$(has_br feat/s2)" no
    ck_eq  "9 its copy is gone"                "$(present "$(wt_of s2)")" removed
    ck_has "9 the record says it was dropped"  "$(meta_of s2 branchDropped)" 2026
  else
    ck_has "9 without the grant it is kept, with why" \
      "$OUT" "kept: s2 feat/s2: landed under other commit ids; the proven-delete grant is not recorded"
    ck_eq  "9 feat/s2 stays"                   "$(has_br feat/s2)" yes
    ck_eq  "9 its copy stays"                  "$(present "$(wt_of s2)")" present
  fi
done
# The proven route's dry run writes nothing, then the sweep drops it.
fresh_home nine-dry; holding nine-dry; grant
errand q main
q_sha=$(tip feat/q)
echo t > "$repo/t"; git -C "$repo" add t; git -C "$repo" commit -qm trunk
git -C "$repo" cherry-pick "$q_sha" >/dev/null
before=$(snapshot); sweep nine-dry --dry-run
ck_eq  "9 a dry run exits 0"                   "$RC" 0
ck_has "9 says it would drop the original"     "$OUT" "would drop: feat/q (landed under other commit ids)"
ck_eq  "9 and wrote nothing"                   "$(snapshot)" "$before"
sweep nine-dry
ck_has "9 then the sweep drops it"             "$OUT" "dropped: feat/q (landed under other commit ids)"
ck_eq  "9 its copy is gone"                    "$(present "$(wt_of q)")" removed
# A copy that is not on the tip the proof covers, and a second copy holding it.
fresh_home nine-off; holding nine-off; grant
errand k main
k_sha=$(tip feat/k)
echo t > "$repo/t"; git -C "$repo" add t; git -C "$repo" commit -qm trunk
git -C "$repo" cherry-pick "$k_sha" >/dev/null
git -C "$(wt_of k)" checkout -q --detach HEAD~1
sweep nine-off
ck_has "9 a copy off the tip is kept, with why" "$OUT" "not on the tip of feat/k"
ck_eq  "9 its copy stays"                      "$(present "$(wt_of k)")" present
ck_eq  "9 its branch stays"                    "$(has_br feat/k)" yes
git -C "$(wt_of k)" checkout -q feat/k
git -C "$repo" worktree add -q -f "$SCRATCH/another" feat/k
sweep nine-off
ck_has "9 a second copy holding it goes to the liege" "$OUT" "feat/k is checked out at"
ck_eq  "9 its copy stays"                      "$(present "$(wt_of k)")" present
ck_eq  "9 the other copy stays"                "$(present "$SCRATCH/another")" present
ck_eq  "9 its branch stays"                    "$(has_br feat/k)" yes
git -C "$repo" worktree remove "$SCRATCH/another"

echo "--- 10. another reeve's finish, not yet reported ---"
fresh_home ten; holding ten
OWNER=sess-A
errand x main
errand z main
OWNER=''
git -C "$repo" merge -q --ff-only feat/z
git -C "$repo" merge -q feat/x -m "x by hand" 2>/dev/null || git -C "$repo" merge -q --no-edit feat/x
printf 'woke=2026-10-14T11:00:00\n' >> "$REEVE_HOME/state/z.meta"
OUT=$(REEVE_SESSION=sess-B "$ROOT/bin/reeve-teardown" --sweep ten 2>&1)
ck_has "10 kept, with why"                     "$OUT" "kept: x feat/x: its finish not yet reported to its reeve"
ck_eq  "10 its branch stays"                   "$(has_br feat/x)" yes
ck_eq  "10 its copy stays"                     "$(present "$(wt_of x)")" present
ck_eq  "10 its record is not torn down"        "$(meta_of x tornDown)" ""
ck_has "10 one whose wake was left is cleaned"  "$OUT" "cleaned: z"
OUT=$(REEVE_SESSION=sess-A "$ROOT/bin/reeve-sentry" --once --poll 1 2>&1)
ck_has "10 its own reeve still hears of it"    "$OUT" "x"
ck_has "10 and reports it done"                "$OUT" "done"
OUT=$(REEVE_SESSION=sess-B "$ROOT/bin/reeve-teardown" --sweep ten 2>&1)
ck_not "10 once reported it is no longer kept for that" "$OUT" "not yet reported"

echo "--- 11. the upstream fallback leaves a checked-out branch alone ---"
fresh_home eleven; holding eleven
errand v main
git -C "$repo" checkout -q -b side
git -C "$repo" fetch -q . feat/v:main
git -C "$(wt_of v)" checkout -q --detach
git -C "$repo" worktree add -q "$SCRATCH/liege-v" feat/v
git -C "$repo" update-ref refs/remotes/origin/feat/v "$(tip feat/v)"
git -C "$repo" config branch.feat/v.remote origin
git -C "$repo" config branch.feat/v.merge refs/heads/feat/v
OUT=$("$ROOT/bin/reeve-teardown" v --drop-branch 2>&1)
ck_has "11 git refuses the delete"             "$OUT" "git refused to delete 'feat/v'"
ck_eq  "11 the branch stays"                   "$(has_br feat/v)" yes
ck_eq  "11 its upstream is untouched"          "$(git -C "$repo" config branch.feat/v.merge)" refs/heads/feat/v
ck_eq  "11 its remote is untouched"            "$(git -C "$repo" config branch.feat/v.remote)" origin
git -C "$repo" worktree remove "$SCRATCH/liege-v"
git -C "$repo" config --unset branch.feat/v.remote; git -C "$repo" config --unset branch.feat/v.merge
git -C "$repo" worktree add -q "$SCRATCH/liege-v" feat/v
OUT=$("$ROOT/bin/reeve-teardown" v --drop-branch 2>&1)
ck_eq  "11 no upstream is set on a branch checked out elsewhere" \
  "$(git -C "$repo" config branch.feat/v.merge || echo none)" none

echo "--- 12. a chain landed on dev, main behind ---"
fresh_home thirteen; holding thirteen
git -C "$repo" branch dev main
errand ldf main                                # base=main, as the live record
errand mend-ldf feat/ldf
git -C "$repo" fetch -q . feat/mend-ldf:dev    # the liege's fast-forward onto dev
main0=$(tip main)
for e in ldf mend-ldf; do
  OUT=$("$ROOT/bin/reeve-teardown" "$e" --drop-branch 2>&1); RC=$?
  ck_eq  "12 $e tears down"                    "$RC" 0
  ck_not "12 and is not refused over main"     "$OUT" "that main does not have"
  ck_eq  "12 feat/$e is gone"                  "$(has_br "feat/$e")" no
  ck_eq  "12 its copy is gone"                 "$(present "$(wt_of "$e")")" removed
done
ck_eq  "12 main is untouched"                  "$(tip main)" "$main0"
ck_eq  "12 no upstream is left behind"         "$(git -C "$repo" config --get-regexp '^branch\.feat/' || echo none)" none
# The same by the sweep, and what never counts as a landing place.
fresh_home thirteen-sweep; holding thirteen-sweep
git -C "$repo" branch dev main
git -C "$repo" branch liege/x main
errand a2 main
errand b2 feat/a2
git -C "$repo" fetch -q . feat/b2:dev
errand c2 main
git -C "$repo" fetch -q . feat/c2:liege/x       # only on the liege's own branch
errand d2 main
errand e2 feat/d2                              # its work only on another errand's branch
sweep thirteen-sweep
ck_has "12 the sweep cleans the dev chain's original" "$OUT" "cleaned: a2"
ck_has "12 and its mend"                       "$OUT" "cleaned: b2"
ck_eq  "12 feat/a2 is gone"                    "$(has_br feat/a2)" no
ck_eq  "12 feat/b2 is gone"                    "$(has_br feat/b2)" no
ck_not "12 a branch only on a liege branch is not taken" "$OUT" "c2"
ck_eq  "12 feat/c2 stays"                      "$(has_br feat/c2)" yes
ck_eq  "12 its copy stays"                     "$(present "$(wt_of c2)")" present
ck_not "12 nor one only on an errand's branch" "$OUT" "cleaned: d2"
ck_eq  "12 feat/d2 stays"                      "$(has_br feat/d2)" yes
OUT=$("$ROOT/bin/reeve-teardown" c2 2>&1); RC=$?
ck_eq  "12 teardown refuses work only on a liege branch" "$RC" 3
# A dev an errand record names as its branch= is an errand's, never a landing place.
printf 'office=artificer\nholding=thirteen-sweep\nrepo=%s\nbranch=dev\n' "$repo" \
  > "$REEVE_HOME/state/odd.meta"
errand f2 main
git -C "$repo" fetch -q . feat/f2:dev
OUT=$("$ROOT/bin/reeve-teardown" f2 2>&1); RC=$?
ck_eq  "12 a dev a record names is not asked" "$RC" 3
ck_eq  "12 and the copy stays"                 "$(present "$(wt_of f2)")" present

echo "--- 13. the doctor shows the grant ---"
fresh_home twelve
ck_has "13 not recorded"                       "$("$ROOT/bin/reeve-doctor" 2>&1)" "proven-delete not recorded"
grant
ck_has "13 recorded"                           "$("$ROOT/bin/reeve-doctor" 2>&1)" "proven-delete recorded"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
