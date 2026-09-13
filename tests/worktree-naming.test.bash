#!/usr/bin/env bash
# The worktree path is composed once, in reeve-brief, and then trusted: dispatch
# creates that directory and teardown removes it, both reading the recorded
# value back rather than recomposing it. So the name a brief records is the only
# place this can go wrong, and it is worth pinning.
#
# Two properties matter beyond the name itself. The path stays FLAT, because an
# <office>/<id> segment would quietly create a directory per role. And the
# steward keeps having no copy at all, because dispatch runs it in the reeve's
# home and a recorded path it never creates is a lie in the record.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
eq() { # eq <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}
nk() { # nk <name> <expect-ABSENT-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    FAIL=$((FAIL+1)); printf 'FAIL  %s\n      should NOT contain: %s\n' "$1" "$2"
  else PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; fi
}

# --- scratch everything ------------------------------------------------------
# This suite writes briefs and errand metadata. mktemp should already put it
# nowhere near the liege's own home, but it refuses rather than trusts: a run
# that landed in the real home would scribble over live errand records.
# -P: reeve-brief resolves the holding through `git rev-parse --show-toplevel`,
# which reports the real path. On macOS the temp directory is behind a symlink,
# so an unresolved path here would compare /var against /private/var and fail
# for a reason that has nothing to do with the naming.
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

# What it refuses on is a real reeve home, not the whole of $HOME. GNU mktemp
# honours TMPDIR, so a box with TMPDIR=$HOME/tmp, ordinary on Linux and in CI,
# hands back a scratch path under $HOME that is perfectly safe, and a guard
# spanning all of $HOME would fail the suite for nothing. Two homes can hold
# live records: the one an inherited REEVE_HOME names, and the default
# $HOME/.reeve, which a pre-exported REEVE_HOME does not make safe to scribble
# over. The trap above is already installed, so a refusal here leaves nothing
# behind.
refuse_if_inside() { # refuse_if_inside <home that may hold live records>
  local h=$1 p
  [ -n "$h" ] || return 0
  p=$(cd -P "$h" 2>/dev/null && pwd) && h=$p
  case $REEVE_HOME in
    "$h"|"$h"/*)
      printf 'FAIL  refusing to run: REEVE_HOME %s is inside the real reeve home %s\n' \
        "$REEVE_HOME" "$h"
      exit 1 ;;
  esac
}

# Fail closed: an unresolvable HOME means the default home cannot be ruled out,
# so refuse rather than compare against a path that is not the one at risk.
inherited=${REEVE_HOME:-}
home_p=$(cd -P "${HOME:-/nonexistent}" 2>/dev/null && pwd) \
  || { printf 'FAIL  refusing to run: HOME is unset or unreadable\n'; exit 1; }
REEVE_HOME="$SCRATCH/home"
refuse_if_inside "$inherited"
refuse_if_inside "$home_p/.reeve"
export REEVE_HOME
mkdir -p "$REEVE_HOME"

REPO="$SCRATCH/holding"
mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" -c user.email=reeve@example.invalid -c user.name=reeve \
    -c commit.gpgsign=false commit -q --allow-empty -m init

B="$ROOT/bin/reeve-brief"
PARENT="$SCRATCH/holding.worktrees"
recorded() { grep -m1 '^worktree=' "$REEVE_HOME/state/$1.meta" | sed 's/^worktree=//'; }

for office in artificer warden steward; do
  "$B" "e-$office" "$REPO" --office "$office" >/dev/null \
    || { printf 'FAIL  reeve-brief refused for office %s\n' "$office"; FAIL=$((FAIL+1)); }
done

# --- the name is the office, then the errand ---------------------------------
eq "artificer records artificer-<id>" "$PARENT/artificer-e-artificer" "$(recorded e-artificer)"
eq "warden records warden-<id>"       "$PARENT/warden-e-warden"       "$(recorded e-warden)"

# The brief a hand actually reads must name the same directory, not just the
# record the reeve keeps.
eq "the artificer's brief names its copy" \
   "$PARENT/artificer-e-artificer" \
   "$(sed -n 's/^| your copy | `\(.*\)` |$/\1/p' "$REEVE_HOME/errands/e-artificer/brief.md")"

# --- flat: exactly one directory below .worktrees ----------------------------
for id in e-artificer e-warden; do
  leaf=$(recorded "$id"); leaf=${leaf#*.worktrees/}
  case $leaf in
    */*) FAIL=$((FAIL+1)); printf 'FAIL  %s nests below .worktrees: %s\n' "$id" "$leaf" ;;
    '')  FAIL=$((FAIL+1)); printf 'FAIL  %s records nothing below .worktrees\n' "$id" ;;
    *)   PASS=$((PASS+1)); printf 'ok    %s is flat below .worktrees (%s)\n' "$id" "$leaf" ;;
  esac
done

# --- the steward stays the exception -----------------------------------------
eq "steward records no worktree path" "" "$(recorded e-steward)"
nk "steward's brief mentions no .worktrees directory" ".worktrees" \
   "$(cat "$REEVE_HOME/errands/e-steward/brief.md")"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
