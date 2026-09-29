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
# How much of an errand's log has been delivered, read from disk rather than
# through the library, for the same reason as the two above: a suite that asks
# the code under test where it keeps a thing cannot notice it keeping it in the
# wrong place. Both shapes on purpose, so this suite still says something when it
# is run against the commit that kept the count in the shared record.
delivered_of() { # delivered_of <errand>
  local v
  v=$(cat "$REEVE_HOME/state/.delivered-$1" 2>/dev/null | tr -d '[:space:]')
  [ -n "$v" ] || v=$(meta_of "$1" delivered)
  printf '%s' "$v"
}
# Anything left lying beside it: a half written count, or a temp file a rename
# should have consumed.
delivered_debris() { ( cd "$REEVE_HOME/state" 2>/dev/null && ls -a | grep -c "^\.delivered-$1\." ) 2>/dev/null; }
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

echo "--- 2. a listing cannot lose a line to what the reeve does with its stdout ---"
# Two ways a listing costs the reeve a signal, and one order of operations only
# answers the first. A TRIM is a write that FAILS: measured on the shape this
# replaces, `reeve-status --all | head -1` printed the first signal, destroyed the
# second on the failed write and left the third, which writing before removing
# settles. A FILTER is a write that SUCCEEDS into something that throws the line
# away: `| grep` for anything else consumed all three and returned 0, and since
# delivering marks the errand reported, that was the report, permanently and
# silently. AGENTS.md promises both cases cost nothing.
#
# So a listing hands its lines over on stderr, outside the stream the reeve is
# filtering, and both cases come out the same way.
export REEVE_HOME="$SCRATCH/home2"
export REEVE_SESSION=trimmer
mkdir -p "$REEVE_HOME/state"
errand alive trimmer "working: going"
for i in 1 2 3; do leave trimmer "signal: pending-$i" alive; done
ERRF="$SCRATCH/err.trim"
shown=$("$ROOT/bin/reeve-status" --all 2>"$ERRF" | head -1 | grep -c .)
eq "2 a trimmed listing still prints its table" "$shown" 1
eq "2 and hands over every pending line"        "$(grep -c 'signal: pending-' "$ERRF")" 3
eq "2 leaving the spool empty"                  "$(count trimmer)" 0

# The filter, over an errand that has finished, which is the case the loss is
# permanent for: the reeve greps a listing, the line is gone, the errand is
# marked reported and every later watch says nothing is in flight.
export REEVE_HOME="$SCRATCH/home2b"
export REEVE_SESSION=filter
mkdir -p "$REEVE_HOME/state"
errand gone filter "working: going" "done: report written"
leave filter 'signal: gone is done and its session was cleaned up with no reeve watching - report written' gone 2
ERRF="$SCRATCH/err.grep"
"$ROOT/bin/reeve-status" --all 2>"$ERRF" | grep '^kept' >/dev/null
has "2 a filtered listing still tells the reeve" "$(cat "$ERRF")" "gone is done"
eq  "2 and spends the line, having said it"      "$(count filter)" 0
eq  "2 marking the errand reported"              "$(delivered_of gone)" 2
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "2 so the watch behind it adds nothing"      "$RC" 3
nas "2 and says it once in all"                  "$OUT" "gone is done"

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
# standing in live_errands with nothing recorded against it and said the same
# thing again. reeve-status calls a wake delivered twice noise; delivering one now
# marks the errand reported, which is what makes that true.
#
# In a file of the errand's own, not by moving its cursor. The cursor is how far
# a watch has READ the log, a delivery reads none of it, and writing one from
# there is what made a swallowed line silence the errand for good.
#
# Nor in the errand's shared record, which is where it went first. meta_set is
# read modify write over the whole record, so a delivery stamped there loses to
# whichever of the caretaker's `woke=` and the teardown's `tornDown=` renames
# last: 97 stamps of 200 overlapped pairs, measured, and every one of them an
# errand back in live_errands to be reported twice. Case 12 is that end to end.
export REEVE_HOME="$SCRATCH/home5"
export REEVE_SESSION=owner
mkdir -p "$REEVE_HOME/state"
errand twice owner "working: going" "done: branch ready"
leave owner 'signal: twice is done and its session was cleaned up with no reeve watching - branch ready' twice 2
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "5 the first watch delivers the wake"   "$RC" 0
has "5 saying which errand it was about"    "$OUT" "twice is done"
eq  "5 and marks the errand reported"       "$(delivered_of twice)" 2
eq  "5 in a file only this writes"          "$(meta_of twice delivered)" ''
eq  "5 written whole, with nothing left beside it" "$(delivered_debris twice)" 0
eq  "5 without claiming to have read its log" \
    "$([ -e "$REEVE_HOME/state/.cursor-twice" ] && echo present || echo absent)" absent
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "5 the next watch has nothing to add"   "$RC" 3
nas "5 and does not report it again"        "$OUT" "twice is done"

# The half of that the suite could not see: the stamp only ever moves forward.
# A wake left when the log was shorter, delivered after the errand has been
# reported in full, used to be able to walk the record backwards, put the errand
# back into live_errands and have one event reported a second time.
export REEVE_HOME="$SCRATCH/home5c"
mkdir -p "$REEVE_HOME/state"
errand stale owner "working: one" "working: two" "working: three" \
       "needs-decision [key=k]: which" "resolved [key=k]: that one" "done: branch ready"
leave owner 'signal: stale is done and its session was cleaned up with no reeve watching - branch ready' stale 6
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1)
has "5 the wake for the whole log is delivered" "$OUT" "stale is done"
eq  "5 and stamps the whole log"                "$(delivered_of stale)" 6
leave owner 'signal: stale is done and its session was cleaned up with no reeve watching - branch ready' stale 2
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1)
eq  "5 a wake from further back does not unreport it" "$(delivered_of stale)" 6
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "5 so the watch behind that one is quiet too"     "$RC" 3
nas "5 with the event still reported just once"       "$OUT" "stale is done"

# And the other invisible guard: the stamp goes in after the line has actually
# been written, never before. Above the write, an errand whose line reached
# nobody is marked reported and is never reported again. A closed stdout is what
# a dead reader looks like from inside the writer.
export REEVE_HOME="$SCRATCH/home5d"
mkdir -p "$REEVE_HOME/state"
errand unheard owner "working: going" "done: branch ready"
leave owner 'signal: unheard is done and its session was cleaned up with no reeve watching - branch ready' unheard 2
# Only the last line is the rc: a write to a closed fd 1 fails, which is the
# thing under test, but bash keeps the bytes in the stream's buffer and flushes
# them wherever fd 1 points next, so they arrive here behind the answer. The
# entry, the stamp and the next watch are what say where the line really got to.
rc=$(REEVE_SESSION=owner bash -c '. "$0"/bin/reeve-lib.sh
  wake_deliver >&- 2>/dev/null; printf "%s\n" "$?"' "$ROOT" | tail -1)
eq  "5 a write that does not land is not a delivery" "$rc" 2
eq  "5 the line is still there to be delivered"      "$(count owner)" 1
eq  "5 and nothing is marked reported"               "$(delivered_of unheard)" ''
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1)
has "5 so the next watch delivers it after all"      "$OUT" "unheard is done"

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

echo "--- 9. a file in the spool that is not a wake is not delivered as one ---"
# `say=$(wake_field ...)` fails to empty, `printf ''` succeeds, and the entry is
# consumed: for bin/reeve-sentry that is exit 0, an actionable wake, with no
# reason line, against a contract of exactly one line per exit. Only a corrupt or
# foreign file reaches this, and the answer is to set it aside rather than to
# report nothing and call it delivered.
export REEVE_HOME="$SCRATCH/home9"
export REEVE_SESSION=corrupt
mkdir -p "$REEVE_HOME/state" "$(spool corrupt)"
printf 'garbage with no keys\n' > "$(spool corrupt)/1000000000.1.00000"
leave corrupt 'signal: real is done and its session was cleaned up with no reeve watching - answered' real 1
OUT=$("$ROOT/bin/reeve-sentry" --once 2>&1); RC=$?
eq  "9 the watch still wakes, for the line that is one" "$RC" 0
has "9 and has something to say when it does"           "$OUT" "real is done"
eq  "9 the unreadable file is set aside, not destroyed" \
    "$(ls -a "$(spool corrupt)" | grep -c '^\.unreadable\.')" 1
eq  "9 and is out of the spool's way"                   "$(count corrupt)" 0

echo "--- 10. a spool that will not give its line up says so ---"
# `wake_deliver` returned 1 both for "nothing pending" and for "could not claim",
# so an unwritable spool read as an empty one: the line sat there, wake_peek could
# still see it, and the watch told the reeve nothing was in flight.
export REEVE_HOME="$SCRATCH/home10"
export REEVE_SESSION=stuck
mkdir -p "$REEVE_HOME/state"
errand held stuck "working: going"
leave stuck 'signal: held is done and its session was cleaned up with no reeve watching - answered' held 2
chmod a-w "$(spool stuck)"
OUT=$("$ROOT/bin/reeve-sentry" --once 2>&1); RC=$?
# The same spool from the writing side. A caretaker that cannot leave its line
# fails closed and says nothing: `> "$tmp" 2>/dev/null` let the shell report the
# failed redirection itself, before the thing meant to hide it was in effect, so
# `Permission denied` reached state/sentry.log and, through wake_move, the
# liege's own terminal during reeve-adopt.
noise=$(REEVE_SESSION=stuck bash -c '. "$0"/bin/reeve-lib.sh
  wake_leave stuck "signal: no room" held 2 2>&1 >/dev/null; printf ""' "$ROOT")
chmod u+w "$(spool stuck)"
eq  "10 a spool it cannot write to is silent, not noisy"       "$noise" ''
eq  "10 the watch wakes rather than reporting an empty spool" "$RC" 0
has "10 and says what is in the way"                          "$OUT" "cannot be delivered"
eq  "10 with the line still there to deliver"                 "$(count stuck)" 1

echo "--- 11. a claim expires, it is not a lease on a pid's whole life ---"
# A claim was freed by `kill -0` alone, which is not the judgement marker_alive
# makes about a stale process: that one wants the pid alive AND a stamp recent
# enough that it can still be doing the work. Pids are reused, and orphaned claims
# are ordinary rather than rare, because a trimmed listing leaves one every time
# the reader dies at the closed pipe between the rename and the rm. So an
# unrelated process inheriting the number hid the line for its whole life.
export REEVE_HOME="$SCRATCH/home11"
export REEVE_SESSION=claimed
mkdir -p "$REEVE_HOME/state"
sleep 300 & LIVE=$!
leave claimed 'signal: orphan is done and its session was cleaned up with no reeve watching - answered' orphan 1
f=$(ls "$(spool claimed)"/* | head -1)
mv "$f" "$f.claimed.$LIVE"
has "11 a claim with no stamp is expired, whoever holds the pid" "$(drain claimed)" "orphan is done"

leave claimed 'signal: second is done and its session was cleaned up with no reeve watching - answered' second 1
f=$(ls "$(spool claimed)"/* | head -1)
mv "$f" "$f.claimed.$LIVE.$(date +%s)"
eq  "11 a fresh claim by a living reader is left to it" "$(drain claimed)" ''
g=$(ls "$(spool claimed)"/*.claimed.* | head -1)
mv "$g" "${g%.*}.$(( $(date +%s) - 300 ))"
has "11 and the same claim is free once it goes stale"  "$(drain claimed)" "second is done"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null

echo "--- 12. another writer on the record cannot unreport a delivered line ---"
# The delivery stamp spent one commit inside the errand's shared record, where
# meta_set reads the whole file, drops one key, appends and renames the result
# over the top. Any writer holding a copy read before the delivery puts that copy
# back, and the stamp inside it is gone: measured over 200 fully overlapped
# pairs, `woke=` lost 103 and the stamp 97, `tornDown=` 98 against 102, every
# pair losing one of the two. The cost is not a lost write, it is the report said
# twice, because an errand with no stamp is an errand back in live_errands.
#
# Reproduced here as what a lost update leaves on disk rather than by racing for
# one: the record exactly as a caretaker read it before the delivery, with the
# field that caretaker went on to write. A race would pass on a slow machine and
# fail on a fast one, which is no test at all.
export REEVE_HOME="$SCRATCH/home12"
export REEVE_SESSION=owner
mkdir -p "$REEVE_HOME/state"
errand overlap owner "working: going" "done: branch ready"
leave owner 'signal: overlap is done and its session was cleaned up with no reeve watching - branch ready' overlap 2
before=$(cat "$REEVE_HOME/state/overlap.meta")
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "12 the wake is delivered"                     "$RC" 0
has "12 and names the errand"                      "$OUT" "overlap is done"
printf '%s\nwoke=2026-09-28T20:26:00\n' "$before" > "$REEVE_HOME/state/overlap.meta"
eq  "12 a concurrent record write leaves the stamp alone" "$(delivered_of overlap)" 2
OUT=$("$ROOT/bin/reeve-sentry" --once --no-reap 2>&1); RC=$?
eq  "12 so the watch behind it has nothing to add" "$RC" 3
nas "12 and one event is still one report"         "$OUT" "overlap is done"

echo "--- 13. a home that cannot record a delivery still delivers it ---"
# Recording it used to go through meta_set, whose redirections are unguarded on
# purpose: its message is the only sign some homes give that they have gone read
# only. That is fine everywhere it was already called from, and wrong here, where
# the stream it lands in is the notification channel itself. Measured on the
# commit before this one: `reeve-status --all` put the report on stderr and then
# three shell errors after it, two failed redirections and an mv with nothing to
# move, and left the errand unstamped anyway.
#
# So the write is guarded and the failure is said once, in the household's own
# voice. The line is written before any of this, so what a read only home costs
# is the memory of having reported, which is a duplicate later, never the report.
export REEVE_HOME="$SCRATCH/home13"
export REEVE_SESSION=readonly
mkdir -p "$REEVE_HOME/state"
errand frozen readonly "working: going" "done: report written"
leave readonly 'signal: frozen is done and its session was cleaned up with no reeve watching - report written' frozen 2
ERRF="$SCRATCH/err.frozen"
chmod a-w "$REEVE_HOME/state"
"$ROOT/bin/reeve-status" --all >/dev/null 2>"$ERRF"
NOISE=$(cat "$ERRF")
OUT2=$(REEVE_SESSION=readonly "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1)
chmod u+w "$REEVE_HOME/state"
has "13 the report still reaches the reeve"        "$NOISE" "frozen is done"
nas "13 with no shell error in the channel"        "$NOISE" "Permission denied"
nas "13 and nothing about a file that is not there" "$NOISE" "No such file or directory"
has "13 the home saying plainly what it could not do" "$NOISE" "could not record it"
eq  "13 and no half written count left behind"     "$(delivered_debris frozen)" 0
has "13 so the cost is the report repeated, not lost" "$OUT2" "frozen is done"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
