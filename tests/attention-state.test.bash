#!/usr/bin/env bash
# A hand suspended at a permission dialog reports nothing, because it is stopped
# inside a tool call: no status line is ever written, the session stays healthy
# by every process measure, and the household reads that silence as progress. It
# happened. Only a screenshot revealed it.
#
# Two things are covered here, and they are the two halves of the fix:
#   1. the mapping from what a backend can see to one of four words, including
#      the case that caused the incident, where a dialog painted over the whole
#      screen leaves the agent looking exactly like one that finished its turn
#   2. the sentry's dwell and its per errand latch, so a stall is a wake once and
#      a hand between two tool calls is not a wake at all
#
# The mapping cases use documents of the shape `herdr agent explain --json`
# returns, not a live server, so this suite is green on a machine with no herdr.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output should not have said [$3]" ;; *) ok "$1" ;; esac; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-attention-test.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

# --- 1. the mapping, herdr -------------------------------------------------
# Field by field, these are what the scout measured on one pane in four
# conditions. The two that matter most are the last pair: idle with a composer on
# screen is a hand that finished its turn, idle WITHOUT one is a hand with a
# dialog over the top of it, and no single native field tells them apart.

# shellcheck disable=SC1091
. "$ROOT/backends/herdr.sh"

explain() { # explain <state> <live_prompt_box matched: true|false|absent>
  local st=$1 box=$2 rules=''
  case $box in
    absent) rules='{"id":"osc_title_working","matched":false,"priority":1100}' ;;
    *)      rules='{"id":"osc_title_working","matched":false,"priority":1100},
                   {"id":"live_prompt_box","matched":'"$box"',"priority":950}' ;;
  esac
  printf '{"state":"%s","evaluated_rules":[%s]}\n' "$st" "$rules"
}

if ! command -v jq >/dev/null 2>&1; then
  SKIP=$((SKIP+1))
  printf 'skip  the herdr mapping needs jq, which this backend requires anyway\n'
else
  m() { ck_eq "1 $1" "$(_h_attn_from_explain "$(explain "$2" "$3")")" "$4"; }
  m "a working pane is working"                       working true    working
  m "and working with no composer is still working"   working false   working
  m "a visible blocker is waiting (class A)"          blocked false   waiting
  m "THE INCIDENT: idle with no composer is waiting"  idle    false   waiting
  m "and done with no composer too, since it latches" done    false   waiting
  m "idle at its composer is settled, not a stall"    idle    true    settled
  m "done at its composer likewise"                   done    true    settled
  m "a state this household does not know is unknown" nonsense false  unknown
  m "an absent rule is read as not matched"           idle    absent  waiting
  ck_eq "1 an empty document is unknown, never a guess" "$(_h_attn_from_explain '')" unknown
  ck_eq "1 so is one that is not json at all"          "$(_h_attn_from_explain 'herdr: no running session')" unknown
fi

# --- 2. the mapping, tmux text fallback ------------------------------------
# Under tmux there is nothing to ask but the text, so this half runs on captures.
# The AND is the whole test: a hand writing ABOUT permission prompts has the
# footer in its scrollback and its composer still on screen underneath.

# shellcheck disable=SC1091
. "$ROOT/backends/tmux.sh"

t_dialog=$(cat <<'X'
  Bash(python3 -c "print(6*7)")
 ─────────────────────────────────────────────
  Do you want to proceed?
  ❯ 1. Yes
    2. No, and tell Claude what to do differently (esc to cancel)
 ─────────────────────────────────────────────
X
)
t_quoting=$(cat <<'X'
  I am writing about permission prompts. One reads:
    2. No, and tell Claude what to do differently (esc to cancel)
 ─────────────────────────────────────────────
  ❯
 ─────────────────────────────────────────────
  esc to interrupt
X
)
t_composer=$(cat <<'X'
  ⏺ Done. The branch is ready.
 ─────────────────────────────────────────────
  ❯
 ─────────────────────────────────────────────
X
)
ck_eq "2 a dialog with no composer is waiting"        "$(_t_attn_from_text "$t_dialog")"   waiting
ck_eq "2 a hand QUOTING a prompt is not waiting"      "$(_t_attn_from_text "$t_quoting")"  unknown
ck_eq "2 an idle composer is not waiting"             "$(_t_attn_from_text "$t_composer")" unknown
ck_eq "2 nothing captured is unknown"                 "$(_t_attn_from_text '')"            unknown

# --- 3. the sentry: dwell, latch, and what must stay quiet -----------------
# A stub backend, in a scratch REEVE_ROOT, so the sentry's arithmetic is tested
# rather than herdr's. The word it reports is whatever is in $ATTN, which the
# cases below rewrite as if the session had changed.

export REEVE_ROOT="$SCRATCH/root"
export REEVE_HOME="$SCRATCH/home"
mkdir -p "$REEVE_ROOT/backends" "$REEVE_HOME/state" "$REEVE_HOME/errands/stalled"
ATTN="$SCRATCH/attn.word"
cat > "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { echo 'stub'; }
reeve_backend_stub_agent_state()     { echo alive; }
reeve_backend_stub_attention_state() { cat "$STUB_ATTN"; }
reeve_backend_stub_wait_change()     { return 2; }
STUB
export STUB_ATTN="$ATTN"

printf 'target=s|s:p1\nbackend=stub\noffice=artificer\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=yes\n' \
  > "$REEVE_HOME/state/stalled.meta"
printf 'working: reading the auth module\n' > "$REEVE_HOME/errands/stalled/status"

attn_state=$REEVE_HOME/state/.attn-stalled
# Frozen once, not re-read per call: the dwell boundary in 3b/3c is asserted at
# the exact second, and a wall clock that keeps ticking while the test harness
# does its own work (writing files, forking sentry) can cross that edge between
# a backdate and the sentry call that checks it. REEVE_ATTN_NOW pins the sentry
# process to this same instant so the elapsed time is exactly what backdate
# wrote, never more.
NOW=$(date +%s)
sentry() { OUT=$(REEVE_ATTN_NOW=$NOW "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?; }
backdate() { # backdate <seconds ago>
  local woke; woke=$(cut -d' ' -f2 "$attn_state" 2>/dev/null); woke=${woke:-no}
  printf '%s %s\n' "$(( NOW - $1 ))" "$woke" > "$attn_state"
}
seen() { [ -f "$attn_state" ] && printf 'present\n' || printf 'absent\n'; }

# 3a. the dwell. A reading taken in the instant between two tool calls must not
#     wake anybody, so the first sighting only starts the clock.
printf 'waiting\n' > "$ATTN"
sentry
ck_eq  "3a first sighting does not wake"          "$RC" 4
ck_eq  "3a but it does start the clock"           "$(seen)" present
sentry
ck_eq  "3a nor does the second, seconds later"    "$RC" 4

# 3b. held past the dwell, it is a wake. 89 seconds is not yet, 90 is, and the
#     boundary is asserted because a dwell nobody can predict is not a rule.
backdate 89
sentry
ck_eq  "3b 89 seconds is not long enough"         "$RC" 4
backdate 90
sentry
ck_eq  "3b 90 seconds is"                         "$RC" 0
ck_has "3b it says what the errand is doing"      "$OUT" "stalled is waiting for an answer in its session"
ck_has "3b and quotes what it last reported"      "$OUT" "reading the auth module"

# 3c. one stall, one wake. The dialog stands until a human answers it, so the
#     condition is still true on every later poll: without the latch the reeve is
#     woken every fifteen seconds for something already reported.
sentry
ck_eq  "3c the same stall does not wake twice"    "$RC" 4
backdate 900
sentry
ck_eq  "3c not even much later"                   "$RC" 4

# 3d. answered, then stalled again, is a second wake. The latch has to clear
#     when the session leaves `waiting`, or the second dialog is invisible.
printf 'working\n' > "$ATTN"
sentry
ck_eq  "3d back to work is quiet"                 "$RC" 4
ck_eq  "3d and the clock is cleared"              "$(seen)" absent
printf 'waiting\n' > "$ATTN"
sentry; backdate 90; sentry
ck_eq  "3d a second stall wakes again"            "$RC" 0

# 3e. the counterfactuals. Both of these are what a hand looks like when nothing
#     is wrong, and either one reported as a stall would be worse than the hole:
#     a supervisor that cries wolf on every finished turn gets ignored.
printf 'settled\n' > "$ATTN"
sentry
ck_eq  "3e a hand at its composer is quiet"       "$RC" 4
ck_eq  "3e and leaves no clock behind"            "$(seen)" absent
printf 'unknown\n' > "$ATTN"
sentry
ck_eq  "3e a backend that cannot tell is quiet"   "$RC" 4

# 3f. only `working` is policed. Every other reported state is either already
#     escalated or already the liege's, so re-reporting it as a stall would turn
#     one blocked hand into a wake per poll. The cursor is pre-set so the blocked
#     line itself is already absorbed, which is the state a second poll is in.
printf 'waiting\n' > "$ATTN"
printf 'working: reading the auth module\nblocked: pnpm install fails, no .env present\n' \
  > "$REEVE_HOME/errands/stalled/status"
printf '2\n' > "$REEVE_HOME/state/.cursor-stalled"
sentry
ck_eq  "3f a blocked hand is not woken for again"  "$RC" 4
ck_not "3f and not described as waiting"           "$OUT" "waiting for an answer"
ck_eq  "3f no clock is kept for it"                "$(seen)" absent

# 3g. the dwell is configurable only so this suite can drive it, but the zero
#     case also proves the arithmetic runs on a real clock rather than on the
#     backdating above.
printf 'working: reading the auth module\n' > "$REEVE_HOME/errands/stalled/status"
printf '1\n' > "$REEVE_HOME/state/.cursor-stalled"
rm -f "$attn_state"
OUT=$(REEVE_ATTN_DWELL=0 "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
ck_eq  "3g a zero dwell wakes on first sighting"   "$RC" 0
ck_has "3g with the same line"                     "$OUT" "waiting for an answer in its session"

# --- 4. the spin -----------------------------------------------------------
# Measured, not asserted here: a backend whose native wait returns instantly and
# forever (herdr's does, because `blocked` and `done` are latched) cost the
# watcher 12.74s of CPU per 11.68s of wall clock. This asserts the guard that
# replaced it: the sleep is owed unless the wait actually spent time. A stub that
# returns 0 instantly is exactly the pathological case.
cat >> "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_wait_change() { return 0; }
STUB
printf 'settled\n' > "$ATTN"
t0=$(date +%s)
"$ROOT/bin/reeve-sentry" --poll 3 --timeout 1 --no-reap >/dev/null 2>&1
elapsed=$(( $(date +%s) - t0 ))
if [ "$elapsed" -ge 3 ]; then
  ok "4 an instant native wait is still followed by a sleep"
else
  bad "4 an instant native wait is still followed by a sleep" \
      "the loop went round in ${elapsed}s with a poll of 3s, which is the spin"
fi

echo
echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ]
