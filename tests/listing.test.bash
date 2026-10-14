#!/usr/bin/env bash
# bin/reeve-listing: every reeve and errand in flight, as JSON, for a reader
# that polls it once a second.
#
# Pinned here:
#   1. the exact document, version 1, for a known home: the golden case
#   2. it is JSON: a question holding quotes, a backslash, a tab and control
#      characters comes out escaped
#   3. which errands: torn down out, never dispatched out, done but not yet
#      cleaned up in; a record with no backend reads herdr, with no place null
#   4. which reeves: live ones, and gone ones only while they own an errand in
#      flight; one row per name, a live one first; a session another took over
#      from is not live
#   5. waiting, idle and wedged from the sentry's own latches, at its own dwell
#      and window edges, and false while the owner's watch is not running
#   6. it writes nothing and calls no backend, whatever session it runs in
#   7. --home over REEVE_HOME over ~/.reeve; exit 1 and one stderr line only
#      for a home it cannot read, and nothing on stderr otherwise
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "did not mention [$3] in: $2" ;; esac; }
nas() { case $2 in *"$3"*) bad "$1" "should not have mentioned [$3]" ;; *) ok "$1" ;; esac; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
case $SCRATCH in "$real_home"|"$real_home"/*) printf 'FAIL  refusing: scratch is inside the real home\n'; exit 1 ;; esac
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
unset CLAUDE_CODE_SESSION_ID REEVE_SESSION REEVE_NAME REEVE_HAND REEVE_BACKEND REEVE_ROOT REEVE_NOW \
      REEVE_ATTN_NOW REEVE_ATTN_DWELL \
      HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID \
      HALL_ENV HALL_PANE_ID HALL_SOCKET_PATH HALL_TAB_ID HALL_WORKSPACE_ID HALL_BIN_PATH \
      HALL_SESSION HALL_CLIENT_SOCKET_PATH REEVE_HALL_BIN REEVE_HALL_SOCKET REEVE_HALL_SESSION
H="$SCRATCH/home"
export REEVE_HOME="$H"
mkdir -p "$H/state/sessions" "$H/errands" "$H/config"

# Nothing may be asked of a backend: a code root whose backends record any
# call, and a herdr and a hall first on PATH that do the same.
CALLS="$SCRATCH/called"; export CALLS
export REEVE_ROOT="$SCRATCH/root"
mkdir -p "$REEVE_ROOT/backends"
ln -s "$ROOT/bin" "$REEVE_ROOT/bin"
for b in herdr hall; do
  printf 'echo "%s backend sourced" >> "$CALLS"\n' "$b" > "$REEVE_ROOT/backends/$b.sh"
done
FAKE="$SCRATCH/fakebin"; mkdir -p "$FAKE"
for b in herdr hall; do printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\nexit 1\n' "$b" > "$FAKE/$b"; chmod +x "$FAKE/$b"; done
export PATH="$FAKE:$PATH"

L() { "$ROOT/bin/reeve-listing" "$@"; }

# One clock for every process: the reeves' heartbeats and the latches' dwell.
NOW=1800000000
export REEVE_NOW=$NOW REEVE_ATTN_NOW=$NOW REEVE_ATTN_DWELL=90

# backdate <file> <seconds before NOW>   its mtime, on the test's clock
backdate() {
  local ts=$(( NOW - $2 )) stamp
  stamp=$(date -r "$ts" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$ts" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$1"
}

# --- the home -----------------------------------------------------------------
# session <sid> <name|-> <seen> [<pane>] [<place>]
session() {
  local d="$H/state/sessions/$1"; mkdir -p "$d"
  [ "$2" != - ] && printf '%s\n' "$2" > "$d/name"
  printf '%s\n' "$3" > "$d/seen"
  [ -n "${4:-}" ] && printf '%s\n' "$4" > "$d/pane"
  [ -n "${5:-}" ] && printf '%s\n' "$5" > "$d/place"
  return 0
}
# meta <id> <lines...>   the record, one key=value per argument
meta() { local id=$1; shift; printf '%s\n' "$@" > "$H/state/$id.meta"; }
# log <id> <lines...>    the status file
log() { local id=$1; shift; mkdir -p "$H/errands/$id"; printf '%s\n' "$@" > "$H/errands/$id/status"; }

session s-ald Aldric $NOW 'w1:p1@/run/hall.sock' 'hall default'
session s-bran Bran $NOW 'w4:p2@/run/herdr.sock'
session s-gone Cedric $((NOW - 5000)) 'w2:p1@/run/hall.sock' 'hall default'
session s-idle Osric $((NOW - 5000))
session s-anon - $NOW

meta fix-auth office=artificer reeve=Aldric session=s-ald backend=hall place=default \
  'target=w1|w1:p3|w1:t2#c123l456' dispatched=2026-10-01T10:00:00
log fix-auth 'working: 2026-10-01T10:00:00Z reading' 'needs-decision [key=base]: 2026-10-01T10:05:00Z Which base?'
meta scout-x office=scout session=s-bran 'target=w4|w4:p7' dispatched=2026-10-01T10:00:00
log scout-x 'working: on it' 'done: 2026-10-01T11:00:00Z report written'
meta orphan office=scribe session=s-gone backend=hall place=default 'target=w2|w2:p5|w2:t3' \
  dispatched=2026-10-01T10:00:00
log orphan 'working: drafting'
meta old office=scout session=s-bran 'target=w4|w4:p1' dispatched=2026-09-01T10:00:00 tornDown=2026-09-02T10:00:00
log old 'done: finished'
meta briefed office=scout session=s-bran
meta silent office=warden session=s-ald dispatched=2026-10-01T10:00:00

echo "--- 1. the golden document ---"
out=$(L 2>"$SCRATCH/err"); rc=$?
eq  "1 exit 0"                                              "$rc" 0
eq  "1 nothing on stderr"                                   "$(cat "$SCRATCH/err")" ''
GOLD='{"version":1,"reeves":[{"name":"Aldric","session":{"backend":"hall","name":"default","pane_id":"w1:p1"},"live":true},{"name":"Bran","session":{"backend":"herdr","name":null,"pane_id":"w4:p2"},"live":true},{"name":"Cedric","session":{"backend":"hall","name":"default","pane_id":"w2:p1"},"live":false}],"errands":[{"id":"fix-auth","office":"artificer","owner_reeve":"Aldric","hand_state":"needs-decision","question":"Which base?","open":1,"waiting":false,"idle":false,"wedged":false,"session":{"backend":"hall","name":"default","pane_id":"w1:p3"}},{"id":"orphan","office":"scribe","owner_reeve":"Cedric","hand_state":"working","question":null,"open":0,"waiting":false,"idle":false,"wedged":false,"session":{"backend":"hall","name":"default","pane_id":"w2:p5"}},{"id":"scout-x","office":"scout","owner_reeve":"Bran","hand_state":"done","question":null,"open":0,"waiting":false,"idle":false,"wedged":false,"session":{"backend":"herdr","name":null,"pane_id":"w4:p7"}},{"id":"silent","office":"warden","owner_reeve":"Aldric","hand_state":"absent","question":null,"open":0,"waiting":false,"idle":false,"wedged":false,"session":{"backend":"herdr","name":null,"pane_id":null}}]}'
eq  "1 exactly the document"                                "$out" "$GOLD"
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; rc=$?
  eq  "1 which parses as JSON"                              "$rc" 0
else
  echo "skip  1 JSON parse: no python3"
fi

echo "--- 2. escaping ---"
log fix-auth 'working: reading' "$(printf 'needs-decision [key=q]: Say "yes" or \\no\\?\there%s%s%s' $'\001' $'\033' $'\037')"
out=$(L)
has "2 quotes, backslash, tab and control characters escaped" "$out" '"question":"Say \"yes\" or \\no\\?\there\u0001\u001b\u001f"'
if command -v python3 >/dev/null 2>&1; then
  q=$(printf '%s' "$out" | python3 -c 'import json,sys; print(repr([e["question"] for e in json.load(sys.stdin)["errands"] if e["id"]=="fix-auth"][0]))')
  eq  "2 and reads back as the question asked"              "$q" "'Say \"yes\" or \\\\no\\\\?\\there\\x01\\x1b\\x1f'"
fi
log fix-auth 'working: reading' 'needs-decision [key=a]: first?' 'needs-decision [key=b]: second?'
out=$(L)
has "2 the newest open question, with the count"            "$out" '"question":"second?","open":2'
log fix-auth 'working: reading' 'needs-decision [key=a]: first?' 'needs-decision [key=b]: second?' 'resolved [key=b]: ok'
has "2 one answered gives the one still open"               "$(L)" '"question":"first?","open":1'
log fix-auth 'working: 2026-10-01T10:00:00Z reading' 'needs-decision [key=base]: 2026-10-01T10:05:00Z Which base?'

echo "--- 3. which errands ---"
out=$(L)
nas "3 a torn down errand is out"                           "$out" '"id":"old"'
nas "3 one never dispatched is out"                         "$out" '"id":"briefed"'
has "3 one done but not cleaned up is in"                   "$out" '"id":"scout-x","office":"scout","owner_reeve":"Bran","hand_state":"done"'
has "3 one dispatched with no target yet is in, no pane"    "$out" '"id":"silent"'
has "3 no backend reads herdr, no place is null"            "$out" '"session":{"backend":"herdr","name":null,"pane_id":"w4:p7"}'
meta dup office=scout session=s-bran 'target=w4|w4:p8' dispatched=x tornDown= office=other
has "3 a key's first line wins, an empty tornDown is not one" "$(L)" '"id":"dup","office":"scout"'
rm -f "$H/state/dup.meta"

echo "--- 4. which reeves ---"
out=$(L)
has "4 a live reeve"                                        "$out" '{"name":"Aldric","session":{"backend":"hall","name":"default","pane_id":"w1:p1"},"live":true}'
has "4 a gone one that owns an errand in flight"            "$out" '"name":"Cedric"'
nas "4 not a gone one that owns nothing"                    "$out" '"name":"Osric"'
nas "4 nor a session with no name"                          "$out" 's-anon'
session s-ald2 Aldric $((NOW - 10)) 'w9:p9@/run/hall.sock' 'hall dev'
has "4 one row per name: the newest live one"               "$(L)" '{"name":"Aldric","session":{"backend":"hall","name":"default","pane_id":"w1:p1"},"live":true}'
eq  "4 and only one"                                        "$(L | grep -o '"name":"Aldric"' | wc -l | tr -d ' ')" 1
printf '%s\n' "$((NOW - 9000))" > "$H/state/sessions/s-ald/seen"
has "4 a live one over a gone one, whatever is newer"       "$(L)" '{"name":"Aldric","session":{"backend":"hall","name":"dev","pane_id":"w9:p9"},"live":true}'
printf '%s\n' "$NOW" > "$H/state/sessions/s-ald/seen"
rm -rf "$H/state/sessions/s-ald2"
printf 'hand\n' > "$H/state/sessions/s-bran/successor"
session hand - $NOW
backdate "$H/state/sessions/s-bran/successor" 0
has "4 a session another took over from is not live"        "$(L)" '"pane_id":"w4:p2"},"live":false'
rm -f "$H/state/sessions/s-bran/successor"
printf '900\n' > "$H/config/session-stale"
printf '%s\n' "$((NOW - 1000))" > "$H/state/sessions/s-bran/seen"
has "4 session-stale from config"                           "$(L)" '"pane_id":"w4:p2"},"live":false'
printf '2000\n' > "$H/config/session-stale"
has "4 every word of it"                                    "$(L)" '"pane_id":"w4:p2"},"live":true'
rm -f "$H/config/session-stale"; printf '%s\n' "$NOW" > "$H/state/sessions/s-bran/seen"

echo "--- 5. waiting, idle and wedged ---"
# The owner's watch: a live marker, this process, refreshed now on the real
# clock, which is the one marker_alive reads.
watch_on()  { printf '%s %s 15\n' "$$" "$(date +%s)" > "$H/state/.sentry.watch-s-ald"; }
watch_off() { rm -f "$H/state/.sentry.watch-s-ald"; }
flags() { L | grep -o '"id":"w-1"[^}]*' | grep -o '"waiting":[a-z]*,"idle":[a-z]*,"wedged":[a-z]*'; }
lib() { bash -c '. "$1/bin/reeve-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }
meta w-1 office=artificer reeve=Aldric session=s-ald backend=hall place=default 'target=w1|w1:p8|w1:t8' dispatched=x
log w-1 'working: one' 'working: two'
backdate "$H/errands/w-1/status" 20000
watch_on
eq  "5 no latch: nothing"                                   "$(flags)" '"waiting":false,"idle":false,"wedged":false'

printf '%s no\n' "$((NOW - 89))" > "$H/state/.attn-w-1"
eq  "5 waiting, one second inside the dwell: not yet"       "$(flags)" '"waiting":false,"idle":false,"wedged":false'
printf '%s no\n' "$((NOW - 90))" > "$H/state/.attn-w-1"
eq  "5 waiting at the dwell, the moment the sentry wakes"   "$(flags)" '"waiting":true,"idle":false,"wedged":false'
printf '%s yes 2\n' "$((NOW - 900))" > "$H/state/.attn-w-1"
eq  "5 and while the dialog stands after it woke"           "$(flags)" '"waiting":true,"idle":false,"wedged":false'
watch_off
eq  "5 no watch running: every flag false, the latch frozen" "$(flags)" '"waiting":false,"idle":false,"wedged":false'
printf '%s 1 15\n' "$$" "$(( $(date +%s) - 600 ))" > "$H/state/.sentry.watch-s-ald"
eq  "5 a watch marker gone stale is no watch"               "$(flags)" '"waiting":false,"idle":false,"wedged":false'
watch_on
rm -f "$H/state/.attn-w-1"

mark=$(lib stale_mark w-1)
printf '%s %s no\n' "$((NOW - 89))" "$mark" > "$H/state/.stale-w-1"
eq  "5 idle, one second inside the dwell: not yet"          "$(flags)" '"waiting":false,"idle":false,"wedged":false'
printf '%s %s yes\n' "$((NOW - 90))" "$mark" > "$H/state/.stale-w-1"
eq  "5 idle at the dwell"                                   "$(flags)" '"waiting":false,"idle":true,"wedged":false'
printf '%s\n' "$((NOW - 10))" > "$H/state/.steered-w-1"
eq  "5 a steer since the latch started voids it"            "$(flags)" '"waiting":false,"idle":false,"wedged":false'
rm -f "$H/state/.steered-w-1"
printf 'working: three\n' >> "$H/errands/w-1/status"; backdate "$H/errands/w-1/status" 20000
eq  "5 a line since voids it too: a new silence"            "$(flags)" '"waiting":false,"idle":false,"wedged":false'
rm -f "$H/state/.stale-w-1"

printf '100\n' > "$H/config/hand-wedged"
mark=$(lib stale_mark w-1)
printf '%s %s 123-45 no\n' "$((NOW - 99))" "$mark" > "$H/state/.wedged-w-1"
eq  "5 wedged, one second inside the window: not yet"       "$(flags)" '"waiting":false,"idle":false,"wedged":false'
printf '%s %s 123-45 yes\n' "$((NOW - 100))" "$mark" > "$H/state/.wedged-w-1"
eq  "5 wedged at the window"                                "$(flags)" '"waiting":false,"idle":false,"wedged":true'
backdate "$H/errands/w-1/status" 99
eq  "5 not while the status file spoke inside the window"   "$(flags)" '"waiting":false,"idle":false,"wedged":false'
backdate "$H/errands/w-1/status" 20000
printf '0\n' > "$H/config/hand-wedged"
eq  "5 not with the check turned off"                       "$(flags)" '"waiting":false,"idle":false,"wedged":false'
printf '100\n' > "$H/config/hand-wedged"
printf '%s %s 123-45 yes\n' "$((NOW - 100))" "$mark" > "$H/state/.attn-w-1"
printf '%s %s yes\n' "$((NOW - 100))" "$mark" > "$H/state/.stale-w-1"
log w-1 'working: one' 'needs-decision [key=x]: asked'
eq  "5 a hand that is not working has no flag at all"       "$(flags)" '"waiting":false,"idle":false,"wedged":false'
rm -f "$H/state/.attn-w-1" "$H/state/.stale-w-1" "$H/state/.wedged-w-1" "$H/config/hand-wedged"
log w-1 'working: one'

echo "--- 6. it writes nothing and calls no backend ---"
# Every path and every file's contents, before and after, and nothing newer
# than a mark set after every mtime in the home was put in the past.
snap() { (cd "$H" && find . | sort; find . -type f -exec cksum {} + | sort); }
# A wake waiting in the spool of the session it runs as, which reeve-status
# would deliver, and a heartbeat old enough that any touch would show.
REEVE_SESSION=s-ald lib wake_leave s-ald 'signal: w-1 is done - x' w-1 1
printf '%s\n' "$((NOW - 100))" > "$H/state/sessions/s-ald/seen"
find "$H" -exec touch -h -t 202001010000 {} +
touch -t 202001010001 "$SCRATCH/mark"
before=$(snap); : > "$CALLS"
L >/dev/null 2>&1
L --home "$H" >/dev/null 2>&1
eq  "6 the home is byte for byte the same"                  "$(snap)" "$before"
CLAUDE_CODE_SESSION_ID=s-ald L >/dev/null 2>&1
REEVE_SESSION=s-ald L >/dev/null 2>&1
REEVE_SESSION=s-ald CLAUDE_CODE_SESSION_ID=s-ald HALL_ENV=1 HALL_PANE_ID=w5:p5 HALL_SOCKET_PATH=/s \
  HERDR_PANE_ID=w5:p5 HERDR_SOCKET_PATH=/s L >/dev/null 2>&1
eq  "6 and so as a session: no heartbeat, pane or wake taken" "$(snap)" "$before"
eq  "6 nothing in it written at all"                        "$(find "$H" -newer "$SCRATCH/mark")" ''
has "6 the wake is still waiting"                           "$(ls "$H/state/sessions/s-ald/wake")" "."
eq  "6 no backend sourced, no herdr or hall run"            "$(cat "$CALLS")" ''
printf '%s\n' "$NOW" > "$H/state/sessions/s-ald/seen"

echo "--- 7. which home, and when it cannot be read ---"
H2="$SCRATCH/other"; mkdir -p "$H2/state"
eq  "7 --home over REEVE_HOME"                              "$(L --home "$H2")" '{"version":1,"reeves":[],"errands":[]}'
eq  "7 --home= the same"                                    "$(L --home="$H2")" '{"version":1,"reeves":[],"errands":[]}'
eq  "7 REEVE_HOME when no --home"                           "$(REEVE_HOME="$H2" L)" '{"version":1,"reeves":[],"errands":[]}'
eq  "7 ~/.reeve when neither"                               "$(env -u REEVE_HOME HOME="$SCRATCH/fakehome" bash -c 'mkdir -p "$HOME/.reeve"; "$1/bin/reeve-listing"' _ "$ROOT")" '{"version":1,"reeves":[],"errands":[]}'
mkdir -p "$SCRATCH/fresh"
eq  "7 a home with no state yet is empty, not an error"     "$(L --home "$SCRATCH/fresh" 2>&1; echo "rc=$?")" '{"version":1,"reeves":[],"errands":[]}
rc=0'
out=$(L --home "$SCRATCH/nowhere" 2>"$SCRATCH/err"); rc=$?
eq  "7 a home that is not there: exit 1"                    "$rc" 1
eq  "7 nothing on stdout"                                   "$out" ''
eq  "7 one line on stderr"                                  "$(wc -l < "$SCRATCH/err" | tr -d ' ')" 1
has "7 naming it"                                           "$(cat "$SCRATCH/err")" "cannot read the home at $SCRATCH/nowhere"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$H2/state"
  out=$(L --home "$H2" 2>"$SCRATCH/err"); rc=$?
  chmod 755 "$H2/state"
  eq  "7 a state folder it cannot read: exit 1, one line"   "$rc:$(wc -l < "$SCRATCH/err" | tr -d ' ')" "1:1"
  chmod 000 "$H/state/fix-auth.meta"
  out=$(L 2>"$SCRATCH/err"); rc=$?
  chmod 644 "$H/state/fix-auth.meta"
  eq  "7 one record it cannot read: still exit 0, quietly"  "$rc:$(cat "$SCRATCH/err")" "0:"
  has "7 and the rest still listed"                         "$out" '"id":"orphan"'
fi
out=$(L --bogus 2>&1); rc=$?
eq  "7 an unknown argument is refused"                      "$rc" 2

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
