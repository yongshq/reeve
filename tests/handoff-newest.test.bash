#!/usr/bin/env bash
# reeve-handoff newest/list must order by the timestamp carried in the
# filename (<manor>-YYYY-MM-DD-HHMM.md), never by mtime. Closing out a
# session writes a new handoff and then stamps the previous one superseded,
# and that stamp is exactly the mtime write that used to fool `ls -t`: the
# older file becomes the most recently modified one. This pins the fix by
# reproducing that sequence deliberately, and proves the same bug does not
# leak into `new`'s Supersedes field, which calls `newest` internally.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/bin/reeve-handoff"
PASS=0; FAIL=0
ck() { # ck <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}
ckrc() { # ckrc <name> <want-rc> <got-rc>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want rc: %s\n      got rc:  %s\n' "$1" "$2" "$3"; fi
}

SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/reeve-home-test"
mkdir -p "$REEVE_HOME/handoffs"

mkstub() { # mkstub <path>
  printf '# Handoff: stub\n\n- **Status:** open\n' > "$1"
}

echo "--- no handoffs yet ---"
"$BIN" newest reeve >/dev/null 2>&1
ckrc "newest fails with an empty handoffs dir" 1 "$?"

echo "--- mtime disagrees with filename order (the reproduction) ---"
OLD="$REEVE_HOME/handoffs/reeve-2026-01-01-0100.md"
NEW="$REEVE_HOME/handoffs/reeve-2026-01-01-0200.md"
mkstub "$OLD"
sleep 1
mkstub "$NEW"
# The routine close-out step: write the new handoff, then stamp the old one
# superseded. The stamp is a write, so it is also the mtime bug's trigger.
touch "$OLD"

got=$("$BIN" newest reeve)
ck "newest picks the later filename, not the later mtime" "$NEW" "$got"

echo "--- manor filter still applies ---"
OTHER="$REEVE_HOME/handoffs/otherm-2026-06-01-0900.md"
mkstub "$OTHER"
got=$("$BIN" newest reeve)
ck "newest ignores a lexically-later file from a different manor" "$NEW" "$got"
got=$("$BIN" newest otherm)
ck "newest still finds the other manor's own file" "$OTHER" "$got"

echo "--- list orders newest filename first ---"
first=$("$BIN" list reeve | head -1 | awk '{print $1}')
ck "list shows the later filename first" "$(basename "$NEW")" "$first"

echo "--- Supersedes names the right predecessor ---"
out=$("$BIN" new reeve)
scaffolded=$(printf '%s\n' "$out" | sed -n 's/.*handoff scaffolded: //p')
[ -n "$scaffolded" ] && [ -f "$scaffolded" ] || { FAIL=$((FAIL+1)); printf 'FAIL  new did not scaffold a file\n%s\n' "$out"; }
supersedes=$(grep -m1 '^- \*\*Supersedes:\*\*' "$scaffolded" | sed 's/.*Supersedes:\*\* //')
ck "new names the filename-newest handoff as predecessor, not the touched one" "$(basename "$NEW")" "$supersedes"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
