#!/usr/bin/env bash
# Run every test. Colocated with the code they cover, as the repo convention.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
for t in "$ROOT"/tests/*.test.bash; do
  printf '\n=== %s ===\n' "$(basename "$t")"
  bash "$t" || fail=$((fail+1))
done
printf '\n=== shell syntax ===\n'
for f in "$ROOT"/bin/* "$ROOT"/backends/*.sh "$ROOT"/install.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then printf 'ok    %s\n' "$(basename "$f")"
  else printf 'FAIL  %s\n' "$(basename "$f")"; fail=$((fail+1)); fi
done
printf '\n=== adapter drift ===\n'
if out=$("$ROOT/bin/reeve-adapters" --check 2>&1) && [ -z "$out" ]; then
  printf 'ok    adapters match their method files\n'
else
  printf '%s\n' "$out"; fail=$((fail+1))
fi
printf '\n'
[ "$fail" -eq 0 ] && printf 'ALL GREEN\n' || printf '%s suite(s) failed\n' "$fail"
[ "$fail" -eq 0 ]
