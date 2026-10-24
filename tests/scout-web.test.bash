#!/usr/bin/env bash
# Only the scout may search the web and fetch pages. The allow list is what
# keeps an unattended hand from stalling on a dialog, so it is pinned per office.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
allows() { # allows <office> <tool>
  python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["permissions"]["allow"] else 1)' \
    "$ROOT/offices/$1.settings.json" "$2"
}
for t in WebSearch WebFetch; do
  allows scout "$t" && ok "scout allows $t" || bad "scout allows $t"
  for o in artificer warden scribe steward; do
    allows "$o" "$t" && bad "$o must not allow $t" || ok "$o does not allow $t"
  done
done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
