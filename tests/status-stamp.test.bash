#!/usr/bin/env bash
# Status lines carry the UTC time they were written, as a leading
# `2026-10-04T15:36:02Z ` stamp. Two halves: the writers stamp (bin/reeve-say
# for a hand, bin/reeve-answer for the reeve), and every reader takes stamped,
# bare and mixed logs alike, since a log from before the stamp has none.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REEVE_HOME=$(mktemp -d)/reeve-home-test
export REEVE_ROOT="$ROOT"
rm -rf "$REEVE_HOME"; mkdir -p "$REEVE_HOME/errands/t" "$REEVE_HOME/state"
. "$ROOT/bin/reeve-lib.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }

SAY="$ROOT/bin/reeve-say"
F=$(status_file t)
STAMP='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z '
: > "$F"

echo "--- writer: reeve-say ---"
before=$(date -u +%Y-%m-%dT%H:%M:%SZ)
"$SAY" "$F" working 'reading the auth module' >/dev/null 2>&1
after=$(date -u +%Y-%m-%dT%H:%M:%SZ)
line=$(tail -n 1 "$F")
if printf '%s\n' "$line" | grep -Eq "${STAMP}working: reading the auth module\$"; then
  ok "working line is stamped, key unchanged after the stamp"
else bad "working line is stamped" "$line"; fi
s=${line%% *}
if [[ ! "$s" < "$before" ]] && [[ ! "$s" > "$after" ]]; then ok "stamp is the UTC clock at write"
else bad "stamp is the UTC clock at write" "$before <= $s <= $after"; fi

"$SAY" "$F" 'needs-decision [key=copy]' 'Save or Submit?' >/dev/null 2>&1
line=$(tail -n 1 "$F")
if printf '%s\n' "$line" | grep -Eq "${STAMP}needs-decision \[key=copy\]: Save or Submit\?\$"; then
  ok "needs-decision keeps its key after the stamp"
else bad "needs-decision keeps its key after the stamp" "$line"; fi

"$SAY" "$F" blocked 'two
lines' >/dev/null 2>&1
check "a newline in the note cannot forge a second line" "$(grep -c . "$F" | tr -d ' ')" 3
"$SAY" "$F" done 'branch feat/x: 2 commits at 10:30' >/dev/null 2>&1
check "a colon inside the note survives" "$(tail -n 1 "$F" | sed 's/^[^ ]* //')" \
  'done: branch feat/x: 2 commits at 10:30'

n=$(grep -c . "$F" | tr -d ' ')
for args in "resolved [key=copy]|ok" "needs-decision|q" "banana|x" "working|" "working|   " \
            "needs-decision [key=a b]|q" "needs-decision [key=]|q"; do
  h=${args%%|*}; note=${args#*|}
  if "$SAY" "$F" "$h" "$note" >/dev/null 2>&1; then bad "refuses '$h' '$note'"
  else ok "refuses '$h' '$note'"; fi
done
if "$SAY" "$F" working >/dev/null 2>&1; then bad "refuses a missing note"; else ok "refuses a missing note"; fi
if "$SAY" "$REEVE_HOME/errands/t/brief.md" working x >/dev/null 2>&1; then bad "refuses a file not named status"
else ok "refuses a file not named status"; fi
if "$SAY" "$REEVE_HOME/errands/nope/status" working x >/dev/null 2>&1; then bad "refuses a status file that does not exist"
else ok "refuses a status file that does not exist"; fi
[ ! -e "$REEVE_HOME/errands/nope" ] && ok "a refusal creates nothing" || bad "a refusal creates nothing"
check "a refusal appends nothing" "$(grep -c . "$F" | tr -d ' ')" "$n"

echo "--- writer: reeve-answer ---"
: > "$F"; printf 'repo=/nowhere\n' > "$(meta_file t)"
"$SAY" "$F" 'needs-decision [key=copy]' 'Save or Submit?' >/dev/null 2>&1
"$ROOT/bin/reeve-answer" t copy use Save >/dev/null 2>&1
line=$(tail -n 1 "$F")
if printf '%s\n' "$line" | grep -Eq "${STAMP}resolved \[key=copy\]: use Save\$"; then
  ok "reeve-answer stamps its resolved line"
else bad "reeve-answer stamps its resolved line" "$line"; fi
check "a stamped resolved closes a stamped decision" "$(status_field t open)" 0

echo "--- readers: stamped, bare, mixed ---"
r() { # r <name> <state> <open> <div> <last> <at>, log on stdin
  cat > "$F"
  local got
  got="$(status_field t state)/$(status_field t open)/$(status_field t divergence)/$(status_field t last)/$(status_field t at)"
  check "$1" "$got" "$2/$3/$4/$5/$6"
}
r "all stamped" done 0 no "branch feat/x, 1 commit" 2026-10-04T16:20:05Z <<'X'
2026-10-04T15:36:02Z working: started
2026-10-04T15:41:17Z needs-decision [key=copy]: Save or Submit?
2026-10-04T15:50:00Z resolved [key=copy]: use Save
2026-10-04T16:20:05Z done: branch feat/x, 1 commit
X
r "all bare, as before the stamp" done 0 no "shipped" "" <<'X'
working: started
needs-decision [key=copy]: Save or Submit?
resolved [key=copy]: use Save
done: shipped
X
r "old bare log, new stamped lines after" needs-decision 1 yes "shipped" 2026-10-04T16:20:05Z <<'X'
working: started
needs-decision [key=copy]: Save or Submit?
2026-10-04T15:36:02Z working: resumed
2026-10-04T16:20:05Z done: shipped
X
r "stamped decision, bare resolved" working 0 no "resumed" "" <<'X'
2026-10-04T15:41:17Z needs-decision [key=copy]: Save or Submit?
resolved [key=copy]: use Save
working: resumed
X
r "stamp then bare done: at is the bare line's, empty" done 0 no "shipped" "" <<'X'
2026-10-04T15:36:02Z working: started
done: shipped
X
r "stamped blocked" blocked 0 no "no .env" 2026-10-04T15:52:40Z <<'X'
2026-10-04T15:36:02Z working: started
2026-10-04T15:52:40Z blocked: no .env
X
r "stamped colon note" done 0 no "at 10:30: done" 2026-10-04T16:20:05Z <<'X'
2026-10-04T16:20:05Z done: at 10:30: done
X
r "not a stamp is not stripped" working 0 no "fine" "" <<'X'
working: fine
2026-10-04 banana: not a stamp
X
r "stamped unknown verb ignored" working 0 no "fine" 2026-10-04T15:36:02Z <<'X'
2026-10-04T15:36:02Z working: fine
2026-10-04T15:37:00Z banana: what even is this
X
cat > "$F" <<'X'
2026-10-04T15:41:17Z needs-decision [key=copy]: Save or Submit?
needs-decision [key=scope]: Also fix the typo?
X
check "open decisions list strips the stamp" "$(status_reconcile t | sed -n 's/^decision=//p' | tr '\t' '|')" \
"copy|Save or Submit?
scope|Also fix the typo?"

echo "--- readers: reeve-status ---"
cat > "$F" <<'X'
working: started
2026-10-04T15:36:02Z working: reading the auth module
X
out=$("$ROOT/bin/reeve-status" t --no-wake 2>&1)
printf '%s\n' "$out" | grep -q '^reported  working$' && ok "status reads a mixed log" \
  || bad "status reads a mixed log" "$out"
printf '%s\n' "$out" | grep -q '^last said reading the auth module$' && ok "last said carries no stamp" \
  || bad "last said carries no stamp" "$out"
printf '%s\n' "$out" | grep -q '^said at   2026-10-04T15:36:02Z$' && ok "said at shows the stamp" \
  || bad "said at shows the stamp" "$out"
printf 'working: started\n' > "$F"
out=$("$ROOT/bin/reeve-status" t --no-wake 2>&1)
printf '%s\n' "$out" | grep -q '^said at' && bad "a bare line shows no time" "$out" || ok "a bare line shows no time"

echo "--- brief tells the hand to use the helper ---"
if grep -q 'bin/reeve-say' "$ROOT/bin/reeve-brief" && grep -q 'Never type the time yourself' "$ROOT/bin/reeve-brief"; then
  ok "brief template names reeve-say"
else bad "brief template names reeve-say"; fi

rm -rf "$(dirname "$REEVE_HOME")"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
