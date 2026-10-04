#!/usr/bin/env bash
# bin/reeve-steer, against a stub backend so no terminal is involved. That a
# steer re-arms the idle alarm is case 19 of stale-watch.test.bash, beside the
# alarm it re-arms. Covered here, what it refuses and what it never touches:
#   1. a steer is delivered verbatim, and re-arms with or without a latch
#   2. an unknown, finished, failed or cleaned up errand is refused
#   3. a session that is gone, or was never there, is refused
#   4. a session standing at a dialog, or one that cannot be told from one, is
#      refused, and nothing is typed into it
#   5. a send that fails clears nothing
#   6. a latch that cannot be cleared is said, and the delivery still counts
#   7. it never writes the status file
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]: $2" ;; esac; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-steer-test.XXXXXX") || exit 1
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

unset CLAUDE_CODE_SESSION_ID
export REEVE_SESSION=''
export REEVE_ROOT="$SCRATCH/root"
export REEVE_HOME="$SCRATCH/home"
mkdir -p "$REEVE_ROOT/backends" "$REEVE_HOME/state" "$REEVE_HOME/errands/hung"

export STUB_ATTN="$SCRATCH/attn" STUB_ACTS="$SCRATCH/acts" STUB_LIVE="$SCRATCH/live" STUB_SENDFAIL="$SCRATCH/sendfail" STUB_ATTNFAIL="$SCRATCH/attnfail"
cat > "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()        { return 0; }
reeve_backend_stub_describe()         { echo stub; }
reeve_backend_stub_agent_state()      { cat "$STUB_LIVE" 2>/dev/null || echo alive; }
reeve_backend_stub_attention_state()  { [ -f "$STUB_ATTNFAIL" ] && { echo settled; return 1; }; cat "$STUB_ATTN"; }
reeve_backend_stub_send_text_submit() {
  [ -f "$STUB_SENDFAIL" ] && return 1
  printf 'send %s\n' "$*" >> "$STUB_ACTS"
}
STUB

META="$REEVE_HOME/state/hung.meta"
STATUS="$REEVE_HOME/errands/hung/status"
LATCH="$REEVE_HOME/state/.stale-hung"
STEERED="$REEVE_HOME/state/.steered-hung"
fresh() { # fresh [status lines...]   a live idle hand, a reported silence, an empty log of sends
  printf 'target=s|s:p1\nbackend=stub\noffice=artificer\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=yes\ndispatched=2026-10-01T21:30:00\n' > "$META"
  if [ $# -gt 0 ]; then printf '%s\n' "$@" > "$STATUS"; else printf 'working: rewriting the parser\n' > "$STATUS"; fi
  printf '1 1 1 yes\n' > "$LATCH"
  rm -f "$STEERED"
  printf 'settled\n' > "$STUB_ATTN"
  rm -f "$STUB_LIVE" "$STUB_SENDFAIL"; : > "$STUB_ACTS"
}
steer() { OUT=$("$ROOT/bin/reeve-steer" "$@" 2>&1); RC=$?; }
sent()    { cat "$STUB_ACTS"; }
latched() { [ -f "$LATCH" ] && echo kept || echo gone; }

# --- 1. delivered ----------------------------------------------------------
fresh
steer hung 'carry on with your brief: the parser, then the tests'
ck_eq  "1 a steer to a live idle hand succeeds"            "$RC" 0
ck_eq  "1 the text arrives verbatim, submitted"            "$(sent)" "send s|s:p1 carry on with your brief: the parser, then the tests"
ck_has "1 it says where"                                   "$OUT" "delivered to the hand at s|s:p1"
ck_eq  "1 the latch is cleared"                            "$(latched)" gone
ck_eq  "1 and the steer's time recorded"                   "$(fresh; REEVE_ATTN_NOW=1790000000 "$ROOT/bin/reeve-steer" hung go >/dev/null 2>&1; cat "$STEERED")" 1790000000
ck_eq  "1 one fact per line, two lines"                    "$(printf '%s\n' "$OUT" | grep -c .)" 2
steer hung 'and again'
ck_eq  "1 a missing latch is no obstacle"                  "$RC" 0
ck_has "1 and it still says it is armed"                   "$OUT" "idle alarm re-armed"
fresh 'working: rewriting the parser' 'blocked: no .env present'
steer hung 'the .env is in place now'
ck_eq  "1 a blocked hand can be steered"                   "$RC" 0
printf 'working\n' > "$STUB_ATTN"; : > "$STUB_ACTS"
steer hung 'also update the changelog'
ck_eq  "1 so can a working one"                            "$RC" 0

# --- 2. nothing to steer ---------------------------------------------------
fresh
steer nosuch 'carry on'
ck_eq  "2 an unknown errand is refused"                    "$RC" 1
ck_has "2 by name"                                         "$OUT" "no errand 'nosuch'"
steer 'Bad_Id' 'carry on'
ck_eq  "2 a malformed id is refused"                       "$RC" 1
steer hung
ck_eq  "2 no text is refused"                              "$RC" 1
ck_has "2 with the usage"                                  "$OUT" "bin/reeve-steer hung <text>"
for c in 'done: parser rewritten' 'failed: cannot build'; do
  fresh 'working: rewriting the parser' "$c"
  steer hung 'carry on'
  ck_eq  "2 a ${c%%:*} errand is refused"                  "$RC" 1
  ck_has "2 and says it reported ${c%%:*}"                 "$OUT" "reported ${c%%:*}"
  ck_eq  "2 nothing was sent to a ${c%%:*} errand"         "$(sent)" ""
  ck_eq  "2 nor its latch cleared"                         "$(latched)" kept
done
fresh
printf 'tornDown=2026-10-02T10:00:00\n' >> "$META"
steer hung 'carry on'
ck_eq  "2 a cleaned up errand is refused"                  "$RC" 1
ck_has "2 and says so"                                     "$OUT" "was cleaned up"
ck_eq  "2 nothing was sent to it"                          "$(sent)" ""

# --- 3. no session ---------------------------------------------------------
for s in dead missing unreadable; do
  fresh
  printf '%s\n' "$s" > "$STUB_LIVE"
  steer hung 'carry on'
  ck_eq  "3 a $s session is refused"                       "$RC" 1
  ck_has "3 and the refusal names it"                      "$OUT" "the hand is $s"
  ck_eq  "3 nothing was sent to a $s session"              "$(sent)" ""
  ck_eq  "3 nor the latch cleared"                         "$(latched)" kept
done
fresh
sed -i.bak 's/^target=.*/target=/' "$META"; rm -f "$META.bak"
steer hung 'carry on'
ck_eq  "3 a freed session is refused"                      "$RC" 1
ck_has "3 and says there is no session"                    "$OUT" "has no session to steer"

# --- 4. a dialog -----------------------------------------------------------
# Hard rule 7: a dialog is denied or brought to the liege, never cleared by
# whatever text happens to land in it.
fresh
printf 'waiting\n' > "$STUB_ATTN"
steer hung 'yes'
ck_eq  "4 a session at a dialog is refused"                "$RC" 1
ck_has "4 and says why"                                    "$OUT" "waiting at a dialog"
ck_has "4 and what to do instead"                          "$OUT" "bring it to the liege"
ck_eq  "4 nothing was typed into it"                       "$(sent)" ""
ck_eq  "4 nor the latch cleared"                           "$(latched)" kept

# A session that cannot be told from one at a dialog is refused the same way:
# an unverified harness answers `unknown` whatever is on the screen, and hard rule 7 is not broken on a guess. So is a probe that
# failed, whatever it printed, and one that printed nothing.
for a in unknown error empty; do
  fresh
  case $a in
    unknown) printf 'unknown\n' > "$STUB_ATTN" ;;
    error)   touch "$STUB_ATTNFAIL" ;;
    empty)   : > "$STUB_ATTN" ;;
  esac
  steer hung 'yes'
  rm -f "$STUB_ATTNFAIL"
  ck_eq  "4 attention $a is refused"                       "$RC" 1
  ck_has "4 and says it cannot tell"                       "$OUT" "cannot tell whether the hand at s|s:p1 is at a dialog"
  ck_has "4 and what to do instead"                        "$OUT" "Look at the session yourself"
  ck_eq  "4 nothing was typed into it"                     "$(sent)" ""
  ck_eq  "4 nor the latch cleared"                         "$(latched)" kept
  ck_eq  "4 nor the steer recorded"                        "$([ -f "$STEERED" ] && echo kept || echo gone)" gone
done
ck_has "4 an answer is named"                              "$(fresh; printf 'unknown\n' > "$STUB_ATTN"; "$ROOT/bin/reeve-steer" hung yes 2>&1)" "answered unknown"

# --- 5. a send that fails ---------------------------------------------------
fresh
touch "$STUB_SENDFAIL"
steer hung 'carry on'
ck_eq  "5 a failed send fails"                             "$RC" 1
ck_has "5 and says nothing was cleared"                    "$OUT" "nothing was cleared"
ck_eq  "5 and the latch is still there"                    "$(latched)" kept
ck_eq  "5 untouched"                                       "$(cat "$LATCH")" "1 1 1 yes"
ck_eq  "5 and no steer recorded"                           "$([ -f "$STEERED" ] && echo kept || echo gone)" gone

# --- 6. a latch that cannot be cleared --------------------------------------
fresh
chmod a-w "$REEVE_HOME/state"
steer hung 'carry on'
chmod u+w "$REEVE_HOME/state"
ck_eq  "6 the delivery still counts"                       "$RC" 0
ck_eq  "6 it was sent once"                                "$(sent | grep -c .)" 1
ck_has "6 the failed clear is said"                        "$OUT" "cannot clear $LATCH"
ck_has "6 with what it costs"                              "$OUT" "no second idle wake will come"
ck_has "6 as is the steer's time it could not record"      "$OUT" "cannot write $STEERED"
ck_eq  "6 on stderr, stdout keeps the one delivery line"   \
  "$(fresh; chmod a-w "$REEVE_HOME/state"; "$ROOT/bin/reeve-steer" hung 'carry on' 2>/dev/null; chmod u+w "$REEVE_HOME/state")" \
  "delivered to the hand at s|s:p1"

# --- 7. the status file is the hand's ----------------------------------------
fresh
before=$(cat "$STATUS")
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
touch -t 200001010000 "$STATUS"; mbefore=$(mtime "$STATUS")
steer hung 'carry on'
printf 'waiting\n' > "$STUB_ATTN"; steer hung 'yes'
ck_eq  "7 the status file is unchanged"                    "$(cat "$STATUS")" "$before"
ck_eq  "7 not even its mtime"                              "$(mtime "$STATUS")" "$mbefore"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
