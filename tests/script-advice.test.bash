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
trap 'rm -rf "$SCRATCH"' EXIT

echo "--- D1: advice names tools the way they are actually run ---"
has "reeve-answer --list advice is runnable" \
  "$ROOT/bin/reeve-answer" 'run: bin/reeve-answer $id --list'
has "reeve-answer relaunch advice is runnable" \
  "$ROOT/bin/reeve-answer" 'relaunch with: bin/reeve-dispatch $id'
has "reeve-handoff new usage is runnable" \
  "$ROOT/bin/reeve-handoff" 'which manor? bin/reeve-handoff new <manor>'
has "install.sh seeds manors.md with a runnable pointer" \
  "$ROOT/install.sh" 'Proposed by `bin/reeve-survey`'

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

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
