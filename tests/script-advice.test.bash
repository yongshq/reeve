#!/usr/bin/env bash
# Two defects, pinned.
#
# D1. Nothing in this household is on PATH: a clone is the whole install and
# every tool is run as `bin/reeve-x` from the repository root. Advice that
# prints a bare tool name tells the reader to run something that does not
# exist. Asserted as strings so a later edit that drops the prefix fails here
# rather than passing quietly. Scoped to the three files this errand owns.
#
# D2. `reeve-handoff new <manor>` returned 1 after succeeding, because
# `[ -n "$prev" ] && info ...` was the last command in the arm and a missing
# predecessor became the script's own exit status. Both cases are pinned: the
# status, and the supersedes line that must still appear in exactly one of them.
#
# D3. The other side of that status. Fixing D2 left the arm with nothing that
# could make it non-zero, so `new` exited 0 and printed a path after writing
# nothing at all. Both failing writes are pinned: the directory that cannot be
# created, and the directory that exists but cannot be written into.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/bin/reeve-handoff"
PASS=0; FAIL=0
ck() { # ck <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}
has() { # has <name> <file> <fixed-string>
  if grep -qF -- "$3" "$2"; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      missing from %s: %s\n' "$1" "$2" "$3"; fi
}

SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

echo "--- D1: advice names tools the way they are actually run ---"
has "reeve-answer --list advice is runnable" \
  "$ROOT/bin/reeve-answer" 'run: bin/reeve-answer $id --list'
has "reeve-answer relaunch advice is runnable" \
  "$ROOT/bin/reeve-answer" 'relaunch with: bin/reeve-dispatch $id'
has "reeve-handoff new usage is runnable" \
  "$ROOT/bin/reeve-handoff" 'which manor? bin/reeve-handoff new <manor>'
has "install.sh seeds manors.md with a runnable pointer" \
  "$ROOT/install.sh" 'Proposed by `bin/reeve-survey`'
has "reeve-survey seeds manors.md with the same runnable pointer" \
  "$ROOT/bin/reeve-survey" 'Proposed by `bin/reeve-survey`'

# Written into the `## In flight` block of every handoff document, so the reeve
# reads them there rather than on a terminal. Both phrasings, because the block
# takes one path when nothing is live and the other when something is.
has "handoff In flight advice is runnable, nothing live" \
  "$ROOT/bin/reeve-handoff" '`bin/reeve-status --all` is the live truth.'
has "handoff In flight advice is runnable, something live" \
  "$ROOT/bin/reeve-handoff" '`bin/reeve-status --all` is the live truth for'

# The help block of each is printed verbatim by print_help, so it is advice too.
for f in reeve-answer reeve-handoff; do
  bare=$("$ROOT/bin/$f" --help | grep -nE '(^|[^/[:alnum:]_.-])reeve-[a-z]+' || true)
  ck "$f --help names no tool without its bin/ prefix" "" "$bare"
done

echo "--- D2: new exits 0 whether or not a predecessor exists ---"
export REEVE_HOME="$SCRATCH/home"
out=$("$BIN" new reeve 2>&1); rc=$?
ck "first handoff exits 0" 0 "$rc"
first=$(printf '%s\n' "$out" | sed -n 's/.*handoff scaffolded: //p')
ck "first handoff was written" yes "$([ -f "$first" ] && echo yes || echo no)"
ck "first handoff prints no supersedes line" "" "$(printf '%s\n' "$out" | grep 'supersedes:' || true)"

# Both scaffolds would otherwise land on the same minute-resolution filename,
# which `new` refuses. Back-date the first one: the second is then a genuine
# successor without the test waiting out a clock minute.
prev="$(dirname "$first")/reeve-2000-01-01-0100.md"
mv "$first" "$prev"; first=$prev
out=$("$BIN" new reeve 2>&1); rc=$?
ck "second handoff exits 0" 0 "$rc"
ck "second handoff prints the supersedes line" "$(basename "$first")" \
  "$(printf '%s\n' "$out" | sed -n 's/.*supersedes: //p')"

echo "--- D3: new claims no scaffold it could not write ---"
# The other half of D2's exit status: 0 must mean the file is on disk. The reeve
# reads rc 0 plus a printed path as a handoff it can resume from, and an
# unwritable or full $REEVE_HOME is exactly when losing one costs most.
RO="$SCRATCH/readonly"; mkdir -p "$RO"; chmod 555 "$RO"
if touch "$RO/probe" 2>/dev/null; then
  rm -f "$RO/probe"
  printf 'skip  unwritable home: %s is writable anyway (running as root?)\n' "$RO"
else
  out=$(REEVE_HOME="$RO/home" "$BIN" new reeve 2>&1); rc=$?
  ck "unwritable home exits non-zero" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  ck "unwritable home claims no scaffold" "" \
    "$(printf '%s\n' "$out" | grep 'handoff scaffolded:' || true)"
fi
chmod 755 "$RO"

# The same claim, one layer in: the directory already exists, so `mkdir -p`
# succeeds and only the write can fail. This is the full-disk shape, and it
# pins the redirect guard on its own rather than behind the mkdir one.
WO="$SCRATCH/writeonly"; mkdir -p "$WO/handoffs"; chmod 555 "$WO/handoffs"
if touch "$WO/handoffs/probe" 2>/dev/null; then
  rm -f "$WO/handoffs/probe"
  printf 'skip  unwritable handoffs dir: %s is writable anyway (running as root?)\n' "$WO/handoffs"
else
  out=$(REEVE_HOME="$WO" "$BIN" new reeve 2>&1); rc=$?
  ck "unwritable handoffs dir exits non-zero" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  ck "unwritable handoffs dir claims no scaffold" "" \
    "$(printf '%s\n' "$out" | grep 'handoff scaffolded:' || true)"
fi
chmod 755 "$WO/handoffs"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
