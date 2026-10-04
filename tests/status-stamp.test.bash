#!/usr/bin/env bash
# Status lines carry the UTC time they were written, as a stamp right after the
# state's colon: `done: 2026-10-04T15:36:02Z <note>`. Three halves: the writers
# stamp (bin/reeve-say for a hand, bin/reeve-answer for the reeve), every reader
# takes stamped, bare, interim (leading stamp) and mixed logs alike, and a
# reader from before the stamp, main's own lib, still reads a stamped log right.
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
STAMP='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z '
: > "$F"

echo "--- writer: reeve-say ---"
before=$(date -u +%Y-%m-%dT%H:%M:%SZ)
"$SAY" "$F" working 'reading the auth module' >/dev/null 2>&1
after=$(date -u +%Y-%m-%dT%H:%M:%SZ)
line=$(tail -n 1 "$F")
if printf '%s\n' "$line" | grep -Eq "^working: ${STAMP}reading the auth module\$"; then
  ok "working line is stamped after the state's colon"
else bad "working line is stamped after the state's colon" "$line"; fi
s=${line#* }; s=${s%% *}
if [[ ! "$s" < "$before" ]] && [[ ! "$s" > "$after" ]]; then ok "stamp is the UTC clock at write"
else bad "stamp is the UTC clock at write" "$before <= $s <= $after"; fi

"$SAY" "$F" 'needs-decision [key=copy]' 'Save or Submit?' >/dev/null 2>&1
line=$(tail -n 1 "$F")
if printf '%s\n' "$line" | grep -Eq "^needs-decision \[key=copy\]: ${STAMP}Save or Submit\?\$"; then
  ok "needs-decision keeps its key before the stamp"
else bad "needs-decision keeps its key before the stamp" "$line"; fi

"$SAY" "$F" blocked 'two
lines' >/dev/null 2>&1
check "a newline in the note cannot forge a second line" "$(grep -c . "$F" | tr -d ' ')" 3
"$SAY" "$F" done 'branch feat/x: 2 commits at 10:30' >/dev/null 2>&1
check "a colon inside the note survives" "$(tail -n 1 "$F" | sed -E "s/${STAMP}//")" \
  'done: branch feat/x: 2 commits at 10:30'

n=$(grep -c . "$F" | tr -d ' ')
for args in "resolved [key=copy]|ok" "needs-decision|q" "banana|x" "working|" "working|   " \
            "needs-decision [key=a b]|q" "needs-decision [key=]|q"; do
  h=${args%%|*}; note=${args#*|}
  if "$SAY" "$F" "$h" "$note" >/dev/null 2>&1; then bad "refuses '$h' '$note'"
  else ok "refuses '$h' '$note'"; fi
done
if "$SAY" "$F" working >/dev/null 2>&1; then bad "refuses a missing note"; else ok "refuses a missing note"; fi
if "$SAY" "$F" working 'a note' -e >/dev/null 2>&1; then bad "refuses a fourth argument"
else ok "refuses a fourth argument"; fi
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
if printf '%s\n' "$line" | grep -Eq "^resolved \[key=copy\]: ${STAMP}use Save\$"; then
  ok "reeve-answer stamps its resolved line"
else bad "reeve-answer stamps its resolved line" "$line"; fi
check "a stamped resolved closes a stamped decision" "$(status_field t open)" 0

echo "--- readers: stamped, bare, interim, mixed ---"
r() { # r <name> <state> <open> <div> <last> <at>, log on stdin
  cat > "$F"
  local got
  got="$(status_field t state)/$(status_field t open)/$(status_field t divergence)/$(status_field t last)/$(status_field t at)"
  check "$1" "$got" "$2/$3/$4/$5/$6"
}
r "all stamped" done 0 no "branch feat/x, 1 commit" 2026-10-04T16:20:05Z <<'X'
working: 2026-10-04T15:36:02Z started
needs-decision [key=copy]: 2026-10-04T15:41:17Z Save or Submit?
resolved [key=copy]: 2026-10-04T15:50:00Z use Save
done: 2026-10-04T16:20:05Z branch feat/x, 1 commit
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
working: 2026-10-04T15:36:02Z resumed
done: 2026-10-04T16:20:05Z shipped
X
r "stamped decision, bare resolved" working 0 no "resumed" "" <<'X'
needs-decision [key=copy]: 2026-10-04T15:41:17Z Save or Submit?
resolved [key=copy]: use Save
working: resumed
X
r "stamp then bare done: at is the bare line's, empty" done 0 no "shipped" "" <<'X'
working: 2026-10-04T15:36:02Z started
done: shipped
X
r "stamped blocked" blocked 0 no "no .env" 2026-10-04T15:52:40Z <<'X'
working: 2026-10-04T15:36:02Z started
blocked: 2026-10-04T15:52:40Z no .env
X
r "stamped colon note" done 0 no "at 10:30: done" 2026-10-04T16:20:05Z <<'X'
done: 2026-10-04T16:20:05Z at 10:30: done
X
r "not a stamp is not stripped" working 0 no "fine" "" <<'X'
working: fine
2026-10-04 banana: not a stamp
X
r "stamped unknown verb ignored" working 0 no "fine" 2026-10-04T15:36:02Z <<'X'
working: 2026-10-04T15:36:02Z fine
banana: 2026-10-04T15:37:00Z what even is this
X
cat > "$F" <<'X'
needs-decision [key=copy]: 2026-10-04T15:41:17Z Save or Submit?
needs-decision [key=scope]: Also fix the typo?
X
check "open decisions list strips the stamp" "$(status_reconcile t | sed -n 's/^decision=//p' | tr '\t' '|')" \
"copy|Save or Submit?
scope|Also fix the typo?"

r "interim leading stamp, as logs on disk carry it" done 0 no "shipped" 2026-10-04T16:20:05Z <<'X'
2026-10-04T15:36:02Z working: started
2026-10-04T15:41:17Z needs-decision [key=copy]: Save or Submit?
2026-10-04T15:50:00Z resolved [key=copy]: use Save
2026-10-04T16:20:05Z done: shipped
X
r "interim ask, stamped resolved and done" done 0 no "shipped" 2026-10-04T16:20:05Z <<'X'
2026-10-04T15:41:17Z needs-decision [key=copy]: Save or Submit?
resolved [key=copy]: 2026-10-04T15:50:00Z use Save
done: 2026-10-04T16:20:05Z shipped
X
r "a half stamp in a note is kept" done 0 no "2026-10-04 shipped" "" <<'X'
done: 2026-10-04 shipped
X

echo "--- old readers: main's lib reads a stamped log ---"
# A watch, caretaker or second reeve still running main's code reads the same
# home. Its parser is taken from main itself, so this asserts against the code
# that is actually out there, not a copy of it kept here. A fresh clone of a
# branch has main only as origin/main.
OLDLIB="$(dirname "$REEVE_HOME")/old-lib.sh"
: > "$OLDLIB"
for ref in main origin/main; do
  git -C "$ROOT" show "$ref:bin/reeve-lib.sh" > "$OLDLIB" 2>/dev/null && [ -s "$OLDLIB" ] && break
done
if [ -s "$OLDLIB" ]; then
  old() { # old <name> <state> <open> <div>, of the log in $F
    local got
    got=$(bash -c '. "$1"; s=$(status_reconcile t); printf "%s/%s/%s" \
            "$(printf "%s\n" "$s" | sed -n "s/^state=//p")" \
            "$(printf "%s\n" "$s" | sed -n "s/^open=//p")" \
            "$(printf "%s\n" "$s" | sed -n "s/^divergence=//p")"' _ "$OLDLIB" 2>/dev/null)
    check "old reader: $1" "$got" "$2/$3/$4"
  }
  : > "$F"
  "$SAY" "$F" working 'started' >/dev/null 2>&1
  "$SAY" "$F" done 'built' >/dev/null 2>&1
  old "stamped done is done" done 0 no
  : > "$F"
  "$SAY" "$F" working 'started' >/dev/null 2>&1
  "$SAY" "$F" 'needs-decision [key=k]' 'which?' >/dev/null 2>&1
  old "stamped keyed ask stays open" needs-decision 1 no
  "$ROOT/bin/reeve-answer" t k yes >/dev/null 2>&1
  "$SAY" "$F" done 'built' >/dev/null 2>&1
  old "stamped resolved closes it, done with no divergence" done 0 no
  : > "$F"
  printf 'needs-decision [key=k]: which?\n' >> "$F"
  "$ROOT/bin/reeve-answer" t k yes >/dev/null 2>&1
  "$SAY" "$F" done 'built' >/dev/null 2>&1
  old "bare ask, stamped resolved: no phantom open decision" done 0 no
  : > "$F"
  "$SAY" "$F" 'needs-decision [key=k]' 'which?' >/dev/null 2>&1
  "$SAY" "$F" done 'built' >/dev/null 2>&1
  old "stamped done over an open ask is a divergence" needs-decision 1 yes
else
  bad "old reader: main's bin/reeve-lib.sh could be read from git"
fi

echo "--- sentry: a signal line carries the note, not the stamp ---"
# Stubbed code root and a scout, as tests/sentry-ownership.test.bash builds
# them, so nothing is ever opened and the teardown has nothing to refuse.
STUB="$(dirname "$REEVE_HOME")/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_launch()          { return 0; }
reeve_backend_stub_agent_state()     { printf 'alive\n'; }
reeve_backend_stub_attention_state() { printf 'settled\n'; }
reeve_backend_stub_wait_change()     { return 2; }
reeve_backend_stub_kill()            { return 0; }
ADAPTER
signal() { # signal <name> <want>, stamped lines written with reeve-say first
  local out
  out=$(REEVE_ROOT="$STUB" REEVE_SESSION=sess-stamp "$ROOT/bin/reeve-sentry" --once --poll 1 2>&1)
  # what a teardown did is said after the note, in brackets: not the note's
  check "$1" "$(printf '%s\n' "$out" | grep '^signal: ' | head -n 1 | sed 's/ \[session .*\]$//')" "$2"
}
sentry_errand() { # sentry_errand <id>
  mkdir -p "$REEVE_HOME/errands/$1"
  printf 'target=stub:1\nbackend=stub\noffice=scout\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=no\ndispatched=2026-09-28T20:25:26\nsession=sess-stamp\n' \
    > "$(meta_file "$1")"
  : > "$(status_file "$1")"
}
rm -f "$(meta_file t)"
sentry_errand sd
"$SAY" "$(status_file sd)" working 'started' >/dev/null 2>&1
"$SAY" "$(status_file sd)" done 'built it' >/dev/null 2>&1
signal "done signal shows the note only" "signal: sd is done - built it"
rm -f "$(meta_file sd)"
sentry_errand sq
"$SAY" "$(status_file sq)" 'needs-decision [key=k]' 'which one?' >/dev/null 2>&1
signal "decision signal shows the question only" "signal: sq needs a decision (1 open) - which one?"
rm -f "$(meta_file sq)"
sentry_errand sb
printf '2026-10-04T15:52:40Z blocked: no .env\n' >> "$(status_file sb)"
signal "an interim stamped line signals without its stamp" "signal: sb is blocked - no .env"
rm -f "$(meta_file sb)"
printf 'repo=/nowhere\n' > "$(meta_file t)"

echo "--- readers: reeve-status ---"
cat > "$F" <<'X'
working: started
working: 2026-10-04T15:36:02Z reading the auth module
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
