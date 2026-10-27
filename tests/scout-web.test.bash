#!/usr/bin/env bash
# Only the scout may search the web and fetch pages. The allow list is what
# keeps an unattended hand from stalling on a dialog, so it is pinned per office.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
OFFICES=${OFFICES:-$ROOT/offices}
# allows <office> <tool>: 0 allowed, 1 not allowed, 2 settings could not be read.
# A bare T or a scoped T(...) entry both grant T.
allows() {
  python3 -c '
import json, sys
try:
    allow = json.load(open(sys.argv[1]))["permissions"]["allow"]
except Exception:
    sys.exit(2)
t = sys.argv[2]
sys.exit(0 if any(e == t or e.startswith(t + "(") for e in allow) else 1)' \
    "$OFFICES/$1.settings.json" "$2"
}
expect() { # expect <office> <tool> <allow|deny>
  allows "$1" "$2"; local rc=$?
  if [ "$rc" -eq 2 ]; then bad "$1 settings unreadable ($2)"
  elif [ "$3" = allow ]; then [ "$rc" -eq 0 ] && ok "$1 allows $2" || bad "$1 allows $2"
  else [ "$rc" -eq 1 ] && ok "$1 does not allow $2" || bad "$1 must not allow $2"; fi
}
for t in WebSearch WebFetch; do
  expect scout "$t" allow
  for o in mason warden scribe steward; do expect "$o" "$t" deny; done
done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
