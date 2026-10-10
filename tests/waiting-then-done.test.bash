#!/usr/bin/env bash
# The liege's sequence: a hand stalls at a permission dialog, the watch wakes the
# reeve with `waiting`, the liege answers the dialog by hand in the hand's own
# session, the hand gets on with it and reports `done:`. The reeve never heard.
#
# Reproduced against a stub backend, and the code was not what lost it: every
# later watch delivered the `done:`, whether that watch was running at the moment
# of the done or started afterwards from the caretaker's spool. There was no
# later watch. A `waiting` wake ends the watch like every wake, and the liege's
# answer is typed into the hand's session, not to the reeve, so the reeve got no
# turn to start the next one on. So these cases pin two things:
#
#   1. the wake line itself says the watch has ended and must be run again, the
#      one part of this that was missing
#   2. the sequence end to end: a watch started again while the dialog stands is
#      quiet, the listing stops saying waiting once the dialog goes, the answer
#      itself wakes nobody, and every way the hand can then report reaches the
#      next watch as an ordinary wake, with and without a watch running at the
#      time
#   3. a second dialog after the first was answered wakes again once the hand
#      reported a line between, even when no poll ever saw it working
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3], got [$2]" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output should not have said [$3]" ;; *) ok "$1" ;; esac; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-waiting-done-test.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

# A stub backend whose attention word is whatever $STUB_ATTN holds, so a case can
# answer the dialog by rewriting one file. Its native wait runs $STUB_STEP, when
# there is one, so a single long watch can be walked through the whole sequence
# from inside its own loop.
export REEVE_ROOT="$SCRATCH/root"
export REEVE_SESSION=reeve-a
export STUB_ATTN="$SCRATCH/attn.word" STUB_WAITS="$SCRATCH/waits"
mkdir -p "$REEVE_ROOT/backends"
cat > "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { echo 'stub'; }
reeve_backend_stub_agent_state()     { echo alive; }
reeve_backend_stub_attention_state() { cat "$STUB_ATTN"; }
reeve_backend_stub_wait_change() {
  [ -n "${STUB_STEP:-}" ] || return 2
  printf 'w\n' >> "$STUB_WAITS"
  "$STUB_STEP" "$(awk 'END{print NR}' "$STUB_WAITS")"
  return 0
}
STUB

# fresh <home>: one scout out, owned by this reeve, its last word `working:`. A
# scout so a reaped one leaves nothing behind for teardown to refuse over.
fresh() {
  export REEVE_HOME="$SCRATCH/$1"
  mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/errands/hand"
  printf 'target=s|s:p1\nbackend=stub\noffice=scout\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=no\nsession=%s\ndispatched=2026-10-10T00:00:00\n' \
    "$REEVE_SESSION" > "$REEVE_HOME/state/hand.meta"
  printf 'working: reading the upload path\n' > "$REEVE_HOME/errands/hand/status"
  printf 'waiting\n' > "$STUB_ATTN"
}
report() { printf '%s\n' "$1" >> "$REEVE_HOME/errands/hand/status"; }
# A zero dwell, so the first sighting of the dialog is the wake.
sentry() { OUT=$(REEVE_ATTN_DWELL=0 "$ROOT/bin/reeve-sentry" "$@" 2>&1); RC=$?; }
row()    { "$ROOT/bin/reeve-status" --no-wake 2>&1 | awk '$1 == "hand"'; }
one()    { "$ROOT/bin/reeve-status" hand 2>&1; }

# --- 1. the wake line says the watch is over --------------------------------
fresh h1
sentry --once
ck_eq  "1 the dialog wakes the reeve"                    "$RC" 0
ck_has "1 as waiting"                                    "$OUT" "hand is waiting for an answer in its session"
ck_has "1 quoting what it last said"                     "$OUT" "reading the upload path"
ck_has "1 and saying this watch has ended"               "$OUT" "This watch has ended"
ck_has "1 and what to run so the done is not lost"       "$OUT" "run reeve-sentry again now"
ck_eq  "1 still one line"                                "$(printf '%s\n' "$OUT" | grep -c .)" 1

# --- 2. step by step, a watch started again at each stage --------------------
# 2a. started again at once, while the dialog still stands: quiet, because that
#     one stall has already woken it. Otherwise the advice above is a loop.
sentry --once
ck_eq  "2a the re-armed watch is quiet over the same dialog" "$RC" 4
ck_has "2a the listing says waiting while it stands"         "$(row)" "alive/waiting"

# 2b. the liege answers it in the session. Nothing anywhere says waiting any
#     more, read before any watch has looked, since the latch that watch left
#     behind is still on disk then. And the hand working again is progress, which
#     wakes nobody.
printf 'working\n' > "$STUB_ATTN"
ck_has "2b the listing shows it working again"           "$(row)" "alive/working"
ck_not "2b and no longer waiting"                        "$(row)" "waiting"
ck_not "2b nor does the single errand view"              "$(one)" "waiting"
sentry --once
ck_eq  "2b the answer itself wakes nobody"               "$RC" 4

# 2c. and its done reaches the next watch as an ordinary done.
report 'working: retry path traced'
report 'done: retry swallows the error, report.md written'
printf 'settled\n' > "$STUB_ATTN"
sentry --once
ck_eq  "2c the done wakes the next watch"                "$RC" 0
ck_has "2c as an ordinary done"                          "$OUT" "signal: hand is done - retry swallows the error"
ck_has "2c and the finished hand is cleaned up"          "$OUT" "session freed"
sentry --once
ck_eq  "2c once, not again"                              "$RC" 3

# --- 3. one watch, started again after the wake, running throughout ---------
# The shape the advice produces: the reeve runs the watch again at once and it is
# still running when the liege answers and when the hand reports. Walked from
# inside its own loop, so the dialog clears and the done lands between polls of
# one process, never between two.
step3() {
  case $1 in
    2) printf 'working\n' > "$STUB_ATTN" ;;
    4) printf 'done: retry swallows the error\n' >> "$REEVE_HOME/errands/hand/status"
       printf 'settled\n' > "$STUB_ATTN" ;;
    9) printf 'tornDown=yes\n' >> "$REEVE_HOME/state/hand.meta" ;;
  esac
}
export -f step3
fresh h3
sentry --once
ck_eq  "3 the dialog wakes the first watch"              "$RC" 0
: > "$STUB_WAITS"
OUT=$(STUB_STEP=step3 REEVE_SENTRY_SLEEPS="$SCRATCH/sleeps3" REEVE_ATTN_DWELL=0 \
      "$ROOT/bin/reeve-sentry" --poll 1 2>&1); RC=$?
ck_eq  "3 the second watch wakes, rather than running dry" "$RC" 0
ck_has "3 for the done"                                  "$OUT" "signal: hand is done - retry swallows the error"
ck_not "3 never for the dialog it already reported"      "$OUT" "waiting for an answer"
ck_eq  "3 and only after the answer and the done"        "$(awk 'END{print NR}' "$STUB_WAITS")" 4

# --- 4. no watch running at the moment the hand reports ----------------------
# Every way a hand can report after the dialog, each to the next watch started
# afterwards, with no watch at all between the wake and the report: so the
# dialog's latch, written `yes` by the wake, is still on disk when it is read.
for st in done failed blocked 'needs-decision [key=scope]'; do
  fresh "h4-${st%% *}"
  sentry --once
  printf 'working\n' > "$STUB_ATTN"
  report "$st: what the hand said"
  printf 'settled\n' > "$STUB_ATTN"
  sentry --once
  ck_eq  "4 ${st%% *} after the dialog wakes the next watch" "$RC" 0
  ck_has "4 ${st%% *} as an ordinary signal"                 "$OUT" "signal: hand "
  ck_not "4 ${st%% *} never as the old dialog"               "$OUT" "waiting for an answer"
done

# --- 5. the caretaker took it while nobody watched ---------------------------
# The liege's case exactly: the watch ended on the wake, nothing started another,
# and the hand finished. The caretaker frees it and leaves the line for the
# reeve, and the next watch says it.
for st in done failed; do
  fresh "h5-$st"
  sentry --once
  printf 'working\n' > "$STUB_ATTN"
  report "$st: what the hand said"
  printf 'settled\n' > "$STUB_ATTN"
  REEVE_SENTRY_SLEEPS="$SCRATCH/sleeps5" "$ROOT/bin/reeve-sentry" --caretaker --poll 1 >/dev/null 2>&1
  ck_eq  "5 $st: the caretaker cleaned the hand up"        "$(grep -c '^tornDown=' "$REEVE_HOME/state/hand.meta")" 1
  sentry --once
  ck_eq  "5 $st: the next watch still wakes for it"        "$RC" 0
  ck_has "5 $st: with what the hand reported"              "$OUT" "hand is $st and its session was cleaned up with no reeve watching - what the hand said"
  sentry --once
  ck_eq  "5 $st: once, not again"                          "$RC" 3
done

# --- 6. answered, reported, stalled again before any poll saw it working -----
# The latch from the first wake is still on disk, `yes`, because nothing deleted
# it: every poll that looked saw `waiting`. The line the hand reported between is
# what tells the two dialogs apart.
fresh h6
sentry --once
ck_eq  "6 the first dialog wakes the reeve"              "$RC" 0
report 'working: step two'
sentry --once
ck_eq  "6 the second dialog wakes the next watch"        "$RC" 0
ck_has "6 as waiting"                                    "$OUT" "hand is waiting for an answer in its session"
ck_has "6 quoting the line reported between"             "$OUT" "step two"
sentry --once
ck_eq  "6 and that second stall wakes once, not again"   "$RC" 4

# 6b. the same with a dwell: the reported line starts a fresh one rather than
#     waking on the old dialog's clock.
fresh h6b
sentry --once
report 'working: step two'
OUT=$(REEVE_ATTN_DWELL=3600 "$ROOT/bin/reeve-sentry" --once 2>&1); RC=$?
ck_eq  "6b inside a fresh dwell the second dialog is quiet" "$RC" 4
read -r _ w6b _ < "$REEVE_HOME/state/.attn-hand"
ck_eq  "6b its latch is re-armed"                        "$w6b" no

# 6c. a latch written before it carried a count reads as it always did: that
#     dialog has woken, and it stays quiet.
fresh h6c
printf '%s yes\n' "$(date +%s)" > "$REEVE_HOME/state/.attn-hand"
report 'working: step two'
sentry --once
ck_eq  "6c an old two-field latch still keeps it quiet"  "$RC" 4

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
