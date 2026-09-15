#!/usr/bin/env bash
# Nothing ever started bin/reeve-sentry. It ran only when a reeve session ran it
# in the foreground, so terminating or refreshing that session left the household
# with no watcher AND no cleaner: every hand already out finished, reported
# `done:`, and then sat at a prompt holding a session forever. That was the
# liege's reported symptom.
#
# The fix splits the two jobs. Telling the reeve something is actionable needs a
# reeve by definition. Cleaning up after a finished hand does not, because
# bin/reeve-teardown owns the safety rules and they are mechanical. So a dispatch
# leaves a caretaker running, and these cases pin what that caretaker must be:
#
#   1. silent. It never prints a reason line and never exits 0 on an actionable
#      change, because it has nobody to tell. It also never reads or writes the
#      wake cursors, which de-duplicate reports it does not make: a caretaker
#      started after a `done:` line was written must still clean that hand up.
#   2. safe. The never-reap rules are the sentry's own, reused rather than
#      rewritten: a `blocked:` hand can still be steered, and a hand that
#      reported done with a question never answered is not finished.
#   3. single, and mortal. One per home, a second start is a quiet no-op, a lock
#      left by a dead process is reclaimed rather than honoured, and the process
#      ends when the last job it was tending is done.
#   4. detached. It has to outlive the dispatch that started it, or the fix does
#      nothing at all.
#
# Scratch homes only, never the real one. Every case that starts a process waits
# for it and kills it: a suite that leaks a poller is a failed suite.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }

# --- scratch everything ------------------------------------------------------
real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
[ -n "$real_home" ] || { printf 'FAIL  refusing to run: the real home could not be resolved\n'; exit 1; }
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
for guard in "${REEVE_HOME:-}" "$real_home/.reeve"; do
  [ -n "$guard" ] || continue
  g=$(cd -P "$guard" 2>/dev/null && pwd) || g=$guard
  case $SCRATCH in
    "$g"|"$g"/*) printf 'FAIL  refusing to run: the scratch dir %s is inside %s\n' "$SCRATCH" "$g"; exit 1 ;;
  esac
done

# Every caretaker this suite starts, so the trap can account for all of them.
# Read from the scratch homes' own lock files, which nothing else writes.
STARTED=''
reap_started() {
  local p
  for p in $STARTED; do kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null; done
  for p in $(cat "$SCRATCH"/home*/state/.sentry.lock/pid 2>/dev/null); do
    case $p in ''|*[!0-9]*) continue ;; esac
    kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null
  done
  return 0
}
trap 'reap_started; rm -rf "$SCRATCH"' EXIT

waitfor() { # waitfor <seconds> <condition>   poll a condition, never a blind sleep
  local n=0 limit=$(( ${1:-5} * 20 ))
  while [ "$n" -lt "$limit" ]; do
    eval "$2" && return 0
    sleep 0.05
    n=$((n + 1))
  done
  return 1
}

free_pid() { # a pid that is not running, for the stale-lock cases
  local p=41000
  while kill -0 "$p" 2>/dev/null; do p=$((p + 1)); done
  printf '%s\n' "$p"
}

# --- a stubbed code root ------------------------------------------------------
# So no session is ever opened and nothing depends on which harness is installed.
# The backend records every kill, which is how "the session was freed" is
# asserted without a real one.
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
KILLS="$SCRATCH/kills"; : > "$KILLS"
export STUB_KILLS="$KILLS"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_launch()          { return 0; }
reeve_backend_stub_agent_state()     { printf 'alive\n'; }
reeve_backend_stub_attention_state() { printf 'settled\n'; }
reeve_backend_stub_wait_change()     { return 2; }
reeve_backend_stub_kill()            { printf '%s\n' "$1" >> "$STUB_KILLS"; return 0; }
ADAPTER
cat > "$STUB/harnesses/stub.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {settings} {prompt}"
settings_flag = "--settings {settings}"
prompt_mode = "argv"
HARNESS

errand() { # errand <id> <writes> <status line>...
  local id=$1 writes=$2; shift 2
  mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/errands/$id"
  printf 'target=stub:1\nbackend=stub\noffice=artificer\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=%s\n' \
    "$writes" > "$REEVE_HOME/state/$id.meta"
  : > "$REEVE_HOME/errands/$id/status"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$REEVE_HOME/errands/$id/status"; done
}
meta_of()   { grep -m1 "^$2=" "$REEVE_HOME/state/$1.meta" 2>/dev/null | sed "s/^$2=//"; }
reaped()    { [ -n "$(meta_of "$1" tornDown)" ] && printf 'yes\n' || printf 'no\n'; }
killed()    { grep -qF "$1" "$KILLS" && printf 'yes\n' || printf 'no\n'; }
cursors()   { ( cd "$REEVE_HOME/state" 2>/dev/null && ls -a | grep -E '^\.(cursor|attn)-' | sort ) 2>/dev/null; }

echo "--- 1. a caretaker cleans up, says nothing, and judges like the sentry ---"
export REEVE_HOME="$SCRATCH/home1"
export REEVE_ROOT="$STUB"
mkdir -p "$REEVE_HOME/state"
errand finished no "working: reading the auth module" "done: branch ready, 3 commits"
errand stuck    no "working: installing"              "blocked: pnpm install fails, no .env present"
errand asking   no "working: reading the brief"       "needs-decision [key=scope]: rewrite the parser or patch it?"
errand busy     no "working: still going"

# The foreground watch first, on the same fleet, and with --no-reap so it changes
# nothing. Two things come out of it: the reason lines a caretaker must never
# print, and a full set of wake cursors. A caretaker that read those cursors
# would then find nothing new and clean up nothing, which is exactly the case
# that matters, because a caretaker is usually started long after a hand
# finished.
fg=''
for _ in 1 2 3 4 5; do
  out=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); rc=$?
  fg="$fg$out
"
  [ "$rc" -eq 0 ] || break
done
has "1 the foreground watch does report the finished hand" "$fg" "finished is done"
has "1 and the open decision"                              "$fg" "asking needs a decision"
has "1 and the blocked one"                                "$fg" "stuck is blocked"
eq  "1 nothing was reaped, --no-reap"                      "$(reaped finished)" no
before_cursors=$(cursors)
eq  "1 the watch left cursors behind" \
    "$([ -n "$before_cursors" ] && echo present || echo absent)" present

OUT=$("$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 2>&1); RC=$?
eq  "1 the caretaker says nothing at all"        "$OUT" ""
eq  "1 and never exits 0 on an actionable fleet" "$RC" 4
eq  "1 the finished hand is cleaned up anyway, cursors or no cursors" "$(reaped finished)" yes
eq  "1 and its session was freed"                "$(killed stub:1)" yes
eq  "1 a blocked hand is not reaped"             "$(reaped stuck)" no
eq  "1 nor one with an open decision"            "$(reaped asking)" no
eq  "1 nor one still working"                    "$(reaped busy)" no
eq  "1 and no cursor was read or written"        "$(cursors)" "$before_cursors"

# The other terminal state, and the divergence that looks like one. `failed:` is
# finished and is cleaned up; `done:` with a question still open is not finished
# whatever it says, and is left exactly where it is.
errand broke     no "working: building" "failed: the build cannot be made to pass"
errand diverged  no "needs-decision [key=shape]: one table or two?" "done: landed it anyway"
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 2>&1); RC=$?
eq  "1 a failed hand is cleaned up"              "$(reaped broke)" yes
eq  "1 a divergence is not"                      "$(reaped diverged)" no
eq  "1 and it is still silent about both"        "$OUT" ""

echo "--- 2. the lock: one per home, and a dead one does not hold it ---"
export REEVE_HOME="$SCRATCH/home2"
LOCK="$REEVE_HOME/state/.sentry.lock"
mkdir -p "$LOCK"
errand pending no "working: going"
printf '%s\n' "$$" > "$LOCK/pid"          # this test process: unambiguously alive
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 2>&1); RC=$?
eq  "2 a second caretaker is a no-op"                "$RC" 0
eq  "2 and a quiet one"                              "$OUT" ""
eq  "2 it did not steal the lock"                    "$(cat "$LOCK/pid")" "$$"
eq  "2 and did no tending while somebody else holds it" "$(reaped pending)" no

# A lock whose pid is dead must be reclaimed, or one crashed caretaker disables
# cleanup for this home forever.
printf '%s\n' "$(free_pid)" > "$LOCK/pid"
errand ghost no "working: going" ; printf 'done: finished\n' >> "$REEVE_HOME/errands/ghost/status"
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 2>&1); RC=$?
eq  "2 a dead pid does not hold the lock"     "$(reaped ghost)" yes
eq  "2 and the reclaimed lock is released on the way out" \
    "$([ -d "$LOCK" ] && echo present || echo absent)" absent

# Nothing in flight is the end of a caretaker's life: the last job finishing must
# end the process so nothing lingers.
export REEVE_HOME="$SCRATCH/home3"
mkdir -p "$REEVE_HOME/state"
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --poll 1 2>&1); RC=$?
eq  "2 nothing in flight exits 3"             "$RC" 3
eq  "2 without saying so"                     "$OUT" ""
eq  "2 and leaves no lock behind"             "$([ -d "$REEVE_HOME/state/.sentry.lock" ] && echo present || echo absent)" absent

echo "--- 3. dispatch starts one, detaches it, and a dry run does not ---"
export REEVE_HOME="$SCRATCH/home4"
mkdir -p "$REEVE_HOME"
REPO="$SCRATCH/holding"
mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" -c user.email=reeve@example.invalid -c user.name=reeve \
    -c commit.gpgsign=false commit -q --allow-empty -m init

brief_for() { # brief_for <id>
  REEVE_ROOT="$ROOT" "$ROOT/bin/reeve-brief" "$1" "$REPO" --office artificer >/dev/null || return 1
  local b="$REEVE_HOME/errands/$1/brief.md"
  sed -e 's/{INTENT}/the liege said so/' -e 's/{SPEC}/build the thing/' "$b" > "$b.filled" \
    && mv "$b.filled" "$b"
}
dispatch() { # dispatch <id> [args...] -> sets OUT, ERR, RC
  local id=$1; shift
  ERR="$SCRATCH/err.$id"
  OUT=$(REEVE_ROOT="$STUB" REEVE_CARETAKER_POLL=1 "$ROOT/bin/reeve-dispatch" "$id" \
          --backend stub --harness stub "$@" 2>"$ERR"); RC=$?
  ERR=$(cat "$ERR")
}
LOG="$REEVE_HOME/state/sentry.log"
LOCK="$REEVE_HOME/state/.sentry.lock"

brief_for dry || bad "3 reeve-brief refused"
dispatch dry --dry-run
eq  "3 the dry run succeeds"                 "$RC" 0
has "3 it says it would start a caretaker"   "$OUT" "would run: bin/reeve-sentry --caretaker"
has "3 and still claims nothing was changed" "$OUT" "nothing was changed."
eq  "3 no caretaker was started"             "$([ -e "$LOG" ] && echo present || echo absent)" absent
eq  "3 and no lock was created"              "$([ -d "$LOCK" ] && echo present || echo absent)" absent

brief_for optout || bad "3 reeve-brief refused"
OUT=$(REEVE_NO_CARETAKER=1 REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" optout \
        --backend stub --harness stub --dry-run 2>&1)
nas "3 the opt-out silences the dry run's line too" "$OUT" "--caretaker"
REEVE_NO_CARETAKER=1 dispatch optout
eq  "3 a real dispatch under the opt-out succeeds" "$RC" 0
eq  "3 and starts nothing"                   "$([ -e "$LOG" ] && echo present || echo absent)" absent
eq  "3 and locks nothing"                    "$([ -d "$LOCK" ] && echo present || echo absent)" absent
# That dispatch was real, so this home now holds a hand nobody is tending. Finish
# it here: the case below asserts that a caretaker ENDS when nothing is left, and
# a hand left working forever is a hand it would be right to keep tending.
printf 'done: nothing to do\n' > "$REEVE_HOME/errands/optout/status"

# The whole point, end to end: dispatch, let the dispatching process exit, and a
# hand that reports done is cleaned up by something that is no longer attached to
# anything.
brief_for live || bad "3 reeve-brief refused"
dispatch live
eq  "3 the dispatch succeeds" "$RC" 0
if waitfor 10 '[ -f "$LOCK/pid" ]'; then
  ok "3 a caretaker took the lock"
  CARE=$(cat "$LOCK/pid"); STARTED="$STARTED $CARE"
  eq  "3 and it is running"  "$(kill -0 "$CARE" 2>/dev/null && echo alive || echo gone)" alive
  # Its parent was bin/reeve-dispatch, which has long exited: a caretaker still
  # attached to the dispatching shell would die with it, which is the defect.
  eq  "3 detached from the dispatch that started it" \
      "$(ps -o ppid= -p "$CARE" 2>/dev/null | tr -d '[:space:]')" 1

  printf 'working: building\ndone: branch ready\n' > "$REEVE_HOME/errands/live/status"
  if waitfor 15 '[ -n "$(meta_of live tornDown)" ]'; then
    ok "3 the finished hand is cleaned up with no reeve anywhere"
    eq "3 its session was freed"    "$(killed stub:1)" yes
    eq "3 and its copy removed"     "$([ -d "$SCRATCH/holding.worktrees/artificer-live" ] && echo present || echo absent)" absent
  else
    bad "3 the finished hand is cleaned up with no reeve anywhere" \
        "the caretaker never tore it down: $(cat "$REEVE_HOME/state/live.meta")"
  fi
  if waitfor 15 '! kill -0 "$CARE" 2>/dev/null'; then
    ok "3 and the caretaker then ends itself, leaving nothing running"
  else
    bad "3 and the caretaker then ends itself, leaving nothing running" "pid $CARE is still alive"
  fi
  eq  "3 the lock is gone with it" "$([ -d "$LOCK" ] && echo present || echo absent)" absent
  eq  "3 it wrote nothing to its log, having nothing to report" \
      "$([ -s "$LOG" ] && cat "$LOG" || echo '')" ""
else
  bad "3 a caretaker took the lock" "no lock appeared at $LOCK. log: $(cat "$LOG" 2>/dev/null)"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
