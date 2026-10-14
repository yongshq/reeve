#!/usr/bin/env bash
# An errand keeps the backend it went out on, whatever the caller's own
# environment says. A reeve inside hall carries REEVE_BACKEND=hall, and may
# still status, watch, steer and clean up an errand that went out on herdr, one
# of its own from before or an orphan it adopted: every one of those calls goes
# to herdr, because the record says so. A record with no backend at all
# predates hall, so it is herdr's too.
#
# The same for a reeve's own pane: pane_gone and pane_vacant ask the backend
# the holder's `place` record names, and herdr for a holder with none, which is
# every record from before hall.
#
# herdr.sh and hall.sh are stubs in a scratch code root that log every call by
# backend, so nothing here touches a real server. Scratch homes only.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }

SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
unset CLAUDE_CODE_SESSION_ID REEVE_SESSION REEVE_NAME REEVE_HAND \
      HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID \
      HALL_ENV HALL_PANE_ID HALL_SOCKET_PATH HALL_TAB_ID HALL_WORKSPACE_ID HALL_BIN_PATH \
      HALL_SESSION HALL_CLIENT_SOCKET_PATH REEVE_HALL_BIN REEVE_HALL_SOCKET REEVE_HALL_SESSION
export REEVE_HOME="$SCRATCH/home"
export REEVE_NO_CARETAKER=1
export REEVE_ATTN_DWELL=0
mkdir -p "$REEVE_HOME/state/sessions" "$REEVE_HOME/config" "$REEVE_HOME/errands"

# A scratch code root: the real bin, two stub backends.
export REEVE_ROOT="$SCRATCH/root"
mkdir -p "$REEVE_ROOT/backends"
ln -s "$ROOT/bin" "$REEVE_ROOT/bin"
export ACTS="$SCRATCH/acts"
for b in herdr hall; do
  cat > "$REEVE_ROOT/backends/$b.sh" <<STUB
reeve_backend_${b}_available()        { return 0; }
reeve_backend_${b}_describe()         { echo $b stub; }
reeve_backend_${b}_create_endpoint()  { echo "$b create_endpoint \$*" >> "\$ACTS"; echo 'w9|w9:p1'; }
reeve_backend_${b}_launch()           { echo "$b launch" >> "\$ACTS"; }
reeve_backend_${b}_capture()          { echo "$b capture \$1" >> "\$ACTS"; echo 'some screen'; }
reeve_backend_${b}_send_text_submit() { echo "$b send_text_submit \$1" >> "\$ACTS"; }
reeve_backend_${b}_target_exists()    { echo "$b target_exists \$1" >> "\$ACTS"; }
reeve_backend_${b}_agent_state()      { echo "$b agent_state \$1" >> "\$ACTS"; echo "\${STUB_LIVE:-alive}"; }
reeve_backend_${b}_attention_state()  { echo "$b attention_state \$1" >> "\$ACTS"; echo working; }
reeve_backend_${b}_wait_change()      { return 2; }
reeve_backend_${b}_kill()             { echo "$b kill \$1" >> "\$ACTS"; }
reeve_backend_${b}_pane_gone()        { echo "$b pane_gone \$*" >> "\$ACTS"; return 1; }
reeve_backend_${b}_pane_vacant()      { echo "$b pane_vacant \$*" >> "\$ACTS"; return 1; }
STUB
done
acts() { cat "$ACTS" 2>/dev/null; }

# Every caller below runs as a reeve inside hall would, and owns the errands:
# only an owner's watch cleans one up.
export REEVE_BACKEND=hall
export REEVE_SESSION=lead

# errand <id> [<backend>]   a scout in flight, working, recorded on <backend>,
# or with no backend key at all when none is given
errand() {
  mkdir -p "$REEVE_HOME/errands/$1"
  printf 'working: on it\n' > "$REEVE_HOME/errands/$1/status"
  printf 'office=scout\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=no\nsession=lead\n%starget=w1|w1:p1\ndispatched=2026-10-01T00:00:00\n' \
    "${2:+backend=$2
}" > "$REEVE_HOME/state/$1.meta"
}

echo "--- 1. a herdr errand under REEVE_BACKEND=hall stays on herdr ---"
eq  "1 the caller resolves hall"                            "$("$ROOT/bin/reeve-backend" resolve)" hall
errand old herdr
: > "$ACTS"; "$ROOT/bin/reeve-status" old >/dev/null 2>&1
has "1 status asks herdr"                                   "$(acts)" "herdr agent_state w1|w1:p1"
nas "1 and never hall"                                      "$(acts)" "hall "
: > "$ACTS"; "$ROOT/bin/reeve-status" --all --no-wake >/dev/null 2>&1
has "1 so does the whole listing"                           "$(acts)" "herdr agent_state w1|w1:p1"
nas "1 never hall there either"                             "$(acts)" "hall "
: > "$ACTS"; "$ROOT/bin/reeve-sentry" --once --no-reap >/dev/null 2>&1
has "1 the sentry watches it on herdr"                      "$(acts)" "herdr attention_state w1|w1:p1"
nas "1 and never on hall"                                   "$(acts)" "hall "
: > "$ACTS"; "$ROOT/bin/reeve-steer" old 'back to the brief' >/dev/null 2>&1
has "1 a steer is typed into herdr"                         "$(acts)" "herdr send_text_submit w1|w1:p1"
nas "1 never into hall"                                     "$(acts)" "hall "
printf 'done: finished\n' >> "$REEVE_HOME/errands/old/status"
: > "$ACTS"; "$ROOT/bin/reeve-teardown" old >/dev/null 2>&1
has "1 its cleanup closes it on herdr"                      "$(acts)" "herdr kill w1|w1:p1"
nas "1 and asks hall nothing"                               "$(acts)" "hall "

echo "--- 2. a record with no backend predates hall: herdr ---"
errand older
: > "$ACTS"; "$ROOT/bin/reeve-status" older >/dev/null 2>&1
has "2 status asks herdr"                                   "$(acts)" "herdr agent_state w1|w1:p1"
nas "2 never the caller's hall"                             "$(acts)" "hall "
: > "$ACTS"; "$ROOT/bin/reeve-sentry" --once --no-reap >/dev/null 2>&1
nas "2 the sentry never asks hall for it"                   "$(acts)" "hall "
printf 'done: finished\n' >> "$REEVE_HOME/errands/older/status"
: > "$ACTS"; "$ROOT/bin/reeve-sentry" --once >/dev/null 2>&1
has "2 the watch's cleanup closes it on herdr"              "$(acts)" "herdr kill w1|w1:p1"
nas "2 and asks hall nothing"                               "$(acts)" "hall "
# A cleanup refused before the session is closed leaves the target standing,
# and the watch then asks whether a session is still there: of herdr too.
errand oldest
printf 'done: finished\n' >> "$REEVE_HOME/errands/oldest/status"
: > "$ACTS"; STUB_LIVE=unreadable "$ROOT/bin/reeve-sentry" --once >/dev/null 2>&1
eq  "2 a refused cleanup's check asks herdr, twice"         "$(grep -c '^herdr agent_state' "$ACTS")" 2
nas "2 and never the watch's own hall"                      "$(acts)" "hall "

echo "--- 3. a hall errand goes to hall ---"
errand fresh hall
: > "$ACTS"; "$ROOT/bin/reeve-status" fresh >/dev/null 2>&1
has "3 status asks hall"                                    "$(acts)" "hall agent_state w1|w1:p1"
nas "3 and never herdr"                                     "$(acts)" "herdr "

echo "--- 4. a reeve's pane is asked of the backend its place names ---"
SESS="$REEVE_HOME/state/sessions"
holder() { # holder <sid> <name> <pane> [<place>]
  mkdir -p "$SESS/$1"; printf '%s\n' "$2" > "$SESS/$1/name"; printf '%s\n' "$3" > "$SESS/$1/pane"
  printf '%s\n' "$(date +%s)" > "$SESS/$1/seen"
  [ -n "${4:-}" ] && printf '%s\n' "$4" > "$SESS/$1/place"
  return 0
}
lib() { bash -c '. "$1/bin/reeve-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }
holder rh Hugh 'w1:p1@/hall.sock' 'hall default'
holder rd Odo  'w2:p1@/herdr.sock'
: > "$ACTS"; lib holder_live rh
eq  "4 a hall holder's pane is asked of hall"               "$(acts)" "hall pane_vacant w1:p1 /hall.sock"
: > "$ACTS"; lib holder_live rd
eq  "4 a holder with no place, of herdr"                    "$(acts)" "herdr pane_vacant w2:p1 /herdr.sock"
: > "$ACTS"; lib name_live_elsewhere Hugh 'w9:p9@/x.sock' me >/dev/null
eq  "4 a name's holder the same way"                        "$(acts)" "hall pane_vacant w1:p1 /hall.sock"
printf 'g1@/hall.sock\n' > "$SESS/rh/group.hall"; printf 'g2@/herdr.sock\n' > "$SESS/rd/group.hall"
: > "$ACTS"; REEVE_SESSION=me lib group_held_elsewhere me hall >/dev/null
has "4 a group's holder on hall, of hall"                   "$(acts)" "hall pane_gone w1:p1 /hall.sock"
has "4 and one with no place, of herdr"                     "$(acts)" "herdr pane_gone w2:p1 /herdr.sock"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
