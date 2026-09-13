#!/usr/bin/env bash
# Every tool's --help must print its own usage and exit 0, without running
# anything. This is the regression guard for two bugs found in the shared
# template: a positional argument grabbed before -h/--help was checked, and a
# fixed `sed -n 'N,Mp'` line range over the header comment that drifted the
# moment that comment grew or shrank. One loop over bin/* so a seventeenth tool
# cannot quietly reintroduce either.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REEVE_HOME=$(mktemp -d)
export REEVE_ROOT="$ROOT"
PASS=0; FAIL=0

n=0
for f in "$ROOT"/bin/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  base=$(basename "$f")
  # reeve-lib.sh declares itself sourced, never executed; it is not a tool.
  [ "$base" = "reeve-lib.sh" ] && continue
  n=$((n + 1))
  for flag in --help -h; do
    out=$("$f" "$flag" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
      PASS=$((PASS + 1)); printf 'ok    %s %s\n' "$base" "$flag"
    else
      FAIL=$((FAIL + 1)); printf 'FAIL  %s %s (exit %s)\n      %s\n' "$base" "$flag" "$rc" \
        "$(printf '%s' "$out" | head -1)"
    fi
  done
done
printf 'checked %s tool(s) in bin/\n' "$n"

# A hand grabbing --help as a positional value (defect 1) does more than print
# the wrong thing: reeve-teardown mutates a worktree, so the regression this
# guards is not cosmetic.
touched=$(find "$REEVE_HOME" -mindepth 1 2>/dev/null)
if [ -z "$touched" ]; then
  PASS=$((PASS + 1)); printf 'ok    --help touched nothing under REEVE_HOME\n'
else
  FAIL=$((FAIL + 1)); printf 'FAIL  --help left files behind:\n%s\n' "$touched"
fi

rm -rf "$REEVE_HOME"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
