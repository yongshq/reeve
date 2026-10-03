#!/usr/bin/env bash
# A hand whose turn died and whose process did not. Three hands ended their turns
# on `API Error: Can't reach the API server (ENOTFOUND)` when the network dropped,
# stayed alive and idle at their prompts with `working:` as their last line, and
# for twenty two hours every tool here reported them as proceeding: the status
# listing said `working` and `alive/settled`, the sentry found nothing to say.
#
# Covered here, against a stub backend so no terminal is involved:
#   1. the sentry wakes for a silence past the threshold, and the listing shows it
#   2. the same silence inside the threshold is quiet
#   3. done, failed and an open decision are never stale, however old
#   4. a session that is working is never stale, however old its last line
#   5. the threshold comes from config, and a bad value fails closed
#   6. one silence is one wake, and a new silence after speaking is a second
#   7. the dead turn marker shortens the wait, and only on real evidence
#   8. it reports and never acts
#   9. a steer re-arms it: working again, then idle again without a line, wakes
#  10. a bad hand-stale leaves the error wait working, and says so on the watch
#  11. a momentary settled reading mid turn is not a wake: the dwell
#  12. a gone session, an idle one and an undeliverable notification open with
#      three different words
#  13. a session that cannot say whether it is idle is said to be unjudgeable
#  14. the listing and the sentry agree at the dwell boundary, whichever looks first
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]: $2" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output should not have said [$3]: $2" ;; *) ok "$1" ;; esac; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-stale-test.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

# Ownership off: the errand below records no session, and a watch that names one
# would still see it, but the spool it drains should be this home's, not ours.
unset CLAUDE_CODE_SESSION_ID
export REEVE_SESSION=''
export REEVE_ROOT="$SCRATCH/root"
export REEVE_HOME="$SCRATCH/home"
mkdir -p "$REEVE_ROOT/backends" "$REEVE_HOME/state" "$REEVE_HOME/config" "$REEVE_HOME/errands/hung"

export STUB_ATTN="$SCRATCH/attn" STUB_PANE="$SCRATCH/pane" STUB_ACTS="$SCRATCH/acts" STUB_LIVE="$SCRATCH/live"
cat > "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()        { return 0; }
reeve_backend_stub_describe()         { echo stub; }
reeve_backend_stub_agent_state()      { cat "$STUB_LIVE" 2>/dev/null || echo alive; }
reeve_backend_stub_attention_state()  { cat "$STUB_ATTN"; }
reeve_backend_stub_capture()          { cat "$STUB_PANE" 2>/dev/null; }
reeve_backend_stub_wait_change()      { return 2; }
reeve_backend_stub_kill()             { echo "kill $*" >> "$STUB_ACTS"; }
reeve_backend_stub_send_text_submit() { echo "send $*" >> "$STUB_ACTS"; }
reeve_backend_stub_launch()           { echo "launch $*" >> "$STUB_ACTS"; }
STUB

META="$REEVE_HOME/state/hung.meta"
STATUS="$REEVE_HOME/errands/hung/status"
printf 'target=s|s:p1\nbackend=stub\noffice=artificer\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=yes\ndispatched=2026-10-01T21:30:00\n' > "$META"

# One frozen clock for every process, so a backdated mtime is exactly as old as
# the case says and never a second older.
NOW=$(date +%s)
export REEVE_NOW=$NOW
# No dwell, so one watch is one sample, except in case 11 which is about it.
export REEVE_ATTN_DWELL=0

# backdate <seconds ago>   set the status file's mtime, BSD date first, then GNU
backdate() {
  local ts=$(( NOW - $1 )) stamp
  stamp=$(date -r "$ts" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$ts" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$STATUS"
}
# say <lines...>   rewrite the log, cursor at its end, so only the probe speaks
say() {
  printf '%s\n' "$@" > "$STATUS"
  printf '%s\n' "$#" > "$REEVE_HOME/state/.cursor-hung"
  rm -f "$REEVE_HOME/state/.stale-hung"
}
sentry() { OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?; }
# The PROCESS cell by position, since an idle cell holds a space of its own.
row()    { "$ROOT/bin/reeve-status" --all --no-wake 2>/dev/null | grep '^hung ' | cut -c55-70 | sed 's/ *$//'; }
single() { "$ROOT/bin/reeve-status" hung 2>/dev/null | sed -n 's/^process  *//p'; }

printf 'settled\n' > "$STUB_ATTN"
: > "$STUB_PANE"

# --- 1. past the threshold -------------------------------------------------
say 'working: rewriting the parser'
backdate 7300
sentry
ck_eq  "1 a silent idle working hand wakes the sentry"   "$RC" 0
ck_has "1 it names the errand and the silence"            "$OUT" "idle: hung has been silent for 2h 1m"
ck_has "1 it says the session is idle"                    "$OUT" "with its session idle at its prompt"
ck_has "1 and quotes what it last said"                   "$OUT" "last said rewriting the parser"
ck_eq  "1 one line, like every other reason"              "$(printf '%s\n' "$OUT" | grep -c .)" 1
ck_eq  "1 the listing shows it in PROCESS"                "$(row)" "alive/idle 2h"
ck_eq  "1 and the single form says how long"              "$(single)" "alive/settled, idle: silent 2h 1m"

# --- 2. inside the threshold -----------------------------------------------
say 'working: rewriting the parser'
backdate 7100
sentry
ck_eq  "2 inside the threshold the sentry is quiet"       "$RC" 4
ck_not "2 and says nothing of staleness"                  "$OUT" "stale"
ck_not "2 nor of idleness"                                "$OUT" "idle"
ck_eq  "2 the listing reads settled"                      "$(row)" "alive/settled"

# --- 3. explained silences -------------------------------------------------
# Old enough to be stale ten times over. Each of these says why the hand is
# quiet, and only `working` does not.
for c in 'done: parser rewritten' 'failed: cannot build' \
         'needs-decision [key=api]: keep the old api?' 'blocked: no .env present'; do
  say 'working: rewriting the parser' "$c"
  backdate 86400
  sentry
  ck_not "3 never idle: ${c%%:*}"                          "$OUT" "idle:"
  ck_not "3 nor in the listing: ${c%%:*}"                  "$(row)" "idle"
done

# --- 4. a long turn --------------------------------------------------------
say 'working: rewriting the parser'
backdate 86400
for a in working waiting unknown; do
  printf '%s\n' "$a" > "$STUB_ATTN"
  rm -f "$REEVE_HOME/state/.attn-hung"
  sentry
  ck_not "4 a session reading $a is never stale"          "$OUT" "idle:"
  ck_not "4 nor in the listing when $a"                    "$(row)" "idle"
done
printf 'settled\n' > "$STUB_ATTN"

# --- 5. the threshold is config --------------------------------------------
say 'working: rewriting the parser'
backdate 120
printf '60\n' > "$REEVE_HOME/config/hand-stale"
sentry
ck_eq  "5 a configured threshold is honoured"             "$RC" 0
ck_has "5 with the silence it measured"                   "$OUT" "silent for 2m"
for v in abc 0 -5 ''; do
  say 'working: rewriting the parser'
  backdate 864000
  printf '%s\n' "$v" > "$REEVE_HOME/config/hand-stale"
  sentry
  ck_eq "5 hand-stale [$v] fails closed, never fires"     "$RC" 4
  ck_eq "5 and the listing does not call it idle [$v]"    "$(row)" "alive/settled"
done
printf 'abc\n' > "$REEVE_HOME/config/hand-stale"
ck_has "5 the listing says the check is off"              "$("$ROOT/bin/reeve-status" --all --no-wake 2>&1 >/dev/null)" \
  "config/hand-stale is not a whole number"
rm -f "$REEVE_HOME/config/hand-stale"

# --- 6. once per silence ---------------------------------------------------
say 'working: rewriting the parser'
backdate 7300
sentry
ck_eq  "6 the first watch wakes"                          "$RC" 0
sentry
ck_eq  "6 the next does not repeat it"                    "$RC" 4
printf 'unknown\n' > "$STUB_ATTN"; sentry
printf 'settled\n' > "$STUB_ATTN"; sentry
ck_eq  "6 nor after the backend blinked unknown"          "$RC" 4
ck_eq  "6 the listing still shows it, it only shows"      "$(row)" "alive/idle 2h"
printf 'working: rewriting the lexer\n' >> "$STATUS"
backdate 7300
sentry
ck_eq  "6 a hand that spoke and fell silent again wakes"  "$RC" 0
ck_has "6 with what it said last"                         "$OUT" "last said rewriting the lexer"

# --- 7. the dead turn marker -----------------------------------------------
cat > "$STUB_PANE" <<'PANE'
⏺ Reading src/parser.rs
  ⎿  API Error: Can't reach the API server (ENOTFOUND)

 ─────────────────────────────────────────────
  ❯
 ─────────────────────────────────────────────
PANE
say 'working: rewriting the parser'
backdate 700
sentry
ck_eq  "7 a dead turn is stale after ten minutes"         "$RC" 0
ck_has "7 and says it was an error"                       "$OUT" "idle after an API error"
ck_has "7 the single form says so too"                    "$(single)" "after an API error"
say 'working: rewriting the parser'
backdate 500
sentry
ck_eq  "7 but not before ten minutes"                     "$RC" 4
printf '300\n' > "$REEVE_HOME/config/hand-stale-error"
sentry
ck_eq  "7 that wait is config too"                        "$RC" 0
printf 'nope\n' > "$REEVE_HOME/config/hand-stale-error"
say 'working: rewriting the parser'
backdate 700
sentry
ck_eq  "7 a bad error wait drops back to time alone"      "$RC" 4
rm -f "$REEVE_HOME/config/hand-stale-error"

# Evidence, not words: an error mentioned mid sentence is a hand writing about
# one, and an error far up the scrollback is a turn that went on afterwards.
printf '⏺ The log shows API Error: lines when the network drops.\n ❯\n' > "$STUB_PANE"
say 'working: rewriting the parser'
backdate 700
sentry
ck_eq  "7 the words mid sentence are not a dead turn"     "$RC" 4
{ printf '  ⎿  API Error: overloaded\n'; for n in $(seq 1 40); do printf 'line %s\n' "$n"; done; } > "$STUB_PANE"
sentry
ck_eq  "7 nor is an old error that the turn outlived"     "$RC" 4
: > "$STUB_PANE"
sentry
ck_eq  "7 an empty capture falls back to time alone"      "$RC" 4

# --- 8. it reports, and never acts -----------------------------------------
# Without --no-reap, and with the stub logging anything that would touch the
# session: a stale hand is the reeve's to decide about.
: > "$STUB_ACTS"
say 'working: rewriting the parser'
backdate 86400
OUT=$("$ROOT/bin/reeve-sentry" --once 2>&1); RC=$?
ck_eq  "8 a reaping watch still only reports"             "$RC" 0
ck_eq  "8 nothing was sent, killed or launched"           "$(cat "$STUB_ACTS")" ""
ck_eq  "8 and nothing was torn down"                      "$(grep -c '^tornDown=' "$META")" 0
ck_eq  "8 the hand still owns its log"                    "$(cat "$STATUS")" "working: rewriting the parser"

# --- 9. a steer re-arms it -------------------------------------------------
# Last night's recovery: the reeve told a dead turn to carry on, the hand worked
# without writing a line, and died again. The status file never changed, and
# the second death has to be a second wake all the same.
say 'working: rewriting the parser'
backdate 86400
sentry
ck_eq  "9 the first death wakes"                          "$RC" 0
sentry
ck_eq  "9 and is said once"                               "$RC" 4
printf 'working\n' > "$STUB_ATTN"; sentry
ck_eq  "9 the steered turn is quiet while it works"       "$RC" 4
ck_eq  "9 and working re-arms the latch"                  "$([ -f "$REEVE_HOME/state/.stale-hung" ] && echo kept || echo gone)" gone
printf 'settled\n' > "$STUB_ATTN"; sentry
ck_eq  "9 the second death wakes again, with no new line" "$RC" 0
ck_has "9 the same errand, the same silence"              "$OUT" "idle: hung has been silent for 24h 0m"
sentry
ck_eq  "9 and that one is said once too"                  "$RC" 4

# --- 10. a bad hand-stale is not a bad hand-stale-error --------------------
cat > "$STUB_PANE" <<'PANE'
  ⎿  API Error: Can't reach the API server (ENOTFOUND)
  ❯
PANE
for v in abc 7200s ''; do
  say 'working: rewriting the parser'
  backdate 700
  printf '%s\n' "$v" > "$REEVE_HOME/config/hand-stale"
  sentry
  ck_eq  "10 hand-stale [$v]: the error wait still fires"  "$RC" 0
  ck_has "10 hand-stale [$v]: as an API error"             "$OUT" "idle after an API error"
  ck_has "10 hand-stale [$v]: and the watch says why"      "$OUT" "config/hand-stale is not a whole number"
  ck_eq  "10 hand-stale [$v]: on stderr, one stdout line"  \
    "$(say 'working: rewriting the parser'; backdate 700; "$ROOT/bin/reeve-sentry" --once --no-reap 2>/dev/null | grep -c .)" 1
done
: > "$STUB_PANE"
say 'working: rewriting the parser'
backdate 864000
sentry
ck_eq  "10 without an error pane, still closed"           "$RC" 4
ck_has "10 and the quiet watch says the check is off"     "$OUT" "the staleness check on time alone is off"
printf 'nope\n' > "$REEVE_HOME/config/hand-stale-error"
rm -f "$REEVE_HOME/config/hand-stale"
sentry
ck_eq  "10 a bad error wait leaves time alone working"    "$RC" 0
ck_has "10 and is said too"                               "$OUT" "config/hand-stale-error is not a whole number"
rm -f "$REEVE_HOME/config/hand-stale-error"

# --- 11. the dwell ---------------------------------------------------------
# A hand between tool calls can read settled for an instant. The first stale
# reading starts a clock; a working one stops it.
dsentry() { OUT=$(REEVE_ATTN_DWELL=90 REEVE_ATTN_NOW=$1 "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?; }
say 'working: rewriting the parser'
backdate 86400
dsentry "$NOW"
ck_eq  "11 one settled reading is not a wake"             "$RC" 4
printf 'working\n' > "$STUB_ATTN"; dsentry $(( NOW + 30 ))
ck_eq  "11 the turn was still going"                      "$RC" 4
printf 'settled\n' > "$STUB_ATTN"; dsentry $(( NOW + 100 ))
ck_eq  "11 the clock restarted, so still no wake"         "$RC" 4
dsentry $(( NOW + 150 ))
ck_eq  "11 nor inside the dwell"                          "$RC" 4
dsentry $(( NOW + 190 ))
ck_eq  "11 settled past the dwell is the wake"            "$RC" 0
ck_has "11 and it is the idle line"                       "$OUT" "idle: hung"

# --- 12. two conditions, two prefixes --------------------------------------
say 'working: rewriting the parser'
backdate 86400
printf 'dead\n' > "$STUB_LIVE"
sentry
ck_eq  "12 a gone session opens with stale:"              "${OUT%%:*}" stale
ck_has "12 and says it left no result"                    "$OUT" "left no result"
rm -f "$STUB_LIVE"
say 'working: rewriting the parser'
backdate 86400
sentry
ck_eq  "12 an idle living one opens with idle:"           "${OUT%%:*}" idle
w_idle=${OUT%%:*}
printf 'dead\n' > "$STUB_LIVE"; sentry; w_gone=${OUT%%:*}; rm -f "$STUB_LIVE"
# A spool that holds a line it cannot give up, for a reeve of its own, so the
# errand above plays no part in it.
SPOOL="$REEVE_HOME/state/sessions/stuck/wake"
REEVE_SESSION=stuck bash -c '. "$1/bin/reeve-lib.sh"; wake_leave stuck "signal: held is done" held 1' _ "$ROOT"
chmod a-w "$SPOOL"
OUT=$(REEVE_SESSION=stuck "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
chmod u+w "$SPOOL"; rm -rf "$REEVE_HOME/state/sessions/stuck"
ck_eq  "12 an undeliverable notification wakes"           "$RC" 0
ck_eq  "12 and opens with undeliverable:"                 "${OUT%%:*}" undeliverable
ck_has "12 and still says what is in the way"             "$OUT" "cannot be delivered"
ck_eq  "12 three conditions, three different words"       \
  "$(printf '%s\n' "$w_gone" "$w_idle" "${OUT%%:*}" | sort -u | grep -c .)" 3

# --- 13. a session that cannot say ------------------------------------------
# tmux without herdr reads unknown, never settled, so the wake cannot come. The
# watch says so instead of reading as quiet.
printf 'unknown\n' > "$STUB_ATTN"
say 'working: rewriting the parser'
backdate 86400
sentry
ck_eq  "13 unknown is still not a wake"                   "$RC" 4
ck_has "13 but the watch says it cannot judge it"         "$OUT" "hung has been silent for 24h 0m but its session reads unknown"
ck_eq  "13 on stderr, so stdout stays one line"           \
  "$("$ROOT/bin/reeve-sentry" --once --no-reap 2>/dev/null | grep -c .)" 1
backdate 600
sentry
ck_not "13 inside the threshold there is nothing to say"  "$OUT" "reads unknown"
printf 'settled\n' > "$STUB_ATTN"

# --- 14. the listing and the alarm agree -------------------------------------
# The listing once called a hand stale on its first look, ninety seconds before
# the sentry would wake for it. Both now ask stale_probe, dwell included, and
# either one's first look starts the one clock.
drow() { REEVE_ATTN_DWELL=90 REEVE_ATTN_NOW=$1 row; }
say 'working: rewriting the parser'
backdate 86400
ck_eq  "14 the listing's first look only starts the clock" "$(drow "$NOW")" "alive/settled"
dsentry $(( NOW + 89 ))
ck_eq  "14 at 89s the sentry has not woken"                "$RC" 4
ck_eq  "14 and the listing has not called it idle"         "$(drow $(( NOW + 89 )))" "alive/settled"
ck_eq  "14 at 90s the listing calls it idle"               "$(drow $(( NOW + 90 )))" "alive/idle 24h"
dsentry $(( NOW + 90 ))
ck_eq  "14 and the sentry wakes on the same second"        "$RC" 0
ck_has "14 with the idle line"                             "$OUT" "idle: hung"
say 'working: rewriting the parser'
backdate 86400
dsentry "$NOW"
ck_eq  "14 the sentry looking first starts it too"         "$RC" 4
ck_eq  "14 so at 89s the listing still waits"              "$(drow $(( NOW + 89 )))" "alive/settled"
dsentry $(( NOW + 89 ))
ck_eq  "14 as does the sentry"                             "$RC" 4
dsentry $(( NOW + 90 ))
ck_eq  "14 at 90s the sentry wakes"                        "$RC" 0
ck_eq  "14 and the listing agrees"                         "$(drow $(( NOW + 90 )))" "alive/idle 24h"
printf 'working\n' > "$STUB_ATTN"
ck_eq  "14 a working reading in the listing"               "$(drow $(( NOW + 100 )))" "alive/working"
ck_eq  "14 stops the sentry's clock too"                   "$([ -f "$REEVE_HOME/state/.stale-hung" ] && echo kept || echo gone)" gone
printf 'settled\n' > "$STUB_ATTN"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
