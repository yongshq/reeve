#!/usr/bin/env bash
# Errand ids become branch names and directory names, so a bad one is not a
# cosmetic problem. These cases exist because a locale-dependent glob once let
# "Bad_ID" through.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/reeve-lib.sh"
PASS=0; FAIL=0
ck() { # ck <id> <accept|reject>
  if valid_id "$1"; then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf 'ok      %-22s %s\n' "[$1]" "$got"
  else FAIL=$((FAIL+1)); printf 'FAIL    %-22s got %s want %s\n' "[$1]" "$got" "$2"; fi
}
ck x accept
ck ab accept
ck a-b accept
ck find-cv-styles accept
ck a1 accept
ck Bad_ID reject
ck bad_id reject
ck BADID reject
ck 9lives reject
ck -lead reject
ck trail- reject
ck dou--ble reject
ck "has space" reject
ck "" reject
ck "dot.ted" reject
ck "slash/ed" reject
ck "$(printf 'a%.0s' $(seq 49))" reject
ck "$(printf 'a%.0s' $(seq 48))" accept
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
