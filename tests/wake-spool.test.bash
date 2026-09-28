#!/usr/bin/env bash
# The channel that carries a finished hand's last line to the reeve that briefed
# it. tests/wake-delivery.test.bash pins that the line is handed over at all;
# this pins that it SURVIVES the handover.
#
# It did not. The mailbox was one file per session, read with head, rewritten
# with tail and moved into place, and every step of that is a window a writer
# can land in. Measured on the shape this replaces: 200 appends against one
# draining reader lost 54 of them, and two readers over 60 queued lines
# delivered one line each, the same line twice, and destroyed the other 59. The
# household's own contract prescribes exactly those two readers. A line was also
# cleared before it was written rather than after, so `reeve-status --all |
# head -1` printed the first signal, destroyed the second on the write that
# failed, and left the third; and `reeve-handoff new` drained the whole mailbox
# into a table it then filtered every signal back out of, at the one moment a
# reeve is about to be reset and that mailbox is about to become unreadable by
# anybody.
#
# Around the losses sit the four ways one line becomes no line or two:
# a caretaker re-announcing an errand that was reported long ago, a wake and the
# in-flight path both reporting one event, an errand with no owner torn down
# with its report still undelivered, and a wake that does not follow its errand
# when another reeve adopts it.
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
trap 'rm -rf "$SCRATCH"' EXIT

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

# How many wakes are pending for a session, and what they say. Both shapes, on
# purpose: this suite is meant to be run against the code it replaced as well,
# and a reading that only understands the new layout would report a mailbox full
# of destroyed lines as an empty one and pass.
spool()   { printf '%s/state/sessions/%s/wake' "$REEVE_HOME" "$1"; }
count()   {
  local d; d=$(spool "$1")
  if   [ -d "$d" ]; then ls -1 "$d" 2>/dev/null | grep -c .
  elif [ -f "$d" ]; then grep -c . "$d" 2>/dev/null || printf '0\n'
  else printf '0\n'; fi
}
lines()   {
  local d; d=$(spool "$1")
  if   [ -d "$d" ]; then cat "$d"/* 2>/dev/null | sed -n 's/^say=//p'
  elif [ -f "$d" ]; then cat "$d" 2>/dev/null; fi
}
meta_of() { grep -m1 "^$2=" "$REEVE_HOME/state/$1.meta" 2>/dev/null | sed "s/^$2=//"; }
errand()  { # errand <id> <owner> <status line>...
  local id=$1 owner=$2; shift 2
  mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/errands/$id"
  printf 'target=stub:1\nbackend=stub\noffice=scout\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=no\ndispatched=2026-09-28T20:25:26\nsession=%s\n' \
    "$owner" > "$REEVE_HOME/state/$id.meta"
  : > "$REEVE_HOME/errands/$id/status"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$REEVE_HOME/errands/$id/status"; done
}

# Drained through the library itself, exactly as bin/reeve-status drains, and
# through whichever draining function it has: the shape this replaces handed the
# line back to be printed by its caller, which is half of what section 2 is
# about, so a suite that could only call the new one would not run against it.
drain() { # drain <session>   prints every line it got
  REEVE_SESSION=$1 bash -c '. "$0"/bin/reeve-lib.sh
    if type wake_deliver >/dev/null 2>&1; then while wake_deliver; do :; done
    else while l=$(wake_take); do printf "%s\n" "$l"; done; fi' "$ROOT"
}
leave() { # leave <session> <line> [errand] [lines]
  REEVE_SESSION=$1 bash -c '. "$0"/bin/reeve-lib.sh; wake_leave "$1" "$2" "${3:-}" "${4:-}"' \
    "$ROOT" "$1" "$2" "${3:-}" "${4:-}"
}

echo "--- 1. nothing is lost to a writer and a reader working at once ---"
# The measured failure, both halves. A caretaker reaping a second errand while
# the reeve happens to be looking destroyed that errand's report outright, and
# for a scout or a warden the loss is permanent: the copy is gone, tornDown= is
# written, the errand leaves live_errands, no cursor is ever written for it and
# nothing announces it again.
export REEVE_HOME="$SCRATCH/home1"
mkdir -p "$REEVE_HOME/state/sessions"

N=200
( for i in $(seq 1 $N); do leave writer "signal: line-$i"; done ) &
W=$!
: > "$SCRATCH/got1"
while kill -0 $W 2>/dev/null; do drain writer >> "$SCRATCH/got1"; done
wait $W
drain writer >> "$SCRATCH/got1"
got=$(grep -c . "$SCRATCH/got1" 2>/dev/null || echo 0)
dis=$(sort -u "$SCRATCH/got1" | grep -c . 2>/dev/null || echo 0)
eq "1 $N appends against a draining reader: none lost"       "$dis" "$N"
eq "1 and none delivered twice"                              "$got" "$dis"
eq "1 and the spool is empty afterwards"                     "$(count writer)" 0

# Two readers at once is not an edge case: AGENTS.md tells the reeve to run the
# watch in the background, and /muster runs reeve-status in the foreground.
M=60
for i in $(seq 1 $M); do leave pair "signal: two-$i"; done
: > "$SCRATCH/gotA"; : > "$SCRATCH/gotB"
drain pair >> "$SCRATCH/gotA" & A=$!
drain pair >> "$SCRATCH/gotB" & B=$!
wait $A $B
cat "$SCRATCH/gotA" "$SCRATCH/gotB" > "$SCRATCH/got2"
got2=$(grep -c . "$SCRATCH/got2" 2>/dev/null || echo 0)
dis2=$(sort -u "$SCRATCH/got2" | grep -c . 2>/dev/null || echo 0)
eq "1 two concurrent readers over $M lines: all delivered" "$dis2" "$M"
eq "1 and each exactly once"                               "$got2" "$M"

echo "--- 2. a line is removed after it is written, never before ---"
# Measured on the shape this replaces: three pending signals, `reeve-status
# --all | head -1` prints the first, destroys the second on the write that fails
# and leaves the third. A reeve that trims or greps a listing lost whatever was
# in flight at that moment, and so did a sentry killed between the two steps.
export REEVE_HOME="$SCRATCH/home2"
export REEVE_SESSION=trimmer
mkdir -p "$REEVE_HOME/state"
errand alive trimmer "working: going"
for i in 1 2 3; do leave trimmer "signal: pending-$i" alive; done
shown=$("$ROOT/bin/reeve-status" --all 2>/dev/null | head -1 | grep -c .)
eq "2 a trimmed listing prints one line"      "$shown" 1
eq "2 and destroys none of the rest"          "$(count trimmer)" 2
OUT=$("$ROOT/bin/reeve-status" --all 2>/dev/null)
eq "2 which the next full listing delivers"   "$(printf '%s' "$OUT" | grep -c 'signal: pending-')" 2
eq "2 leaving the spool empty"                "$(count trimmer)" 0

echo "--- 3. a command asking a different question must not eat one ---"
# reeve-handoff called reeve-status --all for its table, which drained the
# mailbox, and then kept only the rows whose first field was ERRAND or a live
# errand id. A signal starts `signal:`, so it was dropped: gone from the spool
# and absent from the document, at the one moment the spool is about to belong
# to nobody, because a reset gives the next session a different id.
export REEVE_HOME="$SCRATCH/home3"
export REEVE_SESSION=resetting
mkdir -p "$REEVE_HOME/state"
errand held resetting "working: going"
leave resetting 'signal: gone-scout is done and its session was cleaned up with no reeve watching - answered' gone-scout 2
HO=$("$ROOT/bin/reeve-handoff" new reeve 2>/dev/null | sed -n 's/.*handoff scaffolded: //p')
eq  "3 a handoff leaves the pending wake where it was" "$(count resetting)" 1
has "3 and carries it into the document"               "$(cat "$HO" 2>/dev/null)" "gone-scout is done"
DOC=$("$ROOT/bin/reeve-doctor" 2>/dev/null) || :
eq  "3 reeve-doctor does not spend one either"         "$(count resetting)" 1
nas "3 nor prints it inside its errand table"          "$DOC" "gone-scout is done"
OUT=$("$ROOT/bin/reeve-status" 2>&1) || :
has "3 while the reeve's own listing still delivers it" "$OUT" "gone-scout is done"
eq  "3 and only then is it gone"                        "$(count resetting)" 0

echo "--- 4. one wake per errand, for the whole home and not per process ---"
# `tended` is per process and nothing read a cursor, so the only thing that ever
# stopped a caretaker re-announcing was tornDown=, which the landed-work guard
# never writes for an artificer branch that has not landed. Every dispatch
# starts a caretaker, so an unlanded branch produced one false wake per dispatch,
# forever, and by then its text was false too: the session was cleaned up long
# ago and the reeve was watching. This is the false alarm the errand that built
# this channel was told is worse than no guard at all.
export REEVE_HOME="$SCRATCH/home4"
export REEVE_SESSION=janitor
mkdir -p "$REEVE_HOME/state"
REPO="$SCRATCH/holding"
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" -c user.email=r@example.invalid -c user.name=r \
    -c commit.gpgsign=false commit -q --allow-empty -m init
WT="$SCRATCH/holding.worktrees/artificer-unlanded"
git -C "$REPO" worktree add -q "$WT" -b feat/unlanded main
date > "$WT/built.txt"
git -C "$WT" add built.txt
git -C "$WT" -c user.email=h@example.invalid -c user.name=h \
    -c commit.gpgsign=false commit -q -m 'feat: build the thing'
mkdir -p "$REEVE_HOME/errands/unlanded"
printf 'target=stub:1\nbackend=stub\noffice=artificer\nrepo=%s\nworktree=%s\nbranch=feat/unlanded\nbase=main\nwrites=yes\ndispatched=2026-09-28T20:25:26\nsession=briefer\n' \
  "$REPO" "$WT" > "$REEVE_HOME/state/unlanded.meta"
printf 'working: building\ndone: branch ready, 1 commit\n' > "$REEVE_HOME/errands/unlanded/status"

for _ in 1 2 3; do "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1; done
eq "4 three caretakers over one unlanded branch leave one wake" "$(count briefer)" 1
eq "4 and the branch is still there to be landed"               "$(meta_of unlanded tornDown)" ''

# The other half: an errand the owning reeve has already reported needs no wake
# at all, whatever a later caretaker finds on disk.
export REEVE_HOME="$SCRATCH/home4b"
mkdir -p "$REEVE_HOME/state"
errand told briefer "working: going" "done: landed"
printf '2\n' > "$REEVE_HOME/state/.cursor-told"
"$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1
eq "4 an errand its reeve already reported gets no wake" "$(count briefer)" 0
eq "4 and is cleaned up all the same" \
   "$([ -n "$(meta_of told tornDown)" ] && echo torn-down || echo kept)" torn-down

echo "--- 5. one event is one report ---"
# The wake and the in-flight path both used to fire for one finished hand: the
# watch printed the wake and exited, and the next watch found the errand still
# standing in live_errands with no cursor against it and said the same thing
# again. reeve-status calls a wake delivered twice noise; delivering one now
# marks the errand reported, which is what makes that true.
export REEVE_HOME="$SCRATCH/home5"
export REEVE_SESSION=owner
mkdir -p "$REEVE_HOME/state"
errand twice owner "working: going" "done: branch ready"
leave owner 'signal: twice is done and its session was cleaned up with no reeve watching - branch ready' twice 2
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "5 the first watch delivers the wake"   "$RC" 0
has "5 saying which errand it was about"    "$OUT" "twice is done"
eq  "5 and marks the errand reported"       "$(cat "$REEVE_HOME/state/.cursor-twice" 2>/dev/null)" 2
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "5 the next watch has nothing to add"   "$RC" 3
nas "5 and does not report it again"        "$OUT" "twice is done"

# A wake with nothing in flight behind it is still delivered, and by the sentry
# rather than only by reeve-status: the errand it is about has usually been
# cleaned up already, so it is not in flight by any reading.
export REEVE_HOME="$SCRATCH/home5b"
mkdir -p "$REEVE_HOME/state"
leave owner 'signal: vanished is done and its session was cleaned up with no reeve watching - report written' vanished 2
OUT=$("$ROOT/bin/reeve-sentry" --once 2>&1); RC=$?
eq  "5 a wake with nothing in flight still wakes the reeve" "$RC" 0
has "5 and says what it was"                                "$OUT" "vanished is done"

echo "--- 6. a wake is addressed to the reeve that briefed the errand ---"
# One home is shared by every reeve on this machine, and the caretaker doing the
# cleaning is usually not the one that briefed the errand: it inherits whatever
# session started it. A line posted to its own session is a line the reeve it
# was meant for never sees, and one the taker reports about an errand it does
# not own.
export REEVE_HOME="$SCRATCH/home6"
mkdir -p "$REEVE_HOME/state"
errand theirs alice "working: going" "done: report written"
REEVE_SESSION=reeveB "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1
eq  "6 the line goes to the session that briefed it" "$(count alice)"  1
eq  "6 and not to the caretaker's own"               "$(count reeveB)" 0
has "6 and it names the errand"                      "$(lines alice)" "theirs is done"

echo "--- 7. an errand nobody owns keeps its report ---"
# The household supports a harness that exports no session id, and there the
# record names no owner, so there is nowhere to leave the line. Tearing the
# errand down regardless writes tornDown=, drops it out of live_errands, and
# leaves the `done:` line in a status file no watch looks at again: the reviewed
# bug intact for those homes.
export REEVE_HOME="$SCRATCH/home7"
mkdir -p "$REEVE_HOME/state"
errand nobodys '' "working: going" "done: report written"
REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1
eq  "7 it is not torn down with its report undelivered" "$(meta_of nobodys tornDown)" ''
eq  "7 but its idle session is freed, which costs nothing" "$(meta_of nobodys target)" ''
OUT=$(REEVE_SESSION=passerby "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1)
has "7 and the next reeve to watch still finds it"      "$OUT" "nobodys is done"

echo "--- 8. a pending wake follows its errand to a new owner ---"
# Adoption rewrites session=, and a wake is addressed to a session, so the line
# stayed in the spool of a reeve that is, by the rule adoption is allowed under,
# provably gone. For a torn-down scout that line is the only report there was.
export REEVE_HOME="$SCRATCH/home8"
mkdir -p "$REEVE_HOME/state/sessions/dead-owner"
printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$REEVE_HOME/state/sessions/dead-owner/seen"
errand handed dead-owner "working: going" "done: branch ready"
leave dead-owner 'signal: handed is done and its session was cleaned up with no reeve watching - branch ready' handed 2
leave dead-owner 'signal: other is done and its session was cleaned up with no reeve watching - done' other 1
OUT=$(REEVE_SESSION=heir "$ROOT/bin/reeve-adopt" handed 2>&1); RC=$?
eq  "8 the adoption succeeds"                     "$RC" 0
eq  "8 the errand's own wake comes with it"       "$(count heir)" 1
has "8 and it is the right one"                   "$(lines heir)" "handed is done"
eq  "8 another errand's wake is left where it is" "$(count dead-owner)" 1
has "8 and the adoption says so"                  "$OUT" "pending notification"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
