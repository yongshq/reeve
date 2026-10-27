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
#      and window edges, and false while the owner's watch is not running; each
#      flag's since the first field of its latch, null while it is false
#   6. it writes nothing and calls no backend, whatever session it runs in
#   7. --home over REEVE_HOME over ~/.reeve; exit 1 and one stderr line only
#      for a home it cannot read, and nothing on stderr otherwise; a record it
#      cannot read left out, a status it cannot read unknown, as the help says
#   8. owner_reeve is the owning session's name now, so a hand still nests
#      under a renamed reeve; the recorded name only when the session has none
#   9. always valid UTF-8, whatever bytes a hand wrote
#  10. against the real sentry: a watch that wakes, exits and starts again over
#      the same silence, screen or dialog raises the flag with the same since;
#      a new one raises it with a new since
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

meta fix-auth office=mason reeve=Aldric session=s-ald backend=hall place=default \
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
GOLD='{"version":1,"reeves":[{"name":"Aldric","session":{"backend":"hall","name":"default","pane_id":"w1:p1"},"live":true},{"name":"Bran","session":{"backend":"herdr","name":null,"pane_id":"w4:p2"},"live":true},{"name":"Cedric","session":{"backend":"hall","name":"default","pane_id":"w2:p1"},"live":false}],"errands":[{"id":"fix-auth","office":"mason","owner_reeve":"Aldric","hand_state":"needs-decision","question":"Which base?","open":1,"waiting":false,"idle":false,"wedged":false,"since":{"waiting":null,"idle":null,"wedged":null},"session":{"backend":"hall","name":"default","pane_id":"w1:p3"}},{"id":"orphan","office":"scribe","owner_reeve":"Cedric","hand_state":"working","question":null,"open":0,"waiting":false,"idle":false,"wedged":false,"since":{"waiting":null,"idle":null,"wedged":null},"session":{"backend":"hall","name":"default","pane_id":"w2:p5"}},{"id":"scout-x","office":"scout","owner_reeve":"Bran","hand_state":"done","question":null,"open":0,"waiting":false,"idle":false,"wedged":false,"since":{"waiting":null,"idle":null,"wedged":null},"session":{"backend":"herdr","name":null,"pane_id":"w4:p7"}},{"id":"silent","office":"warden","owner_reeve":"Aldric","hand_state":"absent","question":null,"open":0,"waiting":false,"idle":false,"wedged":false,"since":{"waiting":null,"idle":null,"wedged":null},"session":{"backend":"herdr","name":null,"pane_id":null}}]}'
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
flags() { L | grep -o '"id":"w-1"[^}]*' | grep -o '"waiting":[a-z]*,"idle":[a-z]*,"wedged":[a-z]*,"since"' | sed 's/,"since"$//'; }
# since <id>   that errand's since object, its three values as `w i d`
since() { L | grep -o "\"id\":\"$1\"[^}]*}" | sed -n 's/.*"since":{"waiting":\([^,]*\),"idle":\([^,]*\),"wedged":\([^}]*\)}.*/\1 \2 \3/p'; }
lib() { bash -c '. "$1/bin/reeve-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }
meta w-1 office=mason reeve=Aldric session=s-ald backend=hall place=default 'target=w1|w1:p8|w1:t8' dispatched=x
log w-1 'working: one' 'working: two'
backdate "$H/errands/w-1/status" 20000
watch_on
eq  "5 no latch: nothing"                                   "$(flags)" '"waiting":false,"idle":false,"wedged":false'
eq  "5 every flag false: every since null"                  "$(since w-1)" 'null null null'

printf '%s no\n' "$((NOW - 89))" > "$H/state/.attn-w-1"
eq  "5 waiting, one second inside the dwell: not yet"       "$(flags)" '"waiting":false,"idle":false,"wedged":false'
eq  "5 a latch whose flag is false: since still null"       "$(since w-1)" 'null null null'
printf '%s no\n' "$((NOW - 90))" > "$H/state/.attn-w-1"
eq  "5 waiting at the dwell, the moment the sentry wakes"   "$(flags)" '"waiting":true,"idle":false,"wedged":false'
eq  "5 its since: the latch's first field"                  "$(since w-1)" "$((NOW - 90)) null null"
printf '%s yes 2\n' "$((NOW - 900))" > "$H/state/.attn-w-1"
eq  "5 and while the dialog stands after it woke"           "$(flags)" '"waiting":true,"idle":false,"wedged":false'
eq  "5 since the latch's start, not when it woke"           "$(since w-1)" "$((NOW - 900)) null null"
watch_off
eq  "5 no watch running: every flag false, the latch frozen" "$(flags)" '"waiting":false,"idle":false,"wedged":false'
eq  "5 and every since null"                                "$(since w-1)" 'null null null'
printf '%s 1 15\n' "$$" "$(( $(date +%s) - 600 ))" > "$H/state/.sentry.watch-s-ald"
eq  "5 a watch marker gone stale is no watch"               "$(flags)" '"waiting":false,"idle":false,"wedged":false'
watch_on
rm -f "$H/state/.attn-w-1"

mark=$(lib stale_mark w-1)
printf '%s %s no\n' "$((NOW - 89))" "$mark" > "$H/state/.stale-w-1"
eq  "5 idle, one second inside the dwell: not yet"          "$(flags)" '"waiting":false,"idle":false,"wedged":false'
printf '%s %s yes\n' "$((NOW - 90))" "$mark" > "$H/state/.stale-w-1"
eq  "5 idle at the dwell"                                   "$(flags)" '"waiting":false,"idle":true,"wedged":false'
eq  "5 its since: the idle latch's first field"             "$(since w-1)" "null $((NOW - 90)) null"
printf '%s\n' "$((NOW - 10))" > "$H/state/.steered-w-1"
eq  "5 a steer since the latch started voids it"            "$(flags)" '"waiting":false,"idle":false,"wedged":false'
eq  "5 and its since"                                       "$(since w-1)" 'null null null'
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
eq  "5 its since: the wedged latch's first field"           "$(since w-1)" "null null $((NOW - 100))"
printf '%s yes 1\n' "$((NOW - 300))" > "$H/state/.attn-w-1"
printf '%s %s yes\n' "$((NOW - 200))" "$mark" > "$H/state/.stale-w-1"
eq  "5 all three up: each its own latch's since"           "$(since w-1)" "$((NOW - 300)) $((NOW - 200)) $((NOW - 100))"
rm -f "$H/state/.attn-w-1" "$H/state/.stale-w-1"
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
eq  "5 nor any since"                                       "$(since w-1)" 'null null null'
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
  nas "7 the record itself left out"                        "$out" '"id":"fix-auth"'
  chmod 000 "$H/errands/fix-auth/status"
  out=$(L 2>"$SCRATCH/err"); rc=$?
  chmod 644 "$H/errands/fix-auth/status"
  has "7 a status it cannot read: that errand unknown"      "$rc:$out" '"id":"fix-auth","office":"mason","owner_reeve":"Aldric","hand_state":"unknown"'
fi
help=$(L --help | tr -s ' \n' '  ')
has "7 the help says a status it cannot read shows unknown" "$help" 'whose status cannot be read shows hand_state "unknown"'
has "7 and that a record it cannot read is left out"        "$help" 'a record that cannot be read is left out'
out=$(L --bogus 2>&1); rc=$?
eq  "7 an unknown argument is refused"                      "$rc" 2

echo "--- 8. owner_reeve: the owning session's name now ---"
# The liege's rename rewrites the session's name and no errand record, so the
# name the brief recorded goes stale while the reeve row shows the new one.
printf 'Bertram\n' > "$H/state/sessions/s-ald/name"
out=$(L)
has "8 renamed after dispatch: the hand's owner is the new name" "$out" '"id":"fix-auth","office":"mason","owner_reeve":"Bertram"'
has "8 and so is the reeve row it nests under"              "$out" '{"name":"Bertram","session":{"backend":"hall","name":"default","pane_id":"w1:p1"}'
nas "8 the old name nowhere"                                "$out" '"Aldric"'
printf 'Aldric\n' > "$H/state/sessions/s-ald/name"
meta lost office=scout reeve=Dunstan session=s-vanished 'target=w3|w3:p1' dispatched=x
has "8 an owning session that is gone: the recorded name"   "$(L)" '"id":"lost","office":"scout","owner_reeve":"Dunstan"'
session s-noname - $NOW
meta lost office=scout reeve=Dunstan session=s-noname 'target=w3|w3:p1' dispatched=x
has "8 one with no valid name: the recorded name"           "$(L)" '"id":"lost","office":"scout","owner_reeve":"Dunstan"'
meta lost office=scout session=s-vanished 'target=w3|w3:p1' dispatched=x
has "8 neither: null"                                       "$(L)" '"id":"lost","office":"scout","owner_reeve":null'
rm -f "$H/state/lost.meta"; rm -rf "$H/state/sessions/s-noname"

echo "--- 9. bytes that are not UTF-8 ---"
# One bad byte in any field would make the whole document unreadable to a
# strict parser, every second, until that errand is cleaned up.
log fix-auth 'working: reading' "$(printf 'needs-decision [key=q]: caf\303\251 x \303 y \377 \364\220\200\200 \370 \355\240\200 \300\200 z')"
out=$(L 2>"$SCRATCH/err"); rc=$?
eq  "9 still exit 0, quietly"                               "$rc:$(cat "$SCRATCH/err")" "0:"
if command -v python3 >/dev/null 2>&1; then
  q=$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.buffer.read().decode("utf-8")); print(len(d["errands"]), [e["question"] for e in d["errands"] if e["id"]=="fix-auth"][0])' 2>&1)
  has "9 the document is valid UTF-8 and JSON, every errand in it" "$q" '5 caf'
  has "9 the valid character kept"                          "$q" "$(printf 'caf\303\251 x')"
  nas "9 the bad bytes gone"                                "$q" "$(printf '\377')"
  NOICONV="$SCRATCH/noiconv"; mkdir -p "$NOICONV"
  printf '#!/bin/sh\nexit 127\n' > "$NOICONV/iconv"; chmod +x "$NOICONV/iconv"
  q=$(PATH="$NOICONV:$PATH" L | python3 -c 'import json,sys; d=json.loads(sys.stdin.buffer.read().decode("utf-8")); print([e["question"] for e in d["errands"] if e["id"]=="fix-auth"][0])' 2>&1)
  has "9 with no iconv: still JSON, each byte past ASCII a ?" "$q" 'caf?? x ? y'
else
  echo "skip  9 JSON parse: no python3"
fi
log fix-auth 'working: 2026-10-01T10:00:00Z reading' 'needs-decision [key=base]: 2026-10-01T10:05:00Z Which base?'

echo "--- 10. since across a watch that stops and starts again ---"
# The real sentry, over a stub backend, in a home of its own. A watch that wakes
# exits, so the listing drops every flag until a watch runs again, and the one
# started again over the same silence raises it again. A reader that rings once
# per since rings once only if that second rise carries the first one's since.
H3="$SCRATCH/watched"
mkdir -p "$H3/state/sessions/s-w" "$H3/errands/r-1" "$H3/config"
printf 'Wynn\n' > "$H3/state/sessions/s-w/name"; printf '%s\n' "$NOW" > "$H3/state/sessions/s-w/seen"
printf '%s\n' office=mason reeve=Wynn session=s-w backend=stub 'target=s|s:p1' dispatched=x > "$H3/state/r-1.meta"
export STUB_ATTN="$SCRATCH/stub-attn" STUB_PANE="$SCRATCH/stub-pane"
cat > "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()        { return 0; }
reeve_backend_stub_describe()         { echo stub; }
reeve_backend_stub_agent_state()      { echo alive; }
reeve_backend_stub_attention_state()  { cat "$STUB_ATTN"; }
reeve_backend_stub_capture()          { cat "$STUB_PANE"; }
reeve_backend_stub_wait_change()      { return 2; }
reeve_backend_stub_kill()             { :; }
reeve_backend_stub_send_text_submit() { :; }
STUB
ST3="$H3/errands/r-1/status"
# speak <line>   the hand says one more line, read by the watch as progress, and
# falls silent again long past every threshold
speak() {
  printf '%s\n' "$1" >> "$ST3"
  wc -l < "$ST3" | tr -d ' ' > "$H3/state/.cursor-r-1"
  backdate "$ST3" 20000
}
# watch <seconds past NOW>   one pass of the owner's watch at that time
watch() {
  OUT=$(REEVE_HOME="$H3" REEVE_SESSION=s-w REEVE_ATTN_NOW=$((NOW + $1)) \
        "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
}
# at <seconds past NOW>   the listing's since for r-1 at that time, with the
# owner's watch running, or with none as `at <s> off`
at() {
  if [ "${2:-}" = off ]; then rm -f "$H3/state/.sentry.watch-s-w"
  else printf '%s %s 15\n' "$$" "$(date +%s)" > "$H3/state/.sentry.watch-s-w"; fi
  REEVE_ATTN_NOW=$((NOW + $1)) "$ROOT/bin/reeve-listing" --home "$H3" \
    | sed -n 's/.*"since":{"waiting":\([^,]*\),"idle":\([^,]*\),"wedged":\([^}]*\)}.*/\1 \2 \3/p'
  rm -f "$H3/state/.sentry.watch-s-w"
}
: > "$ST3"; speak 'working: one'
printf 'frame one\n' > "$STUB_PANE"

# idle
printf 'settled\n' > "$STUB_ATTN"
watch 0;   eq "10 idle: the first look starts the latch, no wake"   "$RC" 4
watch 90;  has "10 idle: the watch wakes at the dwell"             "$OUT" 'idle: r-1'
eq  "10 idle: the watch gone, since null"                    "$(at 90 off)" 'null null null'
eq  "10 idle: since the latch's start"                       "$(at 90)" "null $NOW null"
watch 200; eq "10 idle: a watch started again does not wake again" "$RC" 4
eq  "10 idle: and since is the same over the same silence"   "$(at 200)" "null $NOW null"
speak 'working: two'
watch 300; watch 390; has "10 idle: a new silence wakes again"    "$OUT" 'idle: r-1'
eq  "10 idle: with a new since"                              "$(at 390)" "null $((NOW + 300)) null"

# wedged
printf 'working\n' > "$STUB_ATTN"; printf '100\n' > "$H3/config/hand-wedged"
watch 1000; eq "10 wedged: the first look starts the latch"        "$RC" 4
watch 1100; has "10 wedged: the watch wakes at the window"         "$OUT" 'wedged: r-1'
eq  "10 wedged: the watch gone, since null"                  "$(at 1100 off)" 'null null null'
eq  "10 wedged: since the latch's start"                     "$(at 1100)" "null null $((NOW + 1000))"
watch 1200; eq "10 wedged: a watch started again does not wake again" "$RC" 4
eq  "10 wedged: and since is the same over the same screen"  "$(at 1200)" "null null $((NOW + 1000))"
printf 'frame two\n' > "$STUB_PANE"
watch 1300; watch 1400; has "10 wedged: a screen that moved wakes again" "$OUT" 'wedged: r-1'
eq  "10 wedged: with a new since"                            "$(at 1400)" "null null $((NOW + 1300))"
rm -f "$H3/config/hand-wedged"

# waiting
printf 'waiting\n' > "$STUB_ATTN"
watch 2000; eq "10 waiting: the first look starts the latch"       "$RC" 4
watch 2090; has "10 waiting: the watch wakes at the dwell"         "$OUT" 'r-1 is waiting'
eq  "10 waiting: the watch gone, since null"                 "$(at 2090 off)" 'null null null'
eq  "10 waiting: since the latch's start"                    "$(at 2090)" "$((NOW + 2000)) null null"
watch 2200; eq "10 waiting: a watch started again does not wake again" "$RC" 4
eq  "10 waiting: and since is the same over the same dialog" "$(at 2200)" "$((NOW + 2000)) null null"
printf 'working\n' > "$STUB_ATTN"; watch 2300
printf 'waiting\n' > "$STUB_ATTN"; watch 2400; watch 2490
has "10 waiting: a new dialog wakes again"                   "$OUT" 'r-1 is waiting'
eq  "10 waiting: with a new since"                           "$(at 2490)" "$((NOW + 2400)) null null"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
