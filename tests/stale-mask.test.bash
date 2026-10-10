#!/usr/bin/env bash
# One errand whose session is gone, left in flight (an artificer's pane died
# after it committed, so its unlanded branch keeps it there), and a sibling still
# working. The watch stops at the first errand with something to say, and
# `stale:` used to be said on every poll of every watch, so the sibling's `done:`
# never reached the reeve for as long as the gone one stood. Reproduced with
# this stub before the fix: four watches in a row, each only the stale line,
# two of them after the sibling reported done.
#
# So these cases pin:
#
#   1. the gone session is still reported, the first time
#   2. once, not on every watch, so the sibling's done reaches the next watch
#   3. the same within one long watch, with the done landing between polls
#   4. never reaped, and the listing still shows it gone
#   5. a new episode wakes again: the session came back and went, or the hand
#      reported a line since
#   6. a terminal line ends the episode
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

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-stale-mask-test.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

# A stub backend with two hands: aaa's session is whatever $STUB_GONE holds,
# bbb's is alive with the attention word in $STUB_ATTN. Its native wait runs
# $STUB_STEP, when there is one, so one long watch can be walked from inside its
# own loop.
export REEVE_ROOT="$SCRATCH/root"
export REEVE_SESSION=reeve-a
export STUB_GONE="$SCRATCH/gone.word" STUB_ATTN="$SCRATCH/attn.word" STUB_WAITS="$SCRATCH/waits"
mkdir -p "$REEVE_ROOT/backends"
cat > "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { echo 'stub'; }
reeve_backend_stub_agent_state() {
  case $1 in *aaa) cat "$STUB_GONE" ;; *) echo alive ;; esac
}
reeve_backend_stub_attention_state() {
  case $1 in *aaa) echo unknown ;; *) cat "$STUB_ATTN" ;; esac
}
reeve_backend_stub_wait_change() {
  [ -n "${STUB_STEP:-}" ] || return 2
  printf 'w\n' >> "$STUB_WAITS"
  "$STUB_STEP" "$(awk 'END{print NR}' "$STUB_WAITS")"
  return 0
}
STUB

# hand <id> <office>: one errand out, owned by this reeve, its last word
# `working:`. aaa an artificer, as in the case that stays in flight; bbb a scout,
# so a reaped one leaves nothing behind for cleanup to refuse over.
hand() {
  mkdir -p "$REEVE_HOME/errands/$1"
  printf 'target=s|s:%s\nbackend=stub\noffice=%s\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=no\nsession=%s\ndispatched=2026-10-10T00:00:00\n' \
    "$1" "$2" "$REEVE_SESSION" > "$REEVE_HOME/state/$1.meta"
  printf 'working: %s started\n' "$1" > "$REEVE_HOME/errands/$1/status"
}
fresh() {
  export REEVE_HOME="$SCRATCH/$1"
  mkdir -p "$REEVE_HOME/state"
  hand aaa artificer; hand bbb scout
  printf 'missing\n' > "$STUB_GONE"
  printf 'working\n' > "$STUB_ATTN"
}
report() { printf '%s\n' "$2" >> "$REEVE_HOME/errands/$1/status"; }
sentry() { OUT=$(REEVE_ATTN_DWELL=0 "$ROOT/bin/reeve-sentry" "$@" 2>&1); RC=$?; }
row()    { "$ROOT/bin/reeve-status" --no-wake 2>&1 | awk -v id="$1" '$1 == id'; }
LATCH() { printf '%s/state/.gone-aaa' "$REEVE_HOME"; }

# --- 1. the gone session is still reported, the first time ------------------
fresh h1
sentry --once
ck_eq  "1 the gone session wakes the reeve"               "$RC" 0
ck_has "1 as stale"                                       "$OUT" "stale: aaa left no result and its session is missing"
ck_eq  "1 one line"                                       "$(printf '%s\n' "$OUT" | grep -c .)" 1
ck_eq  "1 and the gone latch records it"                  "$([ -f "$(LATCH)" ] && echo kept || echo gone)" kept

# --- 2. once, so the sibling reaches the next watch --------------------------
sentry --once
ck_eq  "2 the next watch is quiet over the same gone session" "$RC" 4
ck_not "2 and does not repeat it"                         "$OUT" "stale: aaa"
report bbb 'done: report.md written'
printf 'settled\n' > "$STUB_ATTN"
sentry --once
ck_eq  "2 the sibling's done wakes the next watch"        "$RC" 0
ck_has "2 as an ordinary done"                            "$OUT" "signal: bbb is done - report.md written"
ck_not "2 not masked by the gone one"                     "$OUT" "stale: aaa"
sentry --once
ck_eq  "2 then quiet, aaa still in flight"                "$RC" 4

# 2b. the sibling stalls at a dialog instead: that reaches the next watch too.
fresh h2b
sentry --once
printf 'waiting\n' > "$STUB_ATTN"
sentry --once
ck_eq  "2b a sibling's dialog wakes the next watch"       "$RC" 0
ck_has "2b as waiting"                                    "$OUT" "bbb is waiting for an answer in its session"

# --- 3. one long watch, the done landing between polls -----------------------
step3() {
  case $1 in
    2) printf 'done: report.md written\n' >> "$REEVE_HOME/errands/bbb/status"
       printf 'settled\n' > "$STUB_ATTN" ;;
    9) printf 'tornDown=yes\n' >> "$REEVE_HOME/state/aaa.meta" ;;
  esac
}
export -f step3
fresh h3
sentry --once
: > "$STUB_WAITS"
OUT=$(STUB_STEP=step3 REEVE_SENTRY_SLEEPS="$SCRATCH/sleeps3" REEVE_ATTN_DWELL=0 \
      "$ROOT/bin/reeve-sentry" --poll 1 2>&1); RC=$?
ck_eq  "3 the running watch wakes for the sibling"        "$RC" 0
ck_has "3 for its done"                                   "$OUT" "signal: bbb is done - report.md written"
ck_not "3 never repeating the gone one"                   "$OUT" "stale: aaa"
ck_eq  "3 and only after the done"                        "$(awk 'END{print NR}' "$STUB_WAITS")" 2

# --- 4. never reaped, and the listing still shows it -------------------------
ck_eq  "4 the gone hand is never cleaned up"              "$(grep -c '^tornDown=' "$REEVE_HOME/state/aaa.meta")" 0
ck_has "4 the listing still shows its session missing"    "$(row aaa)" "missing"

# --- 5. a new episode wakes again --------------------------------------------
# 5a. the session came back, then went again.
fresh h5a
sentry --once
printf 'alive\n' > "$STUB_GONE"
sentry --once
ck_eq  "5a the session back clears the latch"             "$([ -f "$(LATCH)" ] && echo kept || echo gone)" gone
printf 'dead\n' > "$STUB_GONE"
sentry --once
ck_eq  "5a gone again wakes again"                        "$RC" 0
ck_has "5a as stale"                                      "$OUT" "stale: aaa left no result and its session is dead"

# 5b. the hand reported a line since: progress is absorbed, the gone session is
#     said again with it.
fresh h5b
sentry --once
report aaa 'working: one more line'
sentry --once
ck_eq  "5b a line reported since wakes again"             "$RC" 0
ck_has "5b as stale"                                      "$OUT" "stale: aaa"

# 5c. a session that cannot be read ends nothing.
fresh h5c
sentry --once
printf 'unreadable\n' > "$STUB_GONE"
sentry --once
printf 'missing\n' > "$STUB_GONE"
sentry --once
ck_eq  "5c an unreadable poll between does not re-arm it" "$RC" 4

# --- 6. a terminal line ends the episode -------------------------------------
fresh h6
sentry --once
ck_eq  "6 the latch stands before the line"               "$([ -f "$(LATCH)" ] && echo kept || echo gone)" kept
report aaa 'failed: pane died, branch has two commits'
sentry --once
ck_eq  "6 the terminal line wakes the reeve"              "$RC" 0
ck_has "6 as an ordinary failure"                         "$OUT" "signal: aaa failed - pane died"
ck_eq  "6 and the latch is gone"                          "$([ -f "$(LATCH)" ] && echo kept || echo gone)" gone

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
