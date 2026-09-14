#!/usr/bin/env bash
# `## In flight` must carry the live errands only. The skill that owns the
# method says not to copy errand records into a handoff, because they are on
# disk and `reeve-status --all` rebuilds them, and the scaffold used to paste
# that whole table in anyway: 49 rows on the day this was written, every one of
# them finished and cleaned up months of sessions ago. This pins the narrowed
# block, both halves of the liveness test, and the fact that the way back to the
# full record survives in either case.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/bin/reeve-handoff"
PASS=0; FAIL=0
ck() { # ck <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}

SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/reeve-home-test"
mkdir -p "$REEVE_HOME/state"

# The section as written, from `## In flight` up to the next heading.
section() { # section <file>
  awk '/^## In flight/ { p = 1 } p && /^## Open with/ { exit } p' "$1"
}

scaffold() { # scaffold <manor>   prints the path of a fresh handoff
  local out
  # `new` returns non-zero when there is no predecessor to name, which is not
  # this test's subject: read the path it printed rather than its exit status.
  out=$("$BIN" new "$1" 2>/dev/null) || :
  printf '%s\n' "$out" | sed -n 's/.*handoff scaffolded: //p'
}

seed() { # seed <id> <office> <tornDown|-> [status line ...]
  local id=$1 office=$2 td=$3 l
  shift 3
  mkdir -p "$REEVE_HOME/errands/$id"
  {
    printf 'office=%s\nrepo=%s\nbase=main\n' "$office" "$SCRATCH/nonesuch"
    [ "$td" = - ] || printf 'tornDown=%s\n' "$td"
  } > "$REEVE_HOME/state/$id.meta"
  : > "$REEVE_HOME/errands/$id/status"
  for l in "$@"; do printf '%s\n' "$l" >> "$REEVE_HOME/errands/$id/status"; done
}

echo "--- nothing in flight ---"
f=$(scaffold empty)
[ -n "$f" ] && [ -f "$f" ] || { printf 'FAIL  new did not scaffold a file\n'; exit 1; }
sec=$(section "$f")
ck "the empty case says so in one line" 1 "$(printf '%s\n' "$sec" | grep -c 'Nothing still live')"
ck "the empty case opens no code fence" 0 "$(printf '%s\n' "$sec" | grep -c '^```')"
ck "the empty case keeps the way back to the record" 1 "$(printf '%s\n' "$sec" | grep -c 'reeve-status --all')"
ck "the heading survives" 1 "$(printf '%s\n' "$sec" | grep -c '^## In flight')"

echo "--- a mixed fleet ---"
seed done-torn      artificer 2026-09-14T01:00:00 'working: building' 'done: landed'
seed failed-torn    artificer 2026-09-14T02:00:00 'working: building' 'failed: gave up'
seed done-kept      artificer -                   'working: building' 'done: branch ready'
seed still-working  scout     -                   'working: still reading'
seed asking         artificer -                   'needs-decision [key=q1]: which one'
seed not-dispatched warden    -
# A different manor, because the filename carries only minutes: a second handoff
# for the same manor in the same minute is refused, by design.
f=$(scaffold mixed)
[ -n "$f" ] && [ -f "$f" ] || { printf 'FAIL  new did not scaffold a second file\n'; exit 1; }
sec=$(section "$f")

ck "the count is the live errands, not the fleet" 1 "$(printf '%s\n' "$sec" | grep -c '^4 errand(s) still live')"
for i in done-kept still-working asking not-dispatched; do
  ck "$i is listed" 1 "$(printf '%s\n' "$sec" | grep -c "^$i ")"
done
# Both halves of the test matter: terminal alone is not enough to drop a row,
# because a done artificer still holding a branch is the liege's next decision.
for i in done-torn failed-torn; do
  ck "$i is left out, it is finished and cleaned up" 0 "$(printf '%s\n' "$sec" | grep -c "^$i ")"
done
ck "the table header is kept" 1 "$(printf '%s\n' "$sec" | grep -c '^ERRAND  *OFFICE')"
ck "the rows are fenced" 2 "$(printf '%s\n' "$sec" | grep -c '^```')"
ck "the way back to the record survives here too" 1 "$(printf '%s\n' "$sec" | grep -c 'reeve-status --all')"
# 4 rows and a header inside the fence, against 6 rows and a header before this.
ck "nothing else leaked into the fence" 5 \
  "$(printf '%s\n' "$sec" | awk '/^```/ { f = !f; next } f' | grep -c .)"

echo "--- the other sections are untouched ---"
for seam in '{TITLE}' '{RESUME}' '{GOAL}' '{OPEN}' '{DECIDED}' '{NEXT}'; do
  ck "seam $seam survives" 1 "$(grep -cF "$seam" "$f")"
done

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
