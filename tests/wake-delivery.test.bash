#!/usr/bin/env bash
# An artificer ran for seventy minutes, wrote `done:` to its status file, and
# its session was closed. The reeve that briefed it was never told and sat
# believing the work was still in flight until the liege said otherwise.
#
# Nothing was ever going to tell it. A reeve is woken by bin/reeve-sentry in the
# foreground and by nothing else, and a reeve that dispatches and then sits idle
# is running none. What a dispatch leaves behind is a caretaker, which is silent
# by contract. So the caretaker was the only thing that saw the `done:` line,
# and what it did with it was free the hand's session, which blanks `target=`
# and, the branch being unlanded, leaves `tornDown=` unset. Reading in-flight
# off `target=` then took the errand out of every watch as well, before and
# after: no watch started afterwards could see it, and no cursor for it was ever
# written.
#
# Two halves, and both are needed. The caretaker hands the line over to the
# owning session's wake file instead of consuming it, and an errand whose
# session was freed but which was never torn down stays in flight until it is.
#
# Every case here is the same question asked from a different side: after a hand
# reports a terminal line, does that line reach the reeve that briefed it.
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

STARTED=''
marker_pid() { cut -d' ' -f1 "$1" 2>/dev/null; }
reap_started() {
  local p f
  for p in $STARTED; do kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null; done
  for f in "$SCRATCH"/*/state/.sentry.lock "$SCRATCH"/*/state/.sentry.watch-*; do
    [ -f "$f" ] || continue
    p=$(marker_pid "$f")
    case $p in ''|*[!0-9]*) continue ;; esac
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

# --- a stubbed code root ------------------------------------------------------
# So no session is ever opened and nothing depends on which harness is installed.
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
reeve_backend_stub_agent_state()     { [ -n "${1:-}" ] && printf 'alive\n' || printf 'missing\n'; }
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
export REEVE_ROOT="$STUB"

meta_of() { grep -m1 "^$2=" "$REEVE_HOME/state/$1.meta" 2>/dev/null | sed "s/^$2=//"; }
# The spool is a directory, one file per wake, and each file is key=value lines
# with the line itself under `say`. These two read and write it the way the
# household does, without sourcing the library: a test that shares the code
# under test cannot see a change of shape.
wake_of()    { cat "$REEVE_HOME/state/sessions/$1"/wake/* 2>/dev/null | sed -n 's/^say=//p'; }
wake_count() { ls -1 "$REEVE_HOME/state/sessions/$1"/wake 2>/dev/null | grep -c . ; }
wake_plant() { # wake_plant <session> <errand> <log lines> <line>
  local d="$REEVE_HOME/state/sessions/$1/wake"
  mkdir -p "$d"
  printf 'errand=%s\nlines=%s\nsay=%s\n' "$2" "$3" "$4" \
    > "$d/$(date +%s).$$.$(ls -1 "$d" 2>/dev/null | grep -c .)"
}
# The owner walked away from its terminal for longer than the staleness window,
# which is all "idle" looks like from outside: the liveness mark is refreshed by
# reeve commands and statusline renders, and a reeve waiting on a hand runs
# neither. This is the state the errand was in when its caretaker judged it.
idled() { # idled <session>
  mkdir -p "$REEVE_HOME/state/sessions/$1"
  printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$REEVE_HOME/state/sessions/$1/seen"
}

echo "--- 1. the miss itself: a hand finishes while its reeve is idle ---"
export REEVE_HOME="$SCRATCH/home1"
export REEVE_SESSION=owner
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

brief_for slow || bad "1 reeve-brief refused"
OUT=$(REEVE_CARETAKER_POLL=1 "$ROOT/bin/reeve-dispatch" slow --backend stub --harness stub 2>&1)
eq "1 the dispatch succeeds" "$?" 0
LOCK="$REEVE_HOME/state/.sentry.lock"
if waitfor 10 '[ -f "$LOCK" ]'; then
  CARE=$(marker_pid "$LOCK"); STARTED="$STARTED $CARE"
else
  bad "1 a caretaker took the lock" "no lock appeared at $LOCK"
fi

# The hand does its work and finishes. A commit on its own branch is what makes
# the teardown refuse to remove the copy, which is what left the real errand
# with an empty target and no tornDown stamp: dismissed, not torn down.
WT="$SCRATCH/holding.worktrees/artificer-slow"
date > "$WT/built.txt"
git -C "$WT" add built.txt
git -C "$WT" -c user.email=hand@example.invalid -c user.name=hand \
    -c commit.gpgsign=false commit -q -m 'feat: build the thing'
idled owner
printf 'working: building\ndone: branch ready, 1 commit\n' > "$REEVE_HOME/errands/slow/status"

if waitfor 20 '[ -z "$(meta_of slow target)" ]'; then
  ok  "1 the caretaker freed the finished hand's session"
  eq  "1 and the branch kept it from being torn down, exactly as it was" \
      "$([ -n "$(meta_of slow tornDown)" ] && echo tornDown || echo dismissed-only)" dismissed-only
else
  bad "1 the caretaker freed the finished hand's session" "$(cat "$REEVE_HOME/state/slow.meta")"
fi
waitfor 20 '! kill -0 "$CARE" 2>/dev/null' || kill "$CARE" 2>/dev/null

# The caretaker is gone, the pane is gone, and the reeve has not been told
# anything. This is the exact moment the liege found the household in.
has "1 the line the caretaker saw was handed to the reeve that briefed it" \
    "$(wake_of owner)" "slow is done"
eq  "1 and no other session was given it" \
    "$([ -e "$REEVE_HOME/state/sessions/departed/wake" ] && echo present || echo absent)" absent

OUT=$("$ROOT/bin/reeve-sentry" --once 2>&1); RC=$?
eq  "1 the reeve's next watch wakes"      "$RC" 0
has "1 and says which errand finished"    "$OUT" "slow"
has "1 and that it is done"               "$OUT" "done"
has "1 and relays what the hand said"     "$OUT" "branch ready, 1 commit"

OUT=$("$ROOT/bin/reeve-sentry" --once 2>&1); RC=$?
nas "1 a delivered wake is not delivered twice" "$OUT" "was cleaned up with no reeve watching"

echo "--- 2. a dismissed errand is still in flight until it is torn down ---"
# The half that stands on its own: even with no wake file at all, an errand
# whose session was freed and whose copy was kept must remain visible to a
# watch, because its `done:` line has still reached nobody. Read off `target=`,
# it vanished from the household the instant it was cleaned up after.
export REEVE_HOME="$SCRATCH/home2"
export REEVE_SESSION=owner
mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/errands/freed"
printf 'target=\nbackend=stub\noffice=artificer\nsession=owner\nrepo=\nworktree=\nbranch=feat/x\nbase=main\nwrites=no\ndispatched=2026-09-28T20:25:26\n' \
  > "$REEVE_HOME/state/freed.meta"
printf 'working: building\ndone: branch ready, 2 commits\n' > "$REEVE_HOME/errands/freed/status"

OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "2 a watch still finds it"                 "$RC" 0
has "2 and reports it"                         "$OUT" "freed is done"
eq  "2 and a cursor is written for it at last" \
    "$([ -f "$REEVE_HOME/state/.cursor-freed" ] && echo present || echo absent)" present

# And having said its piece, the watch is finished with it. Keying in-flight off
# `target=` ended a watch by accident the moment a cleanup blanked that field;
# what ends it now is the report having been delivered, which is the thing that
# was actually meant.
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "2 a reported terminal errand stops counting as work in flight" "$RC" 3
has "2 and the watch says so"                                       "$OUT" "nothing in flight"

# An errand that was briefed and never sent out is not in flight either, which
# is the one thing the `target=` rule got right and must not be lost with it.
mkdir -p "$REEVE_HOME/errands/unsent"
printf 'target=\nbackend=stub\noffice=artificer\nsession=owner\nrepo=\nworktree=\nbranch=feat/y\nbase=main\nwrites=no\n' \
  > "$REEVE_HOME/state/unsent.meta"
: > "$REEVE_HOME/errands/unsent/status"
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "2 a briefed errand that never went out is not watched" "$RC" 3

echo "--- 3. a wake belongs to the session that briefed the errand ---"
# One home is shared by every reeve on this machine. A wake read by the wrong
# reeve is worse than one that waits: the reeve it was meant for never learns
# its hand finished, and the one that took it reports an errand it does not own.
export REEVE_HOME="$SCRATCH/home3"
mkdir -p "$REEVE_HOME/state"
wake_plant alice theirs 2 \
  'signal: theirs is done and its session was cleaned up with no reeve watching - branch ready'

REEVE_SESSION=bob OUT=$(REEVE_SESSION=bob "$ROOT/bin/reeve-status" 2>&1) || :
nas "3 another reeve does not take it" "$OUT" "theirs is done"
eq  "3 and it is still waiting for its own" "$(wake_count alice)" 1

OUT=$(REEVE_SESSION=alice "$ROOT/bin/reeve-status" 2>&1) || :
has "3 the reeve that briefed it is told when it next looks at its errands" "$OUT" "theirs is done"
eq  "3 and told once"                                                     "$(wake_count alice)" 0

echo "--- 4. a dispatch that leaves nobody watching says so ---"
# The shape of the whole bug in one line: a hand goes out, nothing is watching,
# and the report reads like a clean dispatch. Never fatal, because the dispatch
# itself worked, but never silent either.
export REEVE_HOME="$SCRATCH/home4"
export REEVE_SESSION=owner
mkdir -p "$REEVE_HOME"
brief_for alone || bad "4 reeve-brief refused"
ERRF="$SCRATCH/err.alone"
OUT=$(REEVE_NO_CARETAKER=1 "$ROOT/bin/reeve-dispatch" alone --backend stub --harness stub 2>"$ERRF"); RC=$?
ERR=$(cat "$ERRF")
eq  "4 the dispatch still succeeds"        "$RC" 0
has "4 and still reports itself"           "$OUT" "dispatched alone"
has "4 but it names the household's state" "$ERR" "NOTHING IS WATCHING alone"
has "4 and what to do about it"            "$ERR" "bin/reeve-sentry"

export REEVE_HOME="$SCRATCH/home5"
mkdir -p "$REEVE_HOME"
brief_for tended || bad "4 reeve-brief refused"
ERRF="$SCRATCH/err.tended"
OUT=$(REEVE_CARETAKER_POLL=1 "$ROOT/bin/reeve-dispatch" tended --backend stub --harness stub 2>"$ERRF")
ERR=$(cat "$ERRF")
LOCK="$REEVE_HOME/state/.sentry.lock"
nas "4 a dispatch with a caretaker behind it says nothing of the sort" "$ERR" "NOTHING IS WATCHING"
eq  "4 and it waited to find out rather than assuming" \
    "$([ -f "$LOCK" ] && echo locked || echo unlocked)" locked
# Read AFTER the assertion, never as part of it: the case above is about the
# dispatch having waited, and a wait here would answer it on the dispatch's
# behalf. This only makes sure the trap can account for the process either way,
# because a run that fails that case is exactly a run that leaks a poller.
waitfor 10 '[ -f "$LOCK" ]' && STARTED="$STARTED $(marker_pid "$LOCK")"
printf 'done: nothing to do\n' > "$REEVE_HOME/errands/tended/status"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
