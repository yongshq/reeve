#!/usr/bin/env bash
# A hand frozen inside one command: a hung test, a network call that never
# returns. Its session reads `working` for as long as it is frozen, so the idle
# alarm, which needs a session at its prompt, never fires, and every tool read it
# as progress forever. The liege's constraint: one hand legitimately thought for
# forty minutes in one turn, so silence alone would cry wolf. The screen is the
# second witness: a thinking hand's transcript grows, a wedged one's does not.
#
# Covered here, against a stub backend so no terminal is involved, with
# captures shaped like a real claude pane:
#   1. a wedged hand wakes once, after the window and not before
#   2. a thinking turn, timer ticking and transcript growing, never wakes
#   3. a status line inside the window is no wedge, however still the screen
#   4. a new status line re-arms it
#   5. a screen that moves re-arms it
#   6. a steer through bin/reeve-steer re-arms it, and a late write cannot undo that
#   7. blocked, done, failed and an open decision never wedge; nor does a
#      session that is settled, waiting or unknown, and unknown is said on stderr
#   8. a screen that cannot be read: no wake, said once per watch, latch kept
#   9. no listing form writes the latch, and the listing agrees with the wake
#  10. the threshold is config, and a bad value fails closed and is said
#  11. it reports and never acts
#  12. the widest age stays inside the PROCESS column
#  13. the normaliser, one rule at a time, so a mutation of any one fails here
#  14. a long todo list under the spinner, or a tall agent panel under the
#      composer, cannot push the running tool's timers out of what is stripped
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_ne()  { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "both were [$2]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]: $2" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output should not have said [$3]: $2" ;; *) ok "$1" ;; esac; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-wedge-test.XXXXXX") || exit 1
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

unset CLAUDE_CODE_SESSION_ID
export REEVE_SESSION=''
export REEVE_ROOT="$SCRATCH/root"
export REEVE_HOME="$SCRATCH/home"
mkdir -p "$REEVE_ROOT/backends" "$REEVE_HOME/state" "$REEVE_HOME/config" "$REEVE_HOME/errands/hung"

export STUB_ATTN="$SCRATCH/attn" STUB_PANE="$SCRATCH/pane" STUB_ACTS="$SCRATCH/acts" STUB_LIVE="$SCRATCH/live" STUB_CAPS="$SCRATCH/caps"
cat > "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()        { return 0; }
reeve_backend_stub_describe()         { echo stub; }
reeve_backend_stub_agent_state()      { cat "$STUB_LIVE" 2>/dev/null || echo alive; }
reeve_backend_stub_attention_state()  { cat "$STUB_ATTN"; }
reeve_backend_stub_capture()          { echo x >> "$STUB_CAPS"; cat "$STUB_PANE"; }
reeve_backend_stub_wait_change()      { return 2; }
reeve_backend_stub_kill()             { echo "kill $*" >> "$STUB_ACTS"; }
reeve_backend_stub_send_text_submit() { echo "send $*" >> "$STUB_ACTS"; }
reeve_backend_stub_launch()           { echo "launch $*" >> "$STUB_ACTS"; }
STUB
# A backend with no capture at all, for case 8.
sed -e 's/_stub_/_blind_/' -e '/_capture()/d' "$REEVE_ROOT/backends/stub.sh" > "$REEVE_ROOT/backends/blind.sh"

META="$REEVE_HOME/state/hung.meta"
STATUS="$REEVE_HOME/errands/hung/status"
LATCH="$REEVE_HOME/state/.wedged-hung"
IDLE="$REEVE_HOME/state/.stale-hung"
meta() { printf 'target=s|s:p1\nbackend=%s\noffice=artificer\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=yes\ndispatched=2026-10-01T21:30:00\n' "${1:-stub}" > "$META"; }
meta

# Two clocks, as in stale-watch.test.bash: REEVE_NOW frozen for the status
# file's silence, and the latch's on REEVE_ATTN_NOW, moved by each call.
NOW=$(date +%s)
export REEVE_NOW=$NOW
export REEVE_ATTN_DWELL=0

backdate() {
  local ts=$(( NOW - $1 )) stamp
  stamp=$(date -r "$ts" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$ts" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$STATUS"
}
# say <lines...>   rewrite the log, cursor at its end, so only the probe speaks
say() {
  printf '%s\n' "$@" > "$STATUS"
  printf '%s\n' "$#" > "$REEVE_HOME/state/.cursor-hung"
  rm -f "$LATCH" "$IDLE" "$REEVE_HOME/state/.steered-hung"
}
# sentry <attn clock>
sentry() { OUT=$(REEVE_ATTN_NOW=$1 "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?; }
row()    { REEVE_ATTN_NOW=$1 "$ROOT/bin/reeve-status" --all --no-wake 2>/dev/null | grep '^hung ' | cut -c55-70 | sed 's/ *$//'; }
open()   { REEVE_ATTN_NOW=$1 "$ROOT/bin/reeve-status" --all --no-wake 2>/dev/null | grep '^hung ' | cut -c71-; }
single() { REEVE_ATTN_NOW=$1 "$ROOT/bin/reeve-status" hung 2>/dev/null | sed -n 's/^process  *//p'; }
latched() { [ -f "$LATCH" ] && echo kept || echo gone; }

# A claude pane mid turn. <lines> transcript lines above the running tool, then
# the turn's chrome: the tool's bullet, which blinks, its own timer, the spinner
# with its glyph, verb, timer and token count, the composer, and a statusline.
# TODOS, when set, is how many todo items claude draws under the spinner, and
# AGENTS how many background agents it lists under the composer, each with its
# own ticking counters: both push the running tool up the screen.
# pane <lines> <elapsed> [glyph] [verb] [bullet] [footer]
pane() {
  local n
  {
    printf '⏺ I will run the whole suite, then fix what fails.\n\n'
    for n in $(seq 1 "$1"); do printf '  line %s of the transcript\n' "$n"; done
    printf '\n%s Bash(bash tests/run-all.bash)\n' "${5:-⏺}"
    printf '  ⎿  Running… (%s)\n\n' "$2"
    printf '%s %s… (%s · ↓ 3.1k tokens · esc to interrupt)\n' "${3:-✻}" "${4:-Brewing}" "$2"
    for n in $(seq 1 "${TODOS:-0}"); do
      [ "$n" = 1 ] && printf '  ⎿  ' || printf '     '
      printf '☐ Fix failure %s of the suite\n' "$n"
    done
    printf '\n────────────────────────────────────────────────────────────\n'
    printf '> \n'
    printf '────────────────────────────────────────────────────────────\n'
    printf '  %s\n' "${6:-? for shortcuts}"
    for n in $(seq 1 "${AGENTS:-0}"); do
      printf '  ⏺ scout-%s · %s tool uses · %s.2k tokens · %s\n' "$n" "${#2}" "${#2}" "$2"
    done
  } > "$STUB_PANE"
}

printf 'working\n' > "$STUB_ATTN"
W=7200

# --- 1. a wedged hand -------------------------------------------------------
# The timer ticks, the spinner turns, the bullet blinks, the statusline redraws:
# all chrome. The transcript never moves.
say 'working: running the suite'
backdate 7300
T=$NOW
pane 20 '1m 3s' '✻' Brewing '⏺' 'ctx 12% · $0.40'
sentry "$T"
ck_eq  "1 the first look only starts the clock"            "$RC" 4
ck_eq  "1 in the wedged latch"                             "$(latched)" kept
ck_eq  "1 and leaves the idle one alone"                   "$([ -f "$IDLE" ] && echo kept || echo gone)" gone
pane 20 '1h 0m 12s' '✢' Brewing ' ' 'ctx 13% · $0.41   ⏵⏵ accept edits on'
sentry $(( T + 3600 ))
ck_eq  "1 an hour of ticking chrome is not a wake yet"     "$RC" 4
pane 20 '2h 0m 2s' '✶' Brewing '⏺' 'ctx 14% · $0.42'
sentry $(( T + W - 1 ))
ck_eq  "1 nor a second inside the window"                  "$RC" 4
ck_eq  "1 and the listing calls it working until then"     "$(row $(( T + W - 1 )))" "alive/working"
sentry $(( T + W ))
ck_eq  "1 the window held still: a wake"                   "$RC" 0
ck_eq  "1 it opens with wedged:"                           "${OUT%%:*}" wedged
ck_has "1 it names the errand and the silence"             "$OUT" "wedged: hung has been silent for 2h 1m"
ck_has "1 and how long the screen held"                    "$OUT" "its screen unchanged for 2h 0m"
ck_has "1 and what it last said"                           "$OUT" "last said running the suite"
ck_eq  "1 one line, like every other reason"               "$(printf '%s\n' "$OUT" | grep -c .)" 1
ck_eq  "1 the latch says it was reported"                  "$(awk '{print $NF}' "$LATCH")" yes
ck_eq  "1 the latch holds since, mark and print"           "$(awk '{print NF}' "$LATCH")" 5
sentry $(( T + W + 60 ))
ck_eq  "1 said once"                                       "$RC" 4
sentry $(( T + 3 * W ))
ck_eq  "1 and not again however long it stays"             "$RC" 4
ck_eq  "1 the listing shows it in PROCESS"                 "$(row $(( T + W )))" "alive/wedged 2h"
ck_eq  "1 the single form says both"                       "$(single $(( T + W )))" \
  "alive/working, wedged: silent 2h 1m, screen unchanged 2h 0m"

# --- 2. a thinking turn -----------------------------------------------------
# The same chrome ticking, and a transcript that grows: across three windows,
# never a wake, and never a word in the listing.
say 'working: running the suite'
backdate 86400
T=$(( NOW + 100000 ))
fired=no
for k in $(seq 0 12); do
  pane $(( 20 + k )) "$k""h 0m" '✻' Brewing '⏺'
  sentry $(( T + k * 1800 ))
  [ "$RC" = 0 ] && fired=yes
done
ck_eq  "2 a growing transcript never wakes"                "$fired" no
ck_eq  "2 nor reads wedged in the listing"                 "$(row $(( T + 12 * 1800 )))" "alive/working"
# Forty minutes of one turn with nothing new on the screen at all: inside the
# window, so still nothing.
say 'working: running the suite'
backdate 2400
T=$(( NOW + 200000 ))
pane 30 '1m'; sentry "$T"
pane 30 '40m'; sentry $(( T + 2400 ))
ck_eq  "2 a forty minute turn is not a wedge"              "$RC" 4

# --- 3. the status file is the other witness --------------------------------
say 'working: running the suite'
backdate 7100
T=$(( NOW + 300000 ))
pane 20 '1m'; sentry "$T"
pane 20 '9h'; sentry $(( T + 5 * W ))
ck_eq  "3 a status line inside the window is no wedge"     "$RC" 4
ck_eq  "3 nor in the listing"                              "$(row $(( T + 5 * W )))" "alive/working"

# --- 4. a status line re-arms it --------------------------------------------
say 'working: running the suite'
backdate 7300
T=$(( NOW + 400000 ))
pane 20 '1m'; sentry "$T"; sentry $(( T + W ))
ck_eq  "4 the first wedge wakes"                           "$RC" 0
printf 'working: still running the suite\n' >> "$STATUS"
printf '2\n' > "$REEVE_HOME/state/.cursor-hung"
backdate 7300
sentry $(( T + W + 100 ))
ck_eq  "4 a new line starts a new silence, no wake yet"    "$RC" 4
sentry $(( T + 2 * W + 99 ))
ck_eq  "4 and not inside its window"                       "$RC" 4
sentry $(( T + 2 * W + 100 ))
ck_eq  "4 the second wedge wakes"                          "$RC" 0
ck_has "4 with what it said last"                          "$OUT" "last said still running the suite"

# --- 5. a screen that moves re-arms it --------------------------------------
say 'working: running the suite'
backdate 86400
T=$(( NOW + 500000 ))
pane 20 '1m'; sentry "$T"; sentry $(( T + W ))
ck_eq  "5 the first wedge wakes"                           "$RC" 0
pane 21 '2h'
sentry $(( T + W + 100 ))
ck_eq  "5 the screen moved: a new clock, no wake"          "$RC" 4
ck_eq  "5 and the listing is back to working"              "$(row $(( T + W + 100 )))" "alive/working"
sentry $(( T + 2 * W + 100 ))
ck_eq  "5 frozen again for the window: a second wake"      "$RC" 0
ck_has "5 the screen measured from when it moved"          "$OUT" "screen unchanged for 2h 0m"

# --- 6. a steer re-arms it --------------------------------------------------
say 'working: running the suite'
backdate 86400
T=$(( NOW + 600000 ))
pane 20 '1m'; sentry "$T"; sentry $(( T + W ))
ck_eq  "6 the first wedge wakes"                           "$RC" 0
# Typed into the session by hand, the text lands in the composer, which the
# print never sees, so the old wedge stands and is not said again.
"$ROOT/bin/reeve-backend" call send_text_submit 's|s:p1' 'kill the hung test and carry on' --backend stub
sentry $(( T + 3 * W ))
ck_eq  "6 steered by hand, no second wake"                 "$RC" 4
OUT=$(REEVE_ATTN_NOW=$(( T + 3 * W )) "$ROOT/bin/reeve-steer" hung 'kill the hung test and carry on' 2>&1); RC=$?
ck_eq  "6 the steer is delivered"                          "$RC" 0
ck_has "6 and says the wedged alarm is re-armed too"       "$OUT" "and the wedged alarm with it"
ck_eq  "6 the wedged latch is gone"                        "$(latched)" gone
ck_eq  "6 the status file is untouched"                    "$(cat "$STATUS")" "working: running the suite"
sentry $(( T + 3 * W + 10 ))
ck_eq  "6 the next look starts a fresh clock"              "$RC" 4
sentry $(( T + 4 * W + 9 ))
ck_eq  "6 and does not wake inside it"                     "$RC" 4
sentry $(( T + 4 * W + 10 ))
ck_eq  "6 frozen again after the steer: a second wake"     "$RC" 0
# A watch pass that read the latch before a steer and writes it back after,
# reported and with the old since: no latch at all, as for the idle one.
pre=$(cat "$LATCH")
REEVE_ATTN_NOW=$(( T + 5 * W )) "$ROOT/bin/reeve-steer" hung 'carry on' >/dev/null 2>&1
printf '%s\n' "$pre" > "$LATCH"
sentry $(( T + 5 * W + 10 ))
ck_eq  "6 a late write cannot swallow the next wedge"      "$RC" 4
sentry $(( T + 6 * W + 10 ))
ck_eq  "6 which still wakes, a window later"               "$RC" 0

# --- 7. explained silences and other sessions -------------------------------
for c in 'done: suite green' 'failed: cannot build' \
         'needs-decision [key=api]: keep the old api?' 'blocked: no .env present'; do
  say 'working: running the suite' "$c"
  backdate 86400
  T=$(( NOW + 700000 ))
  pane 20 '1m'; sentry "$T"; sentry $(( T + 2 * W ))
  ck_not "7 never wedged: ${c%%:*}"                        "$OUT" "wedged:"
  ck_eq  "7 no clock started: ${c%%:*}"                    "$(latched)" gone
  ck_not "7 nor in the listing: ${c%%:*}"                  "$(row $(( T + 2 * W )))" "wedged"
done
for a in settled waiting unknown; do
  say 'working: running the suite'
  backdate 86400
  T=$(( NOW + 800000 ))
  pane 20 '1m'; sentry "$T"
  printf '%s\n' "$a" > "$STUB_ATTN"
  rm -f "$REEVE_HOME/state/.attn-hung"
  sentry $(( T + 2 * W ))
  ck_not "7 a session reading $a is never wedged"          "$OUT" "wedged:"
  ck_not "7 nor in the listing when $a"                    "$(row $(( T + 2 * W )))" "wedged"
  case $a in
    unknown) ck_eq "7 unknown re-arms nothing"             "$(latched)" kept
             ck_has "7 and the watch says no wedged wake can come" \
               "$OUT" "cannot be judged stale or wedged and no idle or wedged wake will come for it" ;;
    *)       ck_eq "7 $a ends the turn, and the clock"     "$(latched)" gone ;;
  esac
  printf 'working\n' > "$STUB_ATTN"
done
rm -f "$REEVE_HOME/state/.attn-hung"

# --- 8. a screen that cannot be read ----------------------------------------
say 'working: running the suite'
backdate 86400
T=$(( NOW + 900000 ))
pane 20 '1m'; sentry "$T"
pre=$(cat "$LATCH")
rm -f "$STUB_PANE"
sentry $(( T + 2 * W ))
ck_eq  "8 a failed capture never wakes"                    "$RC" 4
ck_has "8 and the watch says it cannot judge it"           "$OUT" "hung has been silent for 24h 0m while its session works, but its screen could not be read on backend stub"
ck_has "8 and what that costs"                             "$OUT" "no wedged wake will come for it"
ck_eq  "8 on stderr, stdout stays one line"                \
  "$(REEVE_ATTN_NOW=$(( T + 2 * W )) "$ROOT/bin/reeve-sentry" --once --no-reap 2>/dev/null | grep -c .)" 1
ck_eq  "8 the latch is left as it was"                     "$(cat "$LATCH")" "$pre"
ck_not "8 the listing does not call it wedged"             "$(row $(( T + 2 * W )))" "wedged"
# Once per watch, not once per poll: a watch that polls without sleeping makes
# several passes over the same blind hand. Counted by the captures it tried, and
# given seconds enough that a loaded machine still fits two passes in.
: > "$STUB_CAPS"
OUT=$(REEVE_ATTN_NOW=$(( T + 2 * W )) REEVE_SENTRY_SLEEPS="$SCRATCH/sleeps" \
      "$ROOT/bin/reeve-sentry" --poll 1 --timeout 8 --no-reap 2>&1)
ck_eq  "8 a long watch made several passes"                "$([ "$(grep -c . "$STUB_CAPS")" -gt 1 ] && echo yes)" yes
ck_eq  "8 and said it once"                                "$(printf '%s\n' "$OUT" | grep -c 'could not be read')" 1
: > "$STUB_PANE"
sentry $(( T + 2 * W ))
ck_has "8 an empty capture is a failed one"                "$OUT" "could not be read"
backdate 600
sentry $(( T + 2 * W ))
ck_not "8 inside the window there is nothing to say"       "$OUT" "could not be read"
# A backend with no capture at all: the same answer, not an error.
say 'working: running the suite'
backdate 86400
meta blind
sentry "$T"
ck_eq  "8 a backend that cannot capture never wakes"       "$RC" 4
ck_has "8 and says so"                                     "$OUT" "could not be read on backend blind"
ck_eq  "8 and starts no clock"                             "$(latched)" gone
meta

# --- 9. the listing writes nothing ------------------------------------------
say 'working: running the suite'
backdate 86400
T=$(( NOW + 1000000 ))
pane 20 '1m'
for form in '--all' '--all --no-wake' '' '--no-wake' '--orphans' 'hung' 'hung --raw'; do
  # shellcheck disable=SC2086
  REEVE_ATTN_NOW=$T "$ROOT/bin/reeve-status" $form >/dev/null 2>&1
  ck_eq "9 reeve-status ${form:-bare} creates no latch"    "$(latched)" gone
done
sentry "$T"
before=$(cat "$LATCH")
touch -t 200001010000 "$LATCH"
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
mbefore=$(mtime "$LATCH")
for form in '--all' '--all --no-wake' '' 'hung'; do
  for t in $(( T + 100 )) $(( T + W )) $(( T + 2 * W )); do
    # shellcheck disable=SC2086
    REEVE_ATTN_NOW=$t "$ROOT/bin/reeve-status" $form >/dev/null 2>&1
  done
done
ck_eq  "9 nor rewrites one the sentry wrote"               "$(cat "$LATCH")" "$before"
ck_eq  "9 not even its mtime"                              "$(mtime "$LATCH")" "$mbefore"
# The listing turns wedged on at the second the sentry wakes, and only while
# the screen is still the one the latch saw.
ck_eq  "9 a second before the window, working"             "$(row $(( T + W - 1 )))" "alive/working"
ck_eq  "9 at the window, wedged"                           "$(row $(( T + W )))" "alive/wedged 24h"
sentry $(( T + W ))
ck_eq  "9 the same second the sentry wakes"                "$RC" 0
pane 21 '2h'
ck_eq  "9 a screen that moved since is not wedged"         "$(row $(( T + W + 50 )))" "alive/working"
ck_eq  "9 and the listing did not touch the latch"         "$(awk '{print $NF}' "$LATCH")" yes

# --- 10. the threshold is config --------------------------------------------
say 'working: running the suite'
backdate 120
T=$(( NOW + 1100000 ))
printf '60\n' > "$REEVE_HOME/config/hand-wedged"
pane 20 '1m'; sentry "$T"; sentry $(( T + 60 ))
ck_eq  "10 a configured window is honoured"                "$RC" 0
ck_has "10 with the silence it measured"                   "$OUT" "silent for 2m"
for v in abc 7200s -5 ''; do
  say 'working: running the suite'
  backdate 864000
  printf '%s\n' "$v" > "$REEVE_HOME/config/hand-wedged"
  pane 20 '1m'; sentry "$T"; sentry $(( T + 10 * W ))
  ck_eq  "10 hand-wedged [$v] fails closed, never fires"   "$RC" 4
  ck_has "10 hand-wedged [$v] and the watch says why"      "$OUT" "config/hand-wedged is not a whole number"
  ck_eq  "10 hand-wedged [$v] the listing does not either" "$(row $(( T + 10 * W )))" "alive/working"
  ck_has "10 hand-wedged [$v] and says the check is off"   \
    "$("$ROOT/bin/reeve-status" --all --no-wake 2>&1 >/dev/null)" "check for a hand wedged mid turn is off"
done
printf '0\n' > "$REEVE_HOME/config/hand-wedged"
say 'working: running the suite'
backdate 864000
pane 20 '1m'; sentry "$T"; sentry $(( T + 10 * W ))
ck_eq  "10 zero turns it off"                              "$RC" 4
ck_not "10 and is a choice, not remarked on"               "$OUT" "hand-wedged"
rm -f "$REEVE_HOME/config/hand-wedged"
# The idle half is untouched by a bad wedged value, and the other way about.
printf 'abc\n' > "$REEVE_HOME/config/hand-stale"
say 'working: running the suite'
backdate 7300
pane 20 '1m'; sentry "$T"; sentry $(( T + W ))
ck_eq  "10 a bad hand-stale leaves the wedge check on"     "$RC" 0
rm -f "$REEVE_HOME/config/hand-stale"

# --- 11. it reports and never acts ------------------------------------------
: > "$STUB_ACTS"
say 'working: running the suite'
backdate 86400
T=$(( NOW + 1200000 ))
pane 20 '1m'
REEVE_ATTN_NOW=$T "$ROOT/bin/reeve-sentry" --once >/dev/null 2>&1
OUT=$(REEVE_ATTN_NOW=$(( T + W )) "$ROOT/bin/reeve-sentry" --once 2>&1); RC=$?
ck_eq  "11 a reaping watch still only reports"             "$RC" 0
ck_has "11 the wedge"                                      "$OUT" "wedged: hung"
ck_eq  "11 nothing was sent, killed or launched"           "$(cat "$STUB_ACTS")" ""
ck_eq  "11 and nothing was torn down"                      "$(grep -c '^tornDown=' "$META")" 0
ck_eq  "11 the hand still owns its log"                    "$(cat "$STATUS")" "working: running the suite"

# --- 12. the cell stays in its column ---------------------------------------
# `alive/wedged ` is thirteen, so the short age has three, the most it prints.
for age in 7300 172799 8639999 60479999 $(( NOW - 86400 )); do
  say 'working: running the suite'
  backdate "$age"
  T=$(( NOW + 1300000 ))
  pane 20 '1m'; sentry "$T"; sentry $(( T + W ))
  w=$(bash -c '. "$1/bin/reeve-lib.sh"; silence_short "$2"' _ "$ROOT" "$age")
  ck_eq  "12 wedged $w fits the column"                    "$(row $(( T + W )))" "alive/wedged $w"
  ck_eq  "12 and OPEN stays where it was"                  "$(open $(( T + W )))" " -"
done

# --- 13. the normaliser -----------------------------------------------------
# One rule at a time: each pair below differs only in what one rule takes out,
# so dropping that rule makes the pair print differently and fails its case.
# The last three are the other direction: what it must never take out.
pp() { bash -c '. "$1/bin/reeve-lib.sh"; pane_print "$2"' _ "$ROOT" "$1"; }
same() { ck_eq "13 $1" "$(pp "$2")" "$(pp "$3")"; }
differ() { ck_ne "13 $1" "$(pp "$2")" "$(pp "$3")"; }
body='⏺ I will run the whole suite.

  Ran 41 tests, 2 failed.
  line one
  line two'
composer='────────────────────────────────────────
>
────────────────────────────────────────'
# Built with printf, because an editor that trims trailing blanks would quietly
# turn this case into one that proves nothing. The body sits above the bottom
# lines here, where nothing but this rule touches it.
pad=$(seq 1 14 | sed 's/^/  more /')
same "blank lines and trailing blanks are layout" \
  "$(printf '%s\n%s\n⏺ Bash(sleep 9999)\n✻ Brewing… (1m)\n%s' "$body" "$pad" "$composer")" \
  "$(printf '%s   \n\n%s\n\n⏺ Bash(sleep 9999)    \n      \n\n✻ Brewing… (1m)\n\n%s' "$body" "$pad" "$composer")"
same "the statusline under the composer is chrome" \
  "$body
$composer
  ? for shortcuts" \
  "$body
$composer
  ⏵⏵ accept edits on (shift+tab to cycle)   opus · main"
same "so is the boxed composer and what is typed in it" \
  "$body
╭──────────────────────────────────────╮
│ >                                    │
╰──────────────────────────────────────╯" \
  "$body
╭──────────────────────────────────────╮
│ > kill the hung test and carry on    │
╰──────────────────────────────────────╯"
same "the spinner's glyph and verb are chrome" \
  "$body
✻ Brewing… (2h 3m · ↓ 3.1k tokens)
$composer" \
  "$body
✢ Pondering… (2h 4m · ↓ 3.1k tokens)
$composer"
same "a line with the interrupt hint is chrome" \
  "$body
• Working (12s • esc to interrupt)
$composer" \
  "$body
• Searching for tests (2h 01m • esc to interrupt)
$composer"
same "a running tool's timer is chrome" \
  "$body
  ⎿  Running… (1m 3s)
$composer" \
  "$body
  ⎿  Running… (2h 0m 59s)
$composer"
same "a pending tool's blinking bullet is chrome" \
  "$body
⏺ Bash(sleep 9999)
$composer" \
  "$body
  Bash(sleep 9999)
$composer"
same "the tip under the spinner is chrome" \
  "$body
✻ Brewing… (2h 3m)
  ⎿  Tip: Use /clear to start fresh when switching topics
$composer" \
  "$body
✻ Brewing… (2h 3m)
  ⎿  Tip: Press Esc twice to edit a previous message
$composer"
# Two lines exactly as a real claude pane showed them, forty seconds apart, in
# the middle of one long tool call.
same "a real pane's tool timers are chrome" \
  "$body
  Running the whole suite · 11s
  ⎿  \$ bash tests/run-all.bash… (12s · 9 lines)
     (ctrl+b to run in background)
· Scampering… (34m 59s · ↓ 73.7k tokens)
$composer" \
  "$body
⏺ Running the whole suite · 52s
  ⎿  \$ bash tests/run-all.bash… (52s · 9 lines)
     (ctrl+b to run in background)
✻ Scampering… (35m 39s · ↓ 73.7k tokens)
$composer"
same "with no composer at all, the bottom lines are still the chrome" \
  "$body
✻ Brewing… (2h 3m)
  ctx 45%" \
  "$body
✶ Brewing… (2h 9m)
  ctx 47%"
differ "a new transcript line is a change" \
  "$body
⏺ Bash(sleep 9999)
$composer" \
  "$body
  line three
⏺ Bash(sleep 9999)
$composer"
differ "a digit above the bottom lines is a change" \
  "$body
$(seq 1 14 | sed 's/^/  more /')
$composer" \
  "$(printf '%s\n' "$body" | sed 's/Ran 41/Ran 42/')
$(seq 1 14 | sed 's/^/  more /')
$composer"
differ "words changing just above the composer are a change" \
  "$body
  ⎿  3 passed
$composer" \
  "$body
  ⎿  3 failed
$composer"

# --- 14. what claude draws around the running tool ---------------------------
# Ten todos under the spinner, or fourteen background agents under the
# composer, each push the running tool's own timer far up the screen. Wedged,
# it must still wake; thinking, it still must not.
for extra in TODOS=10 AGENTS=14; do
  export "${extra?}"
  say 'working: running the suite'
  backdate 7300
  T=$(( NOW + 1400000 ))
  pane 20 '1m 3s' '✻' Brewing '⏺'
  sentry "$T"
  pane 20 '1h 0m 12s' '✢' Brewing ' '
  sentry $(( T + 3600 ))
  pane 20 '2h 0m 2s' '✶' Brewing '⏺'
  sentry $(( T + W - 1 ))
  ck_eq  "14 $extra: inside the window, no wake"          "$RC" 4
  sentry $(( T + W ))
  ck_eq  "14 $extra: a frozen transcript wakes"            "$RC" 0
  ck_has "14 $extra: as wedged"                            "$OUT" "wedged: hung has been silent"
  say 'working: running the suite'
  backdate 86400
  T=$(( NOW + 1500000 ))
  fired=no
  for k in $(seq 0 12); do
    pane $(( 20 + k )) "$k""h 0m" '✻' Brewing '⏺'
    sentry $(( T + k * 1800 ))
    [ "$RC" = 0 ] && fired=yes
  done
  ck_eq  "14 $extra: a growing transcript never wakes"     "$fired" no
  ck_eq  "14 $extra: nor reads wedged in the listing"      "$(row $(( T + 12 * 1800 )))" "alive/working"
  unset "${extra%%=*}"
done
# The same two shapes against the normaliser alone, with a todo ticked off as
# the change that must still count.
same() { ck_eq "14 $1" "$(pp "$2")" "$(pp "$3")"; }
differ() { ck_ne "14 $1" "$(pp "$2")" "$(pp "$3")"; }
todos() { local n; printf '  ⎿  %s Fix failure 1\n' "$1"; for n in $(seq 2 10); do printf '     ☐ Fix failure %s\n' "$n"; done; }
same "ten todos do not hide the tool's timers" \
  "$body
⏺ Bash(bash tests/run-all.bash)
  ⎿  Running… (1m 3s · 9 lines)
✻ Brewing… (1m 3s · ↓ 3.1k tokens)
$(todos ☐)
$composer" \
  "$body
  Bash(bash tests/run-all.bash)
  ⎿  Running… (2h 0m 59s · 9 lines)
✶ Brewing… (2h 0m 59s · ↓ 3.1k tokens)
$(todos ☐)
$composer"
differ "a todo ticked off is a change" \
  "$body
⏺ Bash(bash tests/run-all.bash)
✻ Brewing… (1m 3s)
$(todos ☐)
$composer" \
  "$body
⏺ Bash(bash tests/run-all.bash)
✻ Brewing… (1m 3s)
$(todos ☒)
$composer"
agents() { local n; for n in $(seq 1 16); do printf '  ⏺ scout-%s · %s tool uses · %s\n' "$n" "$1" "$2"; done; }
same "a tall agent panel under the composer is chrome" \
  "$body
⏺ Bash(bash tests/run-all.bash)
  ⎿  Running… (1m 3s)
✻ Brewing… (1m 3s)
$composer
$(agents 3 '1m 3s')" \
  "$body
⏺ Bash(bash tests/run-all.bash)
  ⎿  Running… (2h 0m 59s)
✻ Brewing… (2h 0m 59s)
$composer
$(agents 41 '2h 0m 59s')"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
