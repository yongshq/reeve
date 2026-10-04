#!/usr/bin/env bash
# Who a sentry is allowed to watch, report on, and clean up.
#
# One home is shared by every reeve on this machine, and before ownership a
# sentry listed every errand in it. Two reeves running at once therefore had
# each one reporting the other's errands as its own and then tearing them down.
#
# A scout is the case that cannot survive that, and case 2 is it: a scout
# commits nothing, so the landed-work guard in bin/reeve-teardown has nothing to
# refuse over, the copy is removed, and the owning reeve is never told. The
# guard that protects an artificer is structurally incapable of protecting a
# scout, which is why this is enforced by ownership rather than left to it.
#
# Scratch homes only, never the real one.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }

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

# A stubbed code root, so no session is ever opened and the kills are countable.
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
reeve_backend_stub_agent_state()     { printf '%s\n' "${STUB_STATE:-alive}"; }
reeve_backend_stub_attention_state() { printf 'settled\n'; }
reeve_backend_stub_wait_change()     { return 2; }
reeve_backend_stub_kill()            { printf '%s\n' "$1" >> "$STUB_KILLS"; return 0; }
ADAPTER
export REEVE_ROOT="$STUB"

# errand <id> <owning session, empty for none> <status line>...
# writes=no and no branch, so this is a scout: the office whose copy teardown
# will always agree to remove.
errand() {
  local id=$1 owner=$2; shift 2
  mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/errands/$id"
  # No worktree path: whether teardown removes a COPY is its own question, and
  # tests/teardown-landed.test.bash owns it. What is asserted here is who is
  # allowed to set teardown in motion at all.
  # dispatched= as every real errand carries it. It is what keeps an errand in
  # flight once its target has been blanked, so an errand seeded without it
  # would be asking a second question about legacy records.
  printf 'target=stub:1\nbackend=stub\noffice=scout\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=no\ndispatched=2026-09-28T20:25:26\nsession=%s\n' \
    "$owner" > "$REEVE_HOME/state/$id.meta"
  : > "$REEVE_HOME/errands/$id/status"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$REEVE_HOME/errands/$id/status"; done
}
meta_of() { grep -m1 "^$2=" "$REEVE_HOME/state/$1.meta" 2>/dev/null | sed "s/^$2=//"; }
reaped()  { [ -n "$(meta_of "$1" tornDown)" ] && printf 'yes\n' || printf 'no\n'; }
# One tick of a foreground watch, as session <s>.
watch_as() { REEVE_SESSION=$1 "$ROOT/bin/reeve-sentry" --once --poll 1 2>&1; }

echo "--- 1. a watch sees its own errands and no others ---"
export REEVE_HOME="$SCRATCH/home1"
mkdir -p "$REEVE_HOME/state"
errand mine  sess-A "working: going"
errand yours sess-B "working: going"

OUT=$(watch_as sess-A); RC=$?
eq  "1 session A has something in flight"   "$RC" 4
has "1 and it counts exactly one"           "$OUT" "1 errand(s) working"

OUT=$(watch_as sess-C); RC=$?
eq  "1 a third session sees nothing at all" "$RC" 3
has "1 and says so"                         "$OUT" "nothing in flight"

OUT=$(REEVE_SESSION=sess-C "$ROOT/bin/reeve-sentry" --once --all --poll 1 2>&1)
has "1 --all is the way to see the whole home" "$OUT" "2 errand(s) working"

echo "--- 2. THE INCIDENT: one reeve must not reap another's scout ---"
export REEVE_HOME="$SCRATCH/home2"
mkdir -p "$REEVE_HOME/state"
errand a-scout sess-A "working: reading the auth module" "done: the answer is in report.md"

# B is watching the same home at the same moment. Before ownership this is the
# tick that reported A's scout as B's and removed the copy.
OUT=$(watch_as sess-B); RC=$?
eq  "2 B has nothing of its own in flight"     "$RC" 3
nas "2 and never names A's errand"             "$OUT" "a-scout"
eq  "2 the scout is NOT torn down"             "$(reaped a-scout)" no
eq  "2 nor was its session freed"              "$(grep -cF 'stub:1' "$KILLS")" 0
eq  "2 and B left no cursor on it"             "$([ -e "$REEVE_HOME/state/.cursor-a-scout" ] && echo present || echo absent)" absent

# The wake is still there for its owner, which is the half that proves the
# report was not merely delayed but kept.
OUT=$(watch_as sess-A); RC=$?
eq  "2 A is told, on the very next tick"       "$RC" 0
has "2 and it is the done line"                "$OUT" "a-scout is done"
eq  "2 now it is cleaned up"                   "$(reaped a-scout)" yes

echo "--- 3. an errand nobody owns stays visible, so nothing is stranded ---"
# Errands briefed before ownership existed carry no session=, and a harness that
# exports no id writes none either. Making those invisible would strand them in
# the home with no reeve able to see them, so they are visible to every watch:
# honest degradation, not isolation. There is nothing to tell two reeves apart
# with, and pretending otherwise would be worse than saying so.
export REEVE_HOME="$SCRATCH/home3"
mkdir -p "$REEVE_HOME/state"
errand legacy '' "working: going"
OUT=$(watch_as sess-A); RC=$?
eq  "3 a session with an id still sees it"  "$RC" 4
OUT=$(REEVE_SESSION= CLAUDE_CODE_SESSION_ID= "$ROOT/bin/reeve-sentry" --once --poll 1 2>&1); RC=$?
eq  "3 and so does one with no id at all"   "$RC" 4

echo "--- 4. two watches, two markers, neither clobbering the other ---"
# A single .sentry.watch filename had the second publisher take the name from
# the first, whose marker_mine then read false: it stopped refreshing a marker
# it no longer owned, the marker went stale, and a caretaker began reaping out
# from under a watch that was still running.
export REEVE_HOME="$SCRATCH/home4"
mkdir -p "$REEVE_HOME/state"
errand ea sess-A "working: going"
errand eb sess-B "working: going"
REEVE_SESSION=sess-A "$ROOT/bin/reeve-sentry" --poll 1 --timeout 4 --no-reap >/dev/null 2>&1 &
WA=$!
REEVE_SESSION=sess-B "$ROOT/bin/reeve-sentry" --poll 1 --timeout 4 --no-reap >/dev/null 2>&1 &
WB=$!
n=0; while [ "$n" -lt 100 ]; do
  [ -f "$REEVE_HOME/state/.sentry.watch-sess-A" ] && [ -f "$REEVE_HOME/state/.sentry.watch-sess-B" ] && break
  sleep 0.05; n=$((n + 1))
done
eq "4 A published its own marker" "$([ -f "$REEVE_HOME/state/.sentry.watch-sess-A" ] && echo yes || echo no)" yes
eq "4 B published its own marker" "$([ -f "$REEVE_HOME/state/.sentry.watch-sess-B" ] && echo yes || echo no)" yes
eq "4 each marker names its own watcher" \
   "$(cut -d' ' -f1 "$REEVE_HOME/state/.sentry.watch-sess-A" 2>/dev/null) $(cut -d' ' -f1 "$REEVE_HOME/state/.sentry.watch-sess-B" 2>/dev/null)" \
   "$WA $WB"
wait "$WA" 2>/dev/null; wait "$WB" 2>/dev/null
eq "4 and both are taken away on the way out" \
   "$(ls "$REEVE_HOME/state" | grep -c '^\.sentry\.watch-' || true)" 0

echo "--- 5. session_state: a proof, an absence, and the difference ---"
# `dead` is a proof that a reeve is gone. `unknown` is the absence of one. Only
# a proof may ever authorise touching somebody's errand, so they are two answers
# and not one.
export REEVE_HOME="$SCRATCH/home5"
mkdir -p "$REEVE_HOME/state/sessions/fresh" "$REEVE_HOME/state/sessions/old"
date +%s > "$REEVE_HOME/state/sessions/fresh/seen"
printf '%s\n' "$(( $(date +%s) - 100000 ))" > "$REEVE_HOME/state/sessions/old/seen"
ask() { REEVE_HOME="$REEVE_HOME" bash -c '. "$0"/bin/reeve-lib.sh; session_state "$1"' "$ROOT" "$1"; }
eq "5 a session refreshed just now is alive"   "$(ask fresh)"  alive
eq "5 one that stopped refreshing is dead"     "$(ask old)"    dead
eq "5 one that never reported is unknown"      "$(ask ghost)"  unknown
eq "5 and so is no session at all"             "$(ask '')"     unknown

echo "--- 6. the caretaker cleans for anyone not watching, never under a watch ---"
# The caretaker sees the whole home on purpose: it exists for errands whose
# reeve is not watching. That makes the owner check load bearing rather than
# decorative: tearing an errand down under its owner's watch races that watch
# for the report.
#
# WATCHING, not alive. It used to stand aside for an owner whose session was
# merely alive, and a reeve is alive all day while its watch is a one shot, so a
# finished hand sat idle at its prompt between one watch and the next: four
# minutes once and fourteen once, measured in one home on one day, with this
# caretaker holding the lock throughout.
export REEVE_HOME="$SCRATCH/home6"
mkdir -p "$REEVE_HOME/state"
beat() { # beat <session> <seconds ago>
  mkdir -p "$REEVE_HOME/state/sessions/$1"
  printf '%s\n' "$(( $(date +%s) - $2 ))" > "$REEVE_HOME/state/sessions/$1/seen"
}
# watching <session> [<seconds of age>] [<poll>]   that session's watch marker,
# naming this process, which is the one pid certain to be alive.
watching() {
  printf '%s %s %s\n' "$$" "$(( $(date +%s) - ${2:-0} ))" "${3:-60}" \
    > "$REEVE_HOME/state/.sentry.watch-$1"
}
# spool <session>   every line waiting in that session's wake spool
spool() { cat "$REEVE_HOME/state/sessions/$1/wake"/* 2>/dev/null | sed -n 's/^say=//p'; }
care() { REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1; reaped "$1"; }

: > "$KILLS"
errand live-owned sess-live "working: x" "done: y"
beat sess-live 0
eq  "6 an owner alive and not watching has its hand cleaned up" "$(care live-owned)" yes
eq  "6 its session freed"                                       "$(grep -cF 'stub:1' "$KILLS")" 1
has "6 and the done line left in that owner's spool"            "$(spool sess-live)" "live-owned is done"

errand watched-owned sess-watch "working: x" "done: y"
beat sess-watch 0
watching sess-watch
eq  "6 an owner that is watching is left alone"     "$(care watched-owned)" no
eq  "6 its session is not even freed"               "$(meta_of watched-owned target)" stub:1
eq  "6 and nothing was left in its spool"           "$(spool sess-watch)" ''
rm -f "$REEVE_HOME/state/.sentry.watch-sess-watch"

errand dead-owned sess-dead "working: x" "done: y"
beat sess-dead 99999
eq "6 one that reported and stopped is cleaned up" "$(care dead-owned)" yes

# `unknown` permits, deliberately. A home whose sessions never report liveness
# keeps the behaviour it had before ownership existed rather than quietly
# losing its cleaner altogether.
errand never-owned sess-silent "working: x" "done: y"
eq "6 an owner that never reported is cleaned up too" "$(care never-owned)" yes

# An errand nobody owns is the one it must NOT finish. There is no spool to
# leave the report in, so removing the copy would write tornDown=, drop it out
# of live_errands, and leave that `done:` line in a status file no watch would
# ever look at again: the reviewed bug intact, for every home whose harness
# exports no session id. The idle session still goes, because that costs
# nothing and the errand stays in flight either way.
errand un-owned '' "working: x" "done: y"
eq "6 an errand nobody owns is not finished off"      "$(care un-owned)" no
eq "6 but its idle session is freed all the same"     "$(meta_of un-owned target)" ''
eq "6 and it is still there for the first reeve that watches" \
   "$(REEVE_SESSION=passerby "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1 | grep -c 'un-owned is done')" 1

# And with anybody at all watching, an unowned errand keeps the blanket rule it
# always had: there is no owner's marker to read, so any live one counts, and
# the caretaker touches nothing, not even the idle session.
errand un-owned-watched '' "working: x" "done: y"
watching passerby
eq "6 an unowned errand waits on any watch at all"  "$(care un-owned-watched)" no
eq "6 down to its session"                          "$(meta_of un-owned-watched target)" stub:1
rm -f "$REEVE_HOME/state/.sentry.watch-passerby"

# Never finished, whatever the markers say: a `blocked:` hand can still be
# steered and a question never answered means the errand is not done.
for w in no yes; do
  rm -f "$REEVE_HOME/state/.sentry.watch-sess-held"
  [ "$w" = yes ] && watching sess-held
  beat sess-held 0
  errand held-blocked-$w sess-held "working: x" "blocked: no .env"
  errand held-asking-$w  sess-held "needs-decision [key=k]: which?" "done: did it anyway"
  care held-blocked-$w >/dev/null
  eq "6 a blocked hand is never freed, owner watching=$w"     "$(reaped held-blocked-$w) $(meta_of held-blocked-$w target)" "no stub:1"
  eq "6 nor an open needs-decision, owner watching=$w"        "$(reaped held-asking-$w) $(meta_of held-asking-$w target)" "no stub:1"
done
rm -f "$REEVE_HOME/state/.sentry.watch-sess-held"

echo "--- 7. session records are pruned, but never one still answering for work ---"
# The statusline gauge writes a record for EVERY claude session on the machine,
# not only reeve ones, so this grows by one directory per session forever unless
# something clears it.
export REEVE_HOME="$SCRATCH/home7"
S="$REEVE_HOME/state/sessions"
mkdir -p "$S" "$REEVE_HOME/errands"
OLD=$(( $(date +%s) - 999999 ))
rec() { mkdir -p "$S/$1"; printf '%s\n' "$2" > "$S/$1/seen"; }
rec long-gone      "$OLD"
rec still-owed     "$OLD"
rec finished-owner "$OLD"
rec just-left      "$(date +%s)"
mkdir -p "$S/never-stamped"
printf 'target=t\nsession=still-owed\n' > "$REEVE_HOME/state/in-flight.meta"
printf 'target=t\nsession=finished-owner\ntornDown=2026-01-01\n' > "$REEVE_HOME/state/wrapped-up.meta"
gone() { [ -d "$S/$1" ] && printf 'kept\n' || printf 'pruned\n'; }
n=$(REEVE_SESSION=me bash -c '. "$0"/bin/reeve-lib.sh; sessions_prune' "$ROOT")

eq "7 it reports what it removed"                 "$n" 2
eq "7 an old record owning nothing goes"          "$(gone long-gone)" pruned
eq "7 so does one whose errand is finished"       "$(gone finished-owner)" pruned
eq "7 a recent record is kept"                    "$(gone just-left)" kept
eq "7 and one never stamped is judged by its age" "$(gone never-stamped)" kept

# The rule that matters. --orphans finds abandoned work by asking whether its
# OWNER is gone, and only a `dead` answer counts. Prune the record and the
# answer becomes `unknown`, which --orphans excludes: the errand would not be
# tidied away, it would become invisible while still in flight.
eq "7 a record still owning live work is NEVER pruned" "$(gone still-owed)" kept
printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$S/still-owed/seen"
out=$(REEVE_SESSION=me "$ROOT/bin/reeve-status" --orphans 2>&1)
has "7 so its errand is still findable afterwards" "$out" "in-flight"

# Deleting a record is not something to have to remember, so it rides along with
# the heartbeat, rate limited so it does not run behind every single call.
export REEVE_HOME="$SCRATCH/home8"
mkdir -p "$REEVE_HOME/state/sessions/stale-one"
printf '%s\n' "$OLD" > "$REEVE_HOME/state/sessions/stale-one/seen"
REEVE_SESSION=me "$ROOT/bin/reeve-status" >/dev/null 2>&1
eq "7 a reeve command clears out the long gone" \
   "$([ -d "$REEVE_HOME/state/sessions/stale-one" ] && echo kept || echo pruned)" pruned
mkdir -p "$REEVE_HOME/state/sessions/another-stale"
printf '%s\n' "$OLD" > "$REEVE_HOME/state/sessions/another-stale/seen"
REEVE_SESSION=me "$ROOT/bin/reeve-status" >/dev/null 2>&1
eq "7 and the next call within the hour does not scan again" \
   "$([ -d "$REEVE_HOME/state/sessions/another-stale" ] && echo kept || echo pruned)" kept

# An escape hatch, because a household may want the whole history.
export REEVE_HOME="$SCRATCH/home9"
mkdir -p "$REEVE_HOME/state/sessions/ancient" "$REEVE_HOME/config"
printf '%s\n' "$OLD" > "$REEVE_HOME/state/sessions/ancient/seen"
printf '0\n' > "$REEVE_HOME/config/session-retain"
n=$(REEVE_SESSION=me bash -c '. "$0"/bin/reeve-lib.sh; sessions_prune' "$ROOT")
eq "7 retain 0 keeps everything" \
   "$([ -d "$REEVE_HOME/state/sessions/ancient" ] && echo kept || echo pruned)" kept

echo "--- 8. two reeves, one watching and one not ---"
export REEVE_HOME="$SCRATCH/home10"
mkdir -p "$REEVE_HOME/state"
beat sess-A 0; beat sess-B 0
watching sess-A
errand a-done sess-A "working: x" "done: A's answer"
errand b-done sess-B "working: x" "done: B's answer"
REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1
eq  "8 the watching reeve's errand is left for its watch" "$(reaped a-done) $(meta_of a-done target)" "no stub:1"
eq  "8 the other reeve's is cleaned up"                   "$(reaped b-done) $(meta_of b-done target)" "yes "
has "8 with its line in B's spool"                        "$(spool sess-B)" "b-done is done"
eq  "8 and nothing in A's"                                "$(spool sess-A)" ''

echo "--- 9. a marker that goes stale under a live owner frees the hand next poll ---"
# The owner's session stays alive throughout. What changes is only its marker:
# believed for three polls and five seconds after its last refresh, so planted
# here four seconds short of that, it is live when the caretaker starts and
# stale a few seconds later, with nothing else touched in between.
export REEVE_HOME="$SCRATCH/home11"
mkdir -p "$REEVE_HOME/state"
beat sess-S 0
errand lapsed sess-S "working: x" "done: y"
watching sess-S 4 1                       # allowance 1*3+5 = 8s, so 4s left
expires=$(( $(date +%s) + 4 ))
REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --poll 1 >/dev/null 2>&1 &
CARE=$!
sleep 2
eq "9 not touched while the owner's marker is live" "$(reaped lapsed)" no
eq "9 and the caretaker is still standing by"       "$(kill -0 "$CARE" 2>/dev/null && echo alive || echo gone)" alive
n=0; while [ "$n" -lt 300 ] && [ "$(reaped lapsed)" = no ]; do sleep 0.05; n=$((n + 1)); done
freed_at=$(date +%s)
eq "9 freed once it went stale"                     "$(reaped lapsed)" yes
eq "9 and not before"                               "$([ "$freed_at" -ge "$expires" ] && echo after || echo before)" after
eq "9 with the owner's session alive throughout"    "$(REEVE_HOME="$REEVE_HOME" bash -c '. "$0"/bin/reeve-lib.sh; session_state sess-S' "$ROOT")" alive
kill "$CARE" 2>/dev/null; wait "$CARE" 2>/dev/null

echo "--- 10. done to freed is bounded by the caretaker's poll, with no watch at all ---"
# The measurement behind the whole change, asserted rather than described. No
# foreground watch runs, the owner is alive, and the time from the `done:` line
# to its session being freed is at most one poll of sleep plus one pass of work,
# with a second of slack for a loaded machine. Milliseconds, from perl, because
# `date +%s` would eat the margin being measured.
export REEVE_HOME="$SCRATCH/home12"
mkdir -p "$REEVE_HOME/state"
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
POLL=2
BOUND=$(( POLL * 1000 + 2000 ))
beat sess-T 0
errand timed sess-T "working: x"
: > "$KILLS"
REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --poll "$POLL" >/dev/null 2>&1 &
CARE=$!
n=0; while [ "$n" -lt 100 ] && [ ! -f "$REEVE_HOME/state/.sentry.lock" ]; do sleep 0.05; n=$((n + 1)); done
sleep 0.5                                 # into its sleep, so a whole poll is owed
t0=$(ms)
printf 'done: branch ready\n' >> "$REEVE_HOME/errands/timed/status"
n=0; while [ "$n" -lt 400 ] && ! grep -qF 'stub:1' "$KILLS"; do sleep 0.02; n=$((n + 1)); done
t1=$(ms)
took=$(( t1 - t0 ))
printf '        done to freed: %sms against a bound of %sms (poll %ss)\n' "$took" "$BOUND" "$POLL"
eq "10 the session was freed"                 "$(grep -cF 'stub:1' "$KILLS")" 1
eq "10 within one poll and one pass of done"  "$([ "$took" -le "$BOUND" ] && echo within || echo "over, ${took}ms")" within
has "10 and its owner was left the line"      "$(spool sess-T)" "timed is done"
kill "$CARE" 2>/dev/null; wait "$CARE" 2>/dev/null

echo "--- 11. the wake line says what teardown did, not what it hoped to do ---"
# A copy of bin with reeve-teardown stubbed, so each outcome is chosen rather
# than engineered. The errand has no copy on disk, the case that used to read
# `copy removed` whatever teardown answered.
export REEVE_HOME="$SCRATCH/home13"
mkdir -p "$REEVE_HOME/state"
FAKEBIN="$SCRATCH/bin13"
cp -R "$ROOT/bin" "$FAKEBIN"
cat > "$FAKEBIN/reeve-teardown" <<'STUBTD'
#!/usr/bin/env bash
meta="$REEVE_HOME/state/$1.meta"
case $STUB_TD in
  late|unlanded) sed 's/^target=.*/target=/' "$meta" > "$meta.t" && mv "$meta.t" "$meta" ;;
esac
case $STUB_TD in
  lock) printf 'reeve: could not take the lock\n' >&2; exit 4 ;;
  unlanded) printf 'reeve: REFUSED to tear down %s\n  feat/z has 2 commit(s) that main does not have.\n' \
          "$1" >&2
        exit 3 ;;
  *)    printf 'reeve: REFUSED to tear down %s\n  stub says no to %s.\n  Investigate.\n' \
          "$1" "$STUB_TD" >&2
        exit 1 ;;
esac
STUBTD
chmod +x "$FAKEBIN/reeve-teardown"
td_watch() { STUB_TD=$2 REEVE_SESSION=sess-R "$FAKEBIN/reeve-sentry" --once --poll 1 2>&1; }

errand early sess-R "working: x" "done: finished"
OUT=$(td_watch early early)
has "11 refused before freeing: the done line"    "$OUT" "early is done"
has "11 says the session was kept and why" \
  "$OUT" "[session kept, cleanup refused: stub says no to early.]"
nas "11 and never claims the copy was removed"    "$OUT" "copy removed"

errand late sess-R "working: x" "done: finished"
OUT=$(td_watch late late)
has "11 refused after freeing: says so" \
  "$OUT" "[session freed, cleanup refused: stub says no to late.]"
nas "11 and never claims the copy was removed"    "$OUT" "copy removed"

errand locked sess-R "working: x" "failed: gave up"
OUT=$(td_watch locked lock)
has "11 a lock not taken is deferred, not refused" \
  "$OUT" "[session kept, cleanup deferred: reeve: could not take the lock]"
nas "11 and never claims the copy was removed"     "$OUT" "copy removed"

# A target teardown left standing on a session already closed is gone, never kept.
errand closed sess-R "working: x" "done: finished"
OUT=$(STUB_STATE=missing td_watch closed early)
has "11 a closed session is gone, not kept" \
  "$OUT" "[session gone, cleanup refused: stub says no to early.]"
errand dead sess-R "working: x" "done: finished"
OUT=$(STUB_STATE=dead td_watch dead early)
has "11 and so is one whose harness has exited" \
  "$OUT" "[session gone, cleanup refused: stub says no to early.]"

# A copy still on disk: the refusal's reason, and deferred, said as above, so
# a teardown that could not judge reads apart from the ordinary keep.
oncopy() { sed "s|^worktree=.*|worktree=$SCRATCH/copy13|; s|^branch=.*|branch=${2:-}|" \
  "$REEVE_HOME/state/$1.meta" > "$REEVE_HOME/state/$1.meta.t" && mv "$REEVE_HOME/state/$1.meta.t" "$REEVE_HOME/state/$1.meta"; }
mkdir -p "$SCRATCH/copy13"
errand cbr sess-R "working: x" "done: finished"; oncopy cbr feat/x
OUT=$(td_watch cbr early)
has "11 a kept branch says why it was kept" \
  "$OUT" "[session kept, feat/x kept with ? commit(s), cleanup refused: stub says no to early.]"
errand ccp sess-R "working: x" "done: finished"; oncopy ccp
OUT=$(td_watch ccp late)
has "11 a kept copy says why it was kept" \
  "$OUT" "[session freed, copy kept, cleanup refused: stub says no to late.]"
errand clk sess-R "working: x" "failed: gave up"; oncopy clk feat/y
OUT=$(td_watch clk lock)
has "11 a kept copy whose lock was not taken is deferred" \
  "$OUT" "[session kept, feat/y kept with ? commit(s), cleanup deferred: reeve: could not take the lock]"
errand cgo sess-R "working: x" "done: finished"; oncopy cgo
OUT=$(STUB_STATE=missing td_watch cgo early)
has "11 a kept copy beside a closed session says gone" \
  "$OUT" "[session gone, copy kept, cleanup refused: stub says no to early.]"

# The routine artificer finish: teardown keeps the branch only because it has
# not landed yet (exit 3). That reads as the ordinary keep, never as a refusal,
# copy on disk or not. Any other refusal on a kept branch still says why, above.
errand cun sess-R "working: x" "done: finished"; oncopy cun feat/z
OUT=$(td_watch cun unlanded)
has "11 an unlanded branch is the ordinary keep" \
  "$OUT" "[session freed, feat/z kept with ? commit(s)]"
nas "11 and is never called refused"            "$OUT" "refused"
errand cnd sess-R "working: x" "done: finished"
sed "s|^branch=.*|branch=feat/z|" "$REEVE_HOME/state/cnd.meta" > "$REEVE_HOME/state/cnd.meta.t" \
  && mv "$REEVE_HOME/state/cnd.meta.t" "$REEVE_HOME/state/cnd.meta"
OUT=$(td_watch cnd unlanded)
has "11 an unlanded branch with no copy on disk is still kept" \
  "$OUT" "[session freed, feat/z kept with ? commit(s)]"
nas "11 and never claims the copy was removed"  "$OUT" "copy removed"
nas "11 nor calls it refused"                   "$OUT" "refused"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
