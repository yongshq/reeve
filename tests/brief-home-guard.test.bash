#!/usr/bin/env bash
# The check at the top of every brief, "Before you touch anything". A hand runs
# it once and believes the answer, so a check that cannot fail is worse than
# none: it reads like a guard and passes in the exact case it exists to catch.
#
# The steward's branch had that shape. Its whole check was `ls` on a directory
# that always exists, with no stated expectation and no response, while the
# repository branch beside it compares two printed paths and says what to do when
# they disagree. This suite holds both branches to the same three properties:
#
#   1. at least one command whose output is compared against a stated expectation
#   2. a reachable failing case, PROVEN here by running the brief's own commands
#      from a wrong directory
#   3. the same response: append `blocked: ...` to the status file, and stop
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else
           FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi; }
has()  { # has <name> <substring> <file>
  if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1" "missing: $2"; fi; }

# --- scratch everything ------------------------------------------------------
# Resolved, because the refusal below and the fixture repositories both need a
# path git and this suite agree on. The homes that must NOT be resolved are
# built on top of it further down: resolving here normalises nothing away, since
# the symlink and the trailing slash are added after this point.
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

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

B="$ROOT/bin/reeve-brief"
brief_of() { printf '%s/errands/%s/brief.md\n' "$REEVE_HOME" "$1"; }

# The steward is the branch under repair; the artificer is the branch it is
# being held to. Both are rendered from the same holding.
"$B" e-steward   "$REPO" --office steward   >/dev/null || { printf 'FAIL  brief refused\n'; exit 1; }
"$B" e-artificer "$REPO" --office artificer >/dev/null || { printf 'FAIL  brief refused\n'; exit 1; }

# The one command block under "Before you touch anything", verbatim. Extracting
# it rather than restating it is the point: what is exercised below is what the
# hand is actually told to run.
guard_cmds() { # guard_cmds <brief file>
  sed -n '/^## Before you touch anything$/,/^## /p' "$1" \
    | sed -n '/^```sh$/,/^```$/p' | sed '1d;$d'
}

# The expectation the hand is judged by, read OUT of the brief instead of
# restated here. Restating it is what let a brief that names the wrong path pass
# this suite while every steward on every machine would block on it: the oracle
# has to come from the artifact the hand actually reads.
expected_of() { # expected_of <brief file> -> the path the brief says pwd -P prints
  sed -n 's/^The first must print `\(.*\)`\. The second.*/\1/p' "$1"
}

for id in e-steward e-artificer; do
  cmds=$(guard_cmds "$(brief_of "$id")")
  [ -n "$cmds" ] && ok "$id states commands to run" || bad "$id states commands to run" 'no ```sh block'
  # A response with a failing case: the word blocked, appended to the status
  # file, and a stop. Both branches, same three.
  has "$id names the blocked line"  'blocked:'        "$(brief_of "$id")"
  has "$id points at the status file" "errands/$id/status" "$(brief_of "$id")"
  has "$id says to stop"            'stop at once'    "$(brief_of "$id")"
  has "$id says do nothing else"    'do nothing else' "$(brief_of "$id")"
done

# The check that cannot fail, named so it cannot come back: `ls` on a directory
# that was just created succeeds every time, whatever the hand's own location is.
if guard_cmds "$(brief_of e-steward)" | grep -q '^ls '; then
  bad "the steward's check is not a bare ls" 'ls on an existing directory always succeeds'
else
  ok "the steward's check is not a bare ls"
fi

# --- the failing case is reachable -------------------------------------------
# Run the brief's own commands from the right place and from a wrong one, and
# judge both by the expectation the brief states: `pwd -P` is the home, and the
# toplevel is either nothing or the home itself.
steward_verdict() { # steward_verdict <brief file> <dir> -> pass|fail, by the brief's own rule
  local out where top want
  want=$(expected_of "$1")
  [ -n "$want" ] || { printf 'fail\n'; return; }
  out=$( cd "$2" 2>/dev/null && eval "$(guard_cmds "$1")" 2>/dev/null ) || { printf 'fail\n'; return; }
  where=$(printf '%s\n' "$out" | sed -n 1p)
  top=$(printf '%s\n' "$out" | sed -n 2p)
  if [ "$where" = "$want" ] \
     && { [ "$top" = 'not a repository' ] || [ "$top" = "$want" ]; }
  then printf 'pass\n'; else printf 'fail\n'; fi
}

STEWARD=$(brief_of e-steward)
eq "the steward's check passes in the reeve's home" "pass" "$(steward_verdict "$STEWARD" "$REEVE_HOME")"
eq "it fails inside a holding"                      "fail" "$(steward_verdict "$STEWARD" "$REPO")"
eq "it fails in any other directory"                "fail" "$(steward_verdict "$STEWARD" "$SCRATCH")"

# A home the liege keeps under git is a legitimate steward home, not a holding,
# so the second line printing the home itself is allowed. Without that clause
# the check would block every steward on such a machine.
git init -q "$REEVE_HOME"
eq "a home under git is still the reeve's home" "pass" "$(steward_verdict "$STEWARD" "$REEVE_HOME")"
rm -rf "$REEVE_HOME/.git"

# The brief must state that expectation, or the hand has output and no rule to
# read it by, and the expectation must be a path `pwd -P` can print.
eq "the steward's brief states the expected path" "$REEVE_HOME" "$(expected_of "$STEWARD")"
has "the steward's brief allows a home under git"  'liege keeps the home under git' "$STEWARD"

# --- homes that are not written the way the filesystem spells them ------------
# $REEVE_HOME is whatever the liege typed. Through a symlink, with a trailing
# slash, or relative, the literal never equals what `pwd -P` prints, so an
# unresolved expectation refuses a healthy steward standing in the right place.
# Each case renders its own brief and is judged from the home the hand is
# launched into, which is the literal reeve-dispatch uses.
home_case() { # home_case <name> <REEVE_HOME as typed> <dir the hand starts in>
  local home=$2 launch=$3 id brief
  id="e-home-$1"
  brief="$home/errands/$id/brief.md"
  if ! REEVE_HOME=$home "$B" "$id" "$REPO" --office steward >/dev/null 2>&1; then
    bad "$1 home renders a brief" 'reeve-brief refused'; return
  fi
  eq "$1 home: the stated path is the one pwd -P prints" \
     "$(cd -P "$launch" && pwd)" "$(expected_of "$brief")"
  eq "$1 home: the steward standing in it passes" "pass" "$(steward_verdict "$brief" "$launch")"
  eq "$1 home: it still fails inside a holding"   "fail" "$(steward_verdict "$brief" "$REPO")"
}

mkdir -p "$SCRATCH/phys/symhome"
ln -s phys "$SCRATCH/via"
home_case symlink "$SCRATCH/via/symhome" "$SCRATCH/via/symhome"

mkdir -p "$SCRATCH/slashhome"
home_case trailing-slash "$SCRATCH/slashhome/" "$SCRATCH/slashhome"

# --- the repository branch is unchanged --------------------------------------
# The same three properties, on the branch that already had them, so a later
# edit cannot quietly hollow out one and leave the other.
eq "the artificer is still told to print two paths" \
   "pwd -P
git rev-parse --show-toplevel" "$(guard_cmds "$(brief_of e-artificer)")"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
