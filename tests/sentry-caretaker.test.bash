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
#      change, because it has nobody to tell. It never WRITES a wake cursor
#      either, because a cursor records a report and it makes none. It does read
#      them, for one question only, whether the owning reeve still has to be
#      told: the cleanup itself is never read off one, or a caretaker started
#      after a `done:` line was written would never clean that hand up.
#   2. safe. The never-reap rules are the sentry's own, reused rather than
#      rewritten: a `blocked:` hand can still be steered, and a hand that
#      reported done with a question never answered is not finished.
#   3. single, and mortal. One per home, a second start is a quiet no-op, a lock
#      left by a dead process is reclaimed rather than honoured, and the process
#      ends when the last job it was tending is done.
#   4. detached. It has to outlive the dispatch that started it, or the fix does
#      nothing at all.
#   5. a STANDBY, not a peer. While an errand's owner is watching, it leaves
#      that errand alone, because cleaning up an errand the watch has not
#      reported yet races the watch for that report. An errand nobody owns waits
#      on any watch at all. Sections 4 and 5 run the two of them genuinely
#      concurrently, which is the only way that shows.
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

# Every process this suite starts, so the trap can account for all of them.
# Also read from the scratch homes' own markers, which nothing else writes: a
# lock names the caretaker holding it and a watch names the watch that published
# it, both in the same shape, `<pid> <epoch> <poll>`.
STARTED=''
marker_pid() { cut -d' ' -f1 "$1" 2>/dev/null; }
# marker <pid> <seconds of age> [poll]   what a process with that pid would have
# written that many seconds ago. Age is the point: a marker is only believed
# while its writer is alive AND still refreshing it.
marker() { printf '%s %s %s\n' "$1" "$(( $(date +%s) - ${2:-0} ))" "${3:-1}"; }
reap_started() {
  local p f
  for p in $STARTED; do kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null; done
  for f in "$SCRATCH"/*/state/.sentry.lock "$SCRATCH"/*/state/.sentry.watch-*; do
    [ -f "$f" ] || continue
    p=$(marker_pid "$f")
    case $p in ''|*[!0-9]*) continue ;; esac
    # Never this process. Several cases below plant a marker naming it on
    # purpose, because it is the one pid certain to be alive, and a sweep that
    # read that back as a stray poller would kill the suite in its own trap:
    # every case passing and the run still ending 143, with the scratch
    # directory left behind unremoved.
    [ "$p" = "$$" ] && continue
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
reeve_backend_stub_agent_state()     { case $1 in gone:*) printf 'gone\n' ;; *) printf 'alive\n' ;; esac; }
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

# ERRAND_OWNER is the session a seeded errand was briefed by, empty by default
# because an unowned errand is what every watch here can see without pinning a
# session first. A case that wants the copy REMOVED has to name an owner: a
# caretaker will not remove what it could not report, and an unowned errand has
# nowhere to leave the report. Whether that owner is alive does not matter to a
# caretaker, only whether it is watching, and nothing here publishes a marker for
# an owner unless the case says so.
ERRAND_OWNER=''
errand() { # errand <id> <writes> <status line>...
  local id=$1 writes=$2; shift 2
  mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/errands/$id"
  printf 'target=stub:1\nbackend=stub\noffice=artificer\nrepo=\nworktree=\nbranch=\nbase=main\nsession=%s\nwrites=%s\n' \
    "$ERRAND_OWNER" "$writes" > "$REEVE_HOME/state/$id.meta"
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
eq  "1 and no cursor was written"                "$(cursors)" "$before_cursors"

# The other terminal state, and the divergence that looks like one. `failed:` is
# finished and is cleaned up; `done:` with a question still open is not finished
# whatever it says, and is left exactly where it is.
#
# Owned, unlike the four above, and by a session that has never reported. These
# two are seeded after the watch has been and gone, so no cursor covers them and
# the report is still owed: without somewhere to leave it the caretaker would
# free the session and stop there, which is the rule section 7 is about.
ERRAND_OWNER=gone
errand broke     no "working: building" "failed: the build cannot be made to pass"
errand diverged  no "needs-decision [key=shape]: one table or two?" "done: landed it anyway"
ERRAND_OWNER=''
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 2>&1); RC=$?
eq  "1 a failed hand is cleaned up"              "$(reaped broke)" yes
eq  "1 a divergence is not"                      "$(reaped diverged)" no
eq  "1 and it is still silent about both"        "$OUT" ""

echo "--- 2. the lock: one per home, and neither a dead nor a forgotten one holds it ---"
export REEVE_HOME="$SCRATCH/home2"
LOCK="$REEVE_HOME/state/.sentry.lock"
mkdir -p "$REEVE_HOME/state"
# Every case here asks whether the lock let a caretaker work, and reads the
# answer off a completed teardown, so each errand needs an owner to report to.
ERRAND_OWNER=gone
errand pending no "working: going"
marker "$$" 0 > "$LOCK"                   # this test process: alive, and current
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 2>&1); RC=$?
eq  "2 a second caretaker is a no-op"                "$RC" 0
eq  "2 and a quiet one"                              "$OUT" ""
eq  "2 it did not steal the lock"                    "$(marker_pid "$LOCK")" "$$"
eq  "2 and did no tending while somebody else holds it" "$(reaped pending)" no

# A lock whose pid is dead must be reclaimed, or one crashed caretaker disables
# cleanup for this home forever.
marker "$(free_pid)" 0 > "$LOCK"
errand ghost no "working: going" ; printf 'done: finished\n' >> "$REEVE_HOME/errands/ghost/status"
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 2>&1); RC=$?
eq  "2 a dead pid does not hold the lock"     "$(reaped ghost)" yes
eq  "2 and the reclaimed lock is released on the way out" \
    "$([ -e "$LOCK" ] && echo present || echo absent)" absent

# The other half of the same rule, and the one a pid alone cannot answer: pids
# are reused. A caretaker killed with -9 leaves its number behind, and the day
# an unrelated process of this user inherits it, `kill -0` says the lock is held
# and no caretaker ever starts for this home again, silently, because a refused
# start is exit 0. So a holder that stopped refreshing does not hold it either,
# however alive its pid looks: this one names THIS process, which is certainly
# running, and is five minutes stale against a one second poll.
errand zombie no "working: going" ; printf 'done: finished\n' >> "$REEVE_HOME/errands/zombie/status"
marker "$$" 300 1 > "$LOCK"
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 2>&1); RC=$?
eq  "2 a live pid that stopped refreshing does not hold it either" "$(reaped zombie)" yes
eq  "2 and reclaiming it is silent"                                "$OUT" ""

# Anything unreadable is stale, and saying so is not the caretaker's job. This
# is the lock a caretaker leaves when it is killed between creating the file and
# writing into it, which is a state the lock can no longer reach at all now that
# its contents are written before it is installed, but a reader that trips over
# an empty one must still be silent rather than print a shell error into
# state/sentry.log, which the case at the end of section 3 asserts stays empty.
errand husk no "working: going" ; printf 'done: finished\n' >> "$REEVE_HOME/errands/husk/status"
: > "$LOCK"
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 2>&1); RC=$?
eq  "2 an unreadable lock is reclaimed"       "$(reaped husk)" yes
eq  "2 without a word about it"               "$OUT" ""

# Nothing in flight is the end of a caretaker's life: the last job finishing must
# end the process so nothing lingers.
export REEVE_HOME="$SCRATCH/home3"
mkdir -p "$REEVE_HOME/state"
OUT=$("$ROOT/bin/reeve-sentry" --caretaker --poll 1 2>&1); RC=$?
eq  "2 nothing in flight exits 3"             "$RC" 3
eq  "2 without saying so"                     "$OUT" ""
eq  "2 and leaves no lock behind"             "$([ -e "$REEVE_HOME/state/.sentry.lock" ] && echo present || echo absent)" absent
eq  "2 and no half written one either"        "$(ls -a "$REEVE_HOME/state" | grep -c '^\.sentry')" 0

# A caretaker that finds its own lock reclaimed out from under it ends itself
# rather than becoming the second one. That is what bounds the one window
# acquisition cannot close: a pair is a pair for at most one poll.
export REEVE_HOME="$SCRATCH/home3b"
LOCK="$REEVE_HOME/state/.sentry.lock"
mkdir -p "$REEVE_HOME/state"
errand held no "working: going"
"$ROOT/bin/reeve-sentry" --caretaker --poll 1 >"$SCRATCH/held.out" 2>&1 &
CARE=$!; STARTED="$STARTED $CARE"
if waitfor 10 '[ -f "$LOCK" ]'; then
  # Somebody else now holds this home, as a caretaker holds it: written whole,
  # and re-asserted every check. One write in place loses to a refresh the
  # caretaker already had in flight, and a real holder settles that next poll.
  # Liveness first, and re-taken only from the caretaker, never from nobody: a
  # lock gone missing is the caretaker removing what it no longer holds, which
  # the check after this must still see rather than have papered over.
  take_lock() { marker "$$" 0 > "$LOCK.new.$$" && mv "$LOCK.new.$$" "$LOCK"; }
  take_lock
  if waitfor 10 '! kill -0 "$CARE" 2>/dev/null || { [ "$(marker_pid "$LOCK")" = "$CARE" ] && take_lock; false; }'; then
    ok "2 a caretaker whose lock was taken stands down"
  else
    bad "2 a caretaker whose lock was taken stands down" "pid $CARE is still alive"
  fi
  eq "2 and does not remove the lock it no longer holds" "$(marker_pid "$LOCK")" "$$"
  eq "2 nor says anything on the way out"                "$(cat "$SCRATCH/held.out")" ""
else
  bad "2 a caretaker whose lock was taken stands down" "no lock appeared at $LOCK"
fi

# The other direction, and it is not the same question. Standing down is right
# when somebody live holds the home and wrong when nobody does: a lock that went
# stale or vanished under a running caretaker has to be taken back, or a reclaim
# race ends with every caretaker having politely stood down and the home left
# with no cleaner at all. That is a worse outcome than briefly having two, and
# it happened: forty simultaneous starts against one stale lock settled on zero
# survivors twice in twelve rounds before this.
export REEVE_HOME="$SCRATCH/home3c"
LOCK="$REEVE_HOME/state/.sentry.lock"
mkdir -p "$REEVE_HOME/state"
errand kept no "working: going"
"$ROOT/bin/reeve-sentry" --caretaker --poll 1 >"$SCRATCH/kept.out" 2>&1 &
CARE=$!; STARTED="$STARTED $CARE"
if waitfor 10 '[ -f "$LOCK" ]'; then
  rm -f "$LOCK"                           # a reclaimer took it and thought better
  if waitfor 10 '[ "$(marker_pid "$LOCK")" = "$CARE" ]'; then
    ok "2 a caretaker whose lock vanished takes the home back"
  else
    bad "2 a caretaker whose lock vanished takes the home back" \
        "lock reads [$(cat "$LOCK" 2>/dev/null)], caretaker is $CARE"
  fi
  eq "2 and is still the one tending it" \
     "$(kill -0 "$CARE" 2>/dev/null && echo alive || echo gone)" alive
  printf 'done: branch ready\n' >> "$REEVE_HOME/errands/kept/status"
  if waitfor 15 '[ -n "$(meta_of kept tornDown)" ]'; then
    ok "2 and still cleans up after the hand it was left with"
  else
    bad "2 and still cleans up after the hand it was left with" "never torn down"
  fi
  waitfor 10 '! kill -0 "$CARE" 2>/dev/null' || kill "$CARE" 2>/dev/null
else
  bad "2 a caretaker whose lock vanished takes the home back" "no lock appeared at $LOCK"
fi

echo "--- 3. dispatch starts one, detaches it, and a dry run does not ---"
export REEVE_HOME="$SCRATCH/home4"
mkdir -p "$REEVE_HOME"
# Everything below is briefed by one named session, so that "no reeve anywhere"
# can be made TRUE rather than assumed. An errand records the session that
# briefed it, and the owner is retired here as well as not watching, which is
# the strongest form of "no reeve anywhere". A caretaker only asks the second
# question; tests/sentry-ownership.test.bash covers an owner alive and not
# watching.
export REEVE_SESSION=departed
# The owner walked away. Backdated well past the staleness window, so the
# caretaker can prove it rather than guess.
depart() {
  mkdir -p "$REEVE_HOME/state/sessions/departed"
  printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$REEVE_HOME/state/sessions/departed/seen"
}
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
eq  "3 and no lock was created"              "$([ -e "$LOCK" ] && echo present || echo absent)" absent

brief_for optout || bad "3 reeve-brief refused"
OUT=$(REEVE_NO_CARETAKER=1 REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" optout \
        --backend stub --harness stub --dry-run 2>&1)
nas "3 the opt-out silences the dry run's line too" "$OUT" "--caretaker"
REEVE_NO_CARETAKER=1 dispatch optout
eq  "3 a real dispatch under the opt-out succeeds" "$RC" 0
eq  "3 and starts nothing"                   "$([ -e "$LOG" ] && echo present || echo absent)" absent
eq  "3 and locks nothing"                    "$([ -e "$LOCK" ] && echo present || echo absent)" absent
# And says so on the errand itself, which is what every caretaker reads: the
# one the next dispatch starts below included, so it must leave this hand up.
eq  "3 the opt-out is recorded on the errand" "$(meta_of optout keep)" REEVE_NO_CARETAKER
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
if waitfor 10 '[ -f "$LOCK" ]'; then
  ok "3 a caretaker took the lock"
  CARE=$(marker_pid "$LOCK"); STARTED="$STARTED $CARE"
  eq  "3 and it is running"  "$(kill -0 "$CARE" 2>/dev/null && echo alive || echo gone)" alive
  # Its parent was bin/reeve-dispatch, which has long exited: a caretaker still
  # attached to the dispatching shell would die with it, which is the defect.
  eq  "3 detached from the dispatch that started it" \
      "$(ps -o ppid= -p "$CARE" 2>/dev/null | tr -d '[:space:]')" 1

  # Truncated first, and that matters: KILLS is cumulative and every errand in
  # this suite runs on target stub:1, so section 1 had already recorded a kill of
  # it. Asserted against that record, "its session was freed" was true before
  # this dispatch existed and would have passed had the caretaker freed nothing
  # at all. A case that cannot fail is worse than no case.
  : > "$KILLS"
  printf 'working: building\ndone: branch ready\n' > "$REEVE_HOME/errands/live/status"
  depart
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
  # The opt-out's hand finished too, before this caretaker existed, and is the
  # whole point of the switch: kept up, by a caretaker it did not start.
  eq  "3 the kept hand beside it was left running" \
      "$(meta_of optout tornDown)|$(meta_of optout target)" "|stub:1"
  eq  "3 with its copy" \
      "$([ -d "$SCRATCH/holding.worktrees/artificer-optout" ] && echo present || echo absent)" present
  eq  "3 the lock is gone with it" "$([ -e "$LOCK" ] && echo present || echo absent)" absent
  eq  "3 it wrote nothing to its log, having nothing to report" \
      "$([ -s "$LOG" ] && cat "$LOG" || echo '')" ""
else
  bad "3 a caretaker took the lock" "no lock appeared at $LOCK. log: $(cat "$LOG" 2>/dev/null)"
fi

# A home the caretaker cannot write to is the one case the start guard exists to
# name, and the older guard could not see it: `mkdir -p` on a directory that is
# already there succeeds whatever its permissions, so an unwritable home dropped
# through to a dispatch that reported perfect success and left no cleaner. Never
# fatal, still: the dispatch itself worked. A directory standing where the log
# belongs is the same refusal, and needs no chmod to arrange.
export REEVE_HOME="$SCRATCH/home4b"
mkdir -p "$REEVE_HOME/state/sentry.log"
brief_for walled || bad "3 reeve-brief refused"
dispatch walled
eq  "3 a home the caretaker cannot write to is not fatal" "$RC" 0
has "3 and the dispatch still reports itself"             "$OUT" "dispatched walled"
has "3 but it says no caretaker started"                  "$ERR" "no caretaker started"
has "3 and names what could not be written"               "$ERR" "$REEVE_HOME/state/sentry.log"
eq  "3 and nothing is locking that home"                  \
    "$([ -e "$REEVE_HOME/state/.sentry.lock" ] && echo present || echo absent)" absent

# The opt-out is one dispatch's word, not the errand's for good. A relaunch of the
# same errand without it, which is how a hand whose session died is sent out
# again, used to inherit keep= from the first and be kept forever though nobody
# asked. A steward, because it has no copy for the relaunch to collide with.
export REEVE_HOME="$SCRATCH/home4c"
mkdir -p "$REEVE_HOME"
LOG="$REEVE_HOME/state/sentry.log"
LOCK="$REEVE_HOME/state/.sentry.lock"
REEVE_ROOT="$ROOT" "$ROOT/bin/reeve-brief" again "$REPO" --office steward >/dev/null \
  || bad "3 reeve-brief refused"
b="$REEVE_HOME/errands/again/brief.md"
sed -e 's/{INTENT}/the liege said so/' -e 's/{SPEC}/tidy the home/' "$b" > "$b.filled" && mv "$b.filled" "$b"
REEVE_NO_CARETAKER=1 dispatch again
eq  "3 a steward dispatched under the opt-out"   "$RC" 0
eq  "3 is recorded as kept"                      "$(meta_of again keep)" REEVE_NO_CARETAKER
# Its session went away, so the next dispatch is a relaunch rather than a refusal.
sed 's/^target=.*/target=gone:1/' "$REEVE_HOME/state/again.meta" > "$SCRATCH/again.meta" \
  && mv "$SCRATCH/again.meta" "$REEVE_HOME/state/again.meta"
: > "$KILLS"
dispatch again
eq  "3 relaunched without the opt-out"           "$RC" 0
has "3 as a relaunch"                            "$ERR" "relaunching"
eq  "3 and is no longer kept"                    "$(meta_of again keep)" ""
if waitfor 10 '[ -f "$LOCK" ]'; then
  CARE=$(marker_pid "$LOCK"); STARTED="$STARTED $CARE"
  printf 'working: tidying\ndone: home tidied\n' > "$REEVE_HOME/errands/again/status"
  depart
  if waitfor 15 '[ "$(killed stub:1)" = yes ]'; then
    ok "3 so the caretaker frees it once it is done"
  else
    bad "3 so the caretaker frees it once it is done" "never freed: $(cat "$REEVE_HOME/state/again.meta")"
  fi
  waitfor 15 '! kill -0 "$CARE" 2>/dev/null' || bad "3 the relaunch's caretaker ends" "pid $CARE is still alive"
else
  bad "3 the relaunch started a caretaker" "no lock appeared at $LOCK. log: $(cat "$LOG" 2>/dev/null)"
fi

echo "--- 4. the watch and the caretaker, at the same time, on one home ---"
# The regression this section exists for, and the reason every case above it is
# not enough: they run the two modes one after the other, so the only thing they
# can see is what each does alone. Run together, the caretaker used to destroy
# the watch's report rather than delay it. It tears the finished errand down,
# teardown writes tornDown=, live_errands stops listing it, and the watch's next
# tick finds nothing in flight and leaves. The `is done` line is then gone for
# good: a fresh watch started afterwards sees nothing either, and `done:` and
# `failed:` are exactly the two states the household must report.
#
# Eight phase offsets across one poll interval, because which of the two ticks
# first is the whole of it. The offset is measured from the `done:` line, which
# is the only instant that matters, and the caretaker is started there rather
# than left to drift into position: a poller's first tick is immediate, so at
# the short offsets the caretaker reaches that errand first every single run,
# which is the losing case pinned down instead of waited for. The watch is
# already established before any of it, so what varies is only how far behind
# the line the cleaner arrives.
# Unowned, deliberately. The standby marker is this section's whole subject, and
# an owner the watch is running as would answer reap_allowed before standby was
# ever consulted.
ERRAND_OWNER=''
kept=0; ended=0; noise=''; n=0
for off in 0 0.125 0.25 0.375 0.5 0.625 0.75 0.875; do
  n=$((n + 1))
  export REEVE_HOME="$SCRATCH/race$n"
  errand racer no "working: going"
  "$ROOT/bin/reeve-sentry" --poll 1 --timeout 12 >"$REEVE_HOME/fg.out" 2>&1 &
  WATCHER=$!; STARTED="$STARTED $WATCHER"
  waitfor 10 '[ -f "$REEVE_HOME/state/.cursor-racer" ]' \
    || bad "4 the watch is in its loop before the race starts" "no cursor at offset $off"
  printf 'done: branch ready\n' >> "$REEVE_HOME/errands/racer/status"
  sleep "$off"
  "$ROOT/bin/reeve-sentry" --caretaker --poll 1 >"$REEVE_HOME/care.out" 2>&1 &
  CARE=$!; STARTED="$STARTED $CARE"
  wait "$WATCHER"
  if grep -qF 'racer is done' "$REEVE_HOME/fg.out"; then
    kept=$((kept + 1))
  else
    printf '        offset %s said [%s]\n' "$off" "$(tr '\n' ' ' < "$REEVE_HOME/fg.out")"
  fi
  # and the standby ends itself once the watch has cleaned up after itself
  waitfor 10 '! kill -0 "$CARE" 2>/dev/null' && ended=$((ended + 1)) || kill "$CARE" 2>/dev/null
  noise="$noise$(cat "$REEVE_HOME/care.out")"
done
eq  "4 the watch reported the finished hand at every one of 8 phase offsets" "$kept" 8
eq  "4 and every caretaker ended once there was nothing left to tend"        "$ended" 8
eq  "4 none of them said a word"                                             "$noise" ""

echo "--- 5. the watch marker: believed while it is refreshed, never past that ---"
export REEVE_HOME="$SCRATCH/home5"
# A watch marker is named for the session that published it, so two reeves
# watching at once cannot overwrite each other's. Pinning the session here is
# what makes the filename predictable enough to assert on.
export REEVE_SESSION=w5
WATCH_F="$REEVE_HOME/state/.sentry.watch-w5"
mkdir -p "$REEVE_HOME/state"
errand watched no "working: going"
"$ROOT/bin/reeve-sentry" --poll 1 --timeout 3 --no-reap >/dev/null 2>&1 &
WATCHER=$!; STARTED="$STARTED $WATCHER"
if waitfor 5 '[ -f "$WATCH_F" ]'; then
  ok "5 a foreground watch says on disk that it holds the home"
  eq "5 naming the process doing the watching" "$(marker_pid "$WATCH_F")" "$WATCHER"
else
  bad "5 a foreground watch says on disk that it holds the home" "nothing appeared at $WATCH_F"
fi
wait "$WATCHER"
eq  "5 and takes the marker with it when it stops" \
    "$([ -e "$WATCH_F" ] && echo present || echo absent)" absent

# What a caretaker does about one. The three that must not stop it are the
# reason this is a marker with a clock in it rather than a pid: the reeve's
# session is routinely killed outright, and a marker that outlived its process
# must never be able to disable cleanup for a home permanently. That would be a
# worse failure than the race it closes.
# Owned from here on: each of these reads its answer off a completed teardown.
# `watched` above stays unowned, because the watch that publishes the marker has
# to be able to see it. Owned by w5, the session whose marker this is, because a
# caretaker yields an owned errand to its OWNER'S watch and to nobody else's.
ERRAND_OWNER=w5
watched_reap() { # watched_reap <id> <marker line>   -> yes|no
  errand "$1" no "working: going"
  printf 'done: finished\n' >> "$REEVE_HOME/errands/$1/status"
  if [ -n "$2" ]; then printf '%s' "$2" > "$WATCH_F"; else rm -f "$WATCH_F"; fi
  "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1
  reaped "$1"
}
eq "5 a live watch stops the caretaker reaping"       "$(watched_reap guarded "$(marker "$$" 0 60)")" no
eq "5 a watch whose process died does not"            "$(watched_reap dead "$(marker "$(free_pid)" 0 60)")" yes
eq "5 nor one that stopped refreshing, pid or no pid" "$(watched_reap stale "$(marker "$$" 300 1)")" yes
eq "5 and with no watch at all it just works"         "$(watched_reap alone '')" yes
# Somebody else's watch is no reason to stand aside: that watch neither sees nor
# reaps this errand, so yielding to it left the hand idle until its own reeve
# next looked.
ERRAND_OWNER=gone
eq "5 a live watch by another session does not stop it" "$(watched_reap elsewhere "$(marker "$$" 0 60)")" yes

# Standing by is not retiring. The caretaker must still be there, still polling,
# for the moment the watch goes away, because that moment is a reeve's session
# being terminated and every hand it was watching still has to be cleaned up.
export REEVE_HOME="$SCRATCH/home6"
WATCH_F="$REEVE_HOME/state/.sentry.watch-w6"
mkdir -p "$REEVE_HOME/state"
ERRAND_OWNER=w6
errand orphan no "working: building" "done: branch ready"
marker "$$" 0 60 > "$WATCH_F"
"$ROOT/bin/reeve-sentry" --caretaker --poll 1 >"$SCRATCH/standby.out" 2>&1 &
CARE=$!; STARTED="$STARTED $CARE"
sleep 3                                  # three polls, which is a decision made
eq  "5 it reaps nothing while a watch holds the home" "$(reaped orphan)" no
eq  "5 and does not exit over it either"              \
    "$(kill -0 "$CARE" 2>/dev/null && echo alive || echo gone)" alive
rm -f "$WATCH_F"                         # the session the reeve watched from is gone
if waitfor 15 '[ -n "$(meta_of orphan tornDown)" ]'; then
  ok "5 and cleans up the moment that watch is gone"
else
  bad "5 and cleans up the moment that watch is gone" "$(cat "$REEVE_HOME/state/orphan.meta")"
fi
if waitfor 15 '! kill -0 "$CARE" 2>/dev/null'; then
  ok "5 then ends itself, with nothing left to tend"
else
  bad "5 then ends itself, with nothing left to tend" "pid $CARE is still alive"
  kill "$CARE" 2>/dev/null
fi
eq  "5 silent throughout"  "$(cat "$SCRATCH/standby.out")" ""

echo "--- 6. a line that lands while the log is being read ---"
# The other way the same wake is lost, and this one needs no caretaker at all.
# The cursor is what says a line has been dealt with, so moving it past a line
# the verdict did not include loses that line for good. Reconciling an errand
# reads its log three times over, and a `done:` appended inside that gap was
# counted as seen while the verdict still said `working`: absorbed as progress,
# never reported, and no later poll ever looks again.
#
# No sleeps and no luck. The cursor is read with `cat` between the verdict and
# the count, so a `cat` of this suite's own making, firing once and only on the
# cursor path, is that gap exactly.
export REEVE_HOME="$SCRATCH/home7"
mkdir -p "$REEVE_HOME/state"
ERRAND_OWNER=''
errand midread no "working: going"
REAL_CAT=$(command -v cat)
FAKEBIN="$SCRATCH/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/cat" <<EOF
#!/bin/sh
case \${1:-} in
  *.cursor-midread)
    if [ ! -e "$SCRATCH/injected" ]; then
      : > "$SCRATCH/injected"
      printf 'done: branch ready\n' >> "$REEVE_HOME/errands/midread/status"
    fi ;;
esac
exec "$REAL_CAT" "\$@"
EOF
chmod +x "$FAKEBIN/cat"
OUT=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/reeve-sentry" --poll 1 --timeout 10 --no-reap 2>&1); RC=$?
eq  "6 the line really did land mid read" \
    "$([ -e "$SCRATCH/injected" ] && echo yes || echo no)" yes
has "6 and is still reported"             "$OUT" "midread is done"
eq  "6 on the watch's own exit"           "$RC" 0
eq  "6 with the cursor caught up, not run ahead" \
    "$(cat "$REEVE_HOME/state/.cursor-midread" 2>/dev/null)" \
    "$(grep -c . "$REEVE_HOME/errands/midread/status")"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
