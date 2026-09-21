#!/usr/bin/env bash
# The four places two reeves sharing one home lose each other's work.
#
# bin/reeve-lib.sh has carried a correct mkdir-based advisory lock since the
# beginning and nothing called it: `grep -rn lock_acquire` returned the
# definition and no call sites at all. Every file below is read, edited and
# written back whole, which is atomic per write and still loses data across two
# writers, because both start from the same content and the second to land
# drops whatever the first added.
#
# These cases run the writers genuinely concurrently, which is the only way a
# lost update shows at all.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
[ -n "$real_home" ] || { printf 'FAIL  refusing to run: the real home could not be resolved\n'; exit 1; }
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
case $SCRATCH in "$real_home"|"$real_home"/*) printf 'FAIL  refusing: scratch is inside the real home\n'; exit 1 ;; esac
trap 'rm -rf "$SCRATCH"' EXIT

echo "--- 1. eight memory writers, eight facts ---"
export REEVE_HOME="$SCRATCH/home1"
"$ROOT/bin/reeve-memory" add "the fact that was already there" --scope liege --tier P >/dev/null 2>&1
for n in 1 2 3 4 5 6 7 8; do
  "$ROOT/bin/reeve-memory" add "concurrent fact number $n" --scope liege --tier P >/dev/null 2>&1 &
done
wait
eq "1 every concurrent fact survived"   "$(grep -c 'concurrent fact number' "$REEVE_HOME/liege.md")" 8
eq "1 and so did the one already there" "$(grep -c 'the fact that was already there' "$REEVE_HOME/liege.md")" 1

echo "--- 2. six reeves reaching for one errand id ---"
# An id is the only key an errand has and its namespace is the whole machine,
# so two reeves picking the same obvious id is not exotic. Both used to pass the
# existence check and both wrote the meta: second write wins, and the first
# errand's repo, branch and worktree vanish from the record with its hand still
# out there working.
export REEVE_HOME="$SCRATCH/home2"
REPO="$SCRATCH/repo"
mkdir -p "$REPO" && ( cd "$REPO" && git init -q . && git config user.email t@t && git config user.name t \
  && echo x > f && git add -A && git commit -qm init ) >/dev/null 2>&1
"$ROOT/bin/reeve-survey" --register r --manor m --path "$REPO" >/dev/null 2>&1
for n in 1 2 3 4 5 6; do
  "$ROOT/bin/reeve-brief" clash r --office scout >"$SCRATCH/brief.$n" 2>&1 &
done
wait
won=$(grep -l 'brief written' "$SCRATCH"/brief.* 2>/dev/null | wc -l | tr -d ' ')
lost=$(grep -l 'already' "$SCRATCH"/brief.* 2>/dev/null | wc -l | tr -d ' ')
eq "2 exactly one brief was written"            "$won" 1
eq "2 and the other five were refused, not lost" "$lost" 5
eq "2 one record exists, not six overwriting"    "$(ls "$REEVE_HOME/state"/*.meta 2>/dev/null | wc -l | tr -d ' ')" 1

echo "--- 3. the lock is advisory, and says who holds it ---"
export REEVE_HOME="$SCRATCH/home3"
mkdir -p "$REEVE_HOME/state"
probe() { bash -c '. "$0"/bin/reeve-lib.sh; d=$(lock_acquire "$1" "${2:-30}") && printf "%s" "$d"' "$ROOT" "$@"; }
held=$(probe probe-a)
eq "3 acquiring names a directory"    "$([ -d "$held" ] && echo yes || echo no)" yes
# A stale lock names the pid that holds it so a human can judge it, which is
# the whole reason it is never broken automatically.
pid=$(cat "$held/pid" 2>/dev/null)
case ${pid:-} in ''|*[!0-9]*) eq "3 and records a pid a human could judge" "${pid:-<empty>}" "<a number>" ;;
  *) ok "3 and records a pid a human could judge" ;;
esac
# A second attempt on a lock a LIVE process holds must not simply take it. The
# holder here is this suite itself, which is the one pid certain to be alive.
printf '%s\n' "$$" > "$held/pid"
out=$(probe probe-a 1 2>&1); rc=$?
eq "3 a live holder is waited for, then refused" "$rc" 1
rm -rf "$held"
eq "3 and releasing frees the name"   "$([ -d "$held" ] && echo yes || echo no)" no

echo "--- 4. locking a command must not break its siblings ---"
# Holding the lock was first written as a second `case $cmd` ahead of the real
# one. Every read-only command then matched its arm in the first case, ran, and
# fell into the second case that had no arm for it, exiting 1 on "unknown
# command" after printing a correct answer. `recall` and `glean` both call
# these, so the household reported a failure for work that had succeeded.
export REEVE_HOME="$SCRATCH/home4"
"$ROOT/bin/reeve-memory" add "a fact worth keeping" --scope liege --tier P >/dev/null 2>&1
for c in list stale budget; do
  out=$("$ROOT/bin/reeve-memory" $c 2>&1); rc=$?
  eq "4 '$c' exits clean" "$rc" 0
  case $out in *"unknown command"*) bad "4 '$c' did not fall through to an unknown-command death" "$out" ;;
    *) ok "4 '$c' did not fall through to an unknown-command death" ;;
  esac
done
out=$("$ROOT/bin/reeve-memory" list 2>&1)
has "4 and list still prints what it holds" "$out" "a fact worth keeping"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
