#!/usr/bin/env bash
# bin/reeve-watch-guard, the Stop hook that sends a reeve back when it ends a
# turn with an errand of its own in flight and no watch running. Fed fixture
# hook inputs, transcripts and errand records over a stub backend, no Claude
# Code involved:
#   1. a session with no reeve name passes, silently
#   2. a hand passes, even in a named session
#   3. a reeve with an errand in flight and no watch is sent back, once, with
#      Stop additionalContext naming the errand and reeve-sentry
#   4. a second stop in the same turn passes: stop_hook_active, and the claim
#      when two copies run or the flag is missing; a later turn is checked afresh
#   5. a watch running passes: a real sentry, this session's live marker, a
#      predecessor's marker that has not followed yet; a dead marker does not
#   6. nothing in flight passes: none, finished, torn down, never sent out,
#      another session's, nobody's
#   7. every unfinished state is in flight: blocked, an open question, a
#      divergence, no line yet
#   8. a stale errand (session dead or missing) is not in flight; unreadable is
#   9. a watch started this turn counts, however it ended; one from an earlier
#      turn, --once, --caretaker or a mere mention does not
#  10. a spool that cannot be delivered passes
#  11. malformed input or a missing tool passes: one stderr note for a reeve
#  12. the plugin and the clone both register it for Stop
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
G="$ROOT/bin/reeve-watch-guard"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]: $2" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output mentioned [$3]: $2" ;; *) ok "$1" ;; esac; }
BLOCK='"additionalContext": "In flight with no watch running'

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-watch-guard-test.XXXXXX") || exit 1
SCRATCH=$(cd -P "$SCRATCH" && pwd)
trap 'kill $(jobs -p) 2>/dev/null; chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

unset CLAUDE_CODE_SESSION_ID REEVE_HAND REEVE_SESSION STUB_STATE

# A stubbed code root, so no session is ever opened and liveness is ours to set.
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_launch()          { return 0; }
reeve_backend_stub_agent_state()     { printf '%s\n' "${STUB_STATE:-alive}"; }
reeve_backend_stub_attention_state() { printf 'settled\n'; }
reeve_backend_stub_wait_change()     { return 2; }
reeve_backend_stub_kill()            { return 0; }
ADAPTER
export REEVE_ROOT="$STUB"

# A PATH with every system tool but python3, so the guard gets as far as it can.
NOPY="$SCRATCH/nopy"; mkdir -p "$NOPY"
for t in /bin/* /usr/bin/*; do
  case ${t##*/} in python3*) continue ;; esac
  [ -e "$NOPY/${t##*/}" ] || ln -s "$t" "$NOPY/${t##*/}"
done

# fresh: a new home with a named reeve session and a nameless one.
fresh() {
  export REEVE_HOME="$SCRATCH/home$1"
  mkdir -p "$REEVE_HOME/state/sessions/reeve-sid" "$REEVE_HOME/state/sessions/plain-sid"
  printf 'Aldric\n' > "$REEVE_HOME/state/sessions/reeve-sid/name"
}
# errand <id> <owning session, empty for none> <status line>...
errand() {
  local id=$1 owner=$2 line; shift 2
  mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/errands/$id"
  printf 'target=stub:1\nbackend=stub\noffice=scout\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=no\ndispatched=2026-09-28T20:25:26\nsession=%s\n' \
    "$owner" > "$REEVE_HOME/state/$id.meta"
  : > "$REEVE_HOME/errands/$id/status"
  for line in "$@"; do printf '%s\n' "$line" >> "$REEVE_HOME/errands/$id/status"; done
}
meta_put() { printf '%s=%s\n' "$2" "$3" >> "$REEVE_HOME/state/$1.meta"; }

# transcript <file> <prompt uuid> [<earlier turn command>] [<this turn command>]
# An earlier turn, then the prompt that opens this one, a tool round trip and a
# closing reply. A command, when given, is a Bash tool call in its turn.
transcript() {
  python3 -c '
import json, sys
path, uuid, before, now = sys.argv[1:5]
def call(cmd, n):
    return [
      {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": n, "name": "Bash", "input": {"command": cmd, "run_in_background": True}}]}},
      {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": n, "content": "started"}]}},
    ]
rows = [{"type": "user", "uuid": "old", "message": {"role": "user", "content": "send a scout"}}]
if before:
    rows += call(before, "t0")
rows += [{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Out."}]}},
         {"type": "user", "uuid": uuid, "message": {"role": "user", "content": "how goes it"}},
         {"type": "user", "isMeta": True, "message": {"role": "user", "content": "<system-reminder>x</system-reminder>"}}]
if now:
    rows += call(now, "t1")
rows += [{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "My liege, still running."}]}}]
with open(path, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")' "$1" "$2" "${3:-}" "${4:-}"
}
# hook <sid> <transcript> [active]: a Stop hook input.
hook() {
  python3 -c '
import json, sys
print(json.dumps({"session_id": sys.argv[1], "hook_event_name": "Stop", "cwd": "/x",
                  "stop_hook_active": sys.argv[3] == "1", "transcript_path": sys.argv[2],
                  "last_assistant_message": "My liege, still running."}))' "$1" "$2" "${3:-0}"
}
# run <input>: sets OUT, ERR and RC. Claims are cleared first, so each case
# stands alone.
run() {
  rm -rf "$REEVE_HOME"/state/sessions/*/watch-guard.*
  OUT=$(printf '%s' "$1" | "$G" 2>"$SCRATCH/err"); RC=$?
  ERR=$(cat "$SCRATCH/err")
}
T="$SCRATCH/turn.jsonl"
transcript "$T" p-one

# --- 1. not a reeve ----------------------------------------------------------
fresh 1
errand e1 plain-sid "working: going"
run "$(hook plain-sid "$T")"
ck_eq '1 unnamed session: exit 0' "$RC" 0
ck_eq '1 unnamed session: no output' "$OUT" ''
ck_eq '1 unnamed session: no stderr' "$ERR" ''
run "$(hook nobody-sid "$T")"
ck_eq '1 session with no record: no output' "$OUT" ''
run "$(hook '../reeve-sid' "$T")"
ck_eq '1 unusable session id: no output' "$OUT" ''
in=$(hook plain-sid "$T")
OUT=$(PATH=$NOPY /bin/bash "$G" <<<"$in" 2>&1); RC=$?
ck_eq '1 stranger, no python3: nothing said' "$OUT" ''

# --- 2. a hand -----------------------------------------------------------------
fresh 2
errand e2 reeve-sid "working: going"
OUT=$(REEVE_HAND=e2 "$G" <<<"$(hook reeve-sid "$T")" 2>&1); RC=$?
ck_eq '2 hand in a named session: exit 0' "$RC" 0
ck_eq '2 hand in a named session: no output' "$OUT" ''

# --- 3. in flight, no watch ----------------------------------------------------
fresh 3
errand e3 reeve-sid "working: going"
run "$(hook reeve-sid "$T")"
ck_eq '3 in flight, no watch: exit 0' "$RC" 0
ck_has '3 in flight, no watch: sent back' "$OUT" "$BLOCK"
ck_has '3 names the errand' "$OUT" 'running: e3.'
ck_has '3 says start reeve-sentry in the background' "$OUT" 'Start reeve-sentry in the background now, before ending this turn'
ck_eq '3 no stderr' "$ERR" ''
ck_eq '3 Stop additionalContext, valid JSON, one line' \
  "$(printf '%s' "$OUT" | python3 -c '
import json, sys
o = json.load(sys.stdin)["hookSpecificOutput"]
print(o["hookEventName"], "\n" not in o["additionalContext"])')" 'Stop True'
ck_not '3 never decision block' "$OUT" '"decision"'
ck_eq '3 output is one line' "$(printf '%s\n' "$OUT" | grep -c .)" 1
errand e3b reeve-sid "working: also"
run "$(hook reeve-sid "$T")"
ck_has '3 two in flight: both named' "$OUT" 'running: e3, e3b.'

# --- 4. once per turn ------------------------------------------------------------
fresh 4
errand e4 reeve-sid "working: going"
run "$(hook reeve-sid "$T" 1)"
ck_eq '4 stop_hook_active: passes' "$OUT" ''
ck_eq '4 stop_hook_active: no stderr' "$ERR" ''
run "$(hook reeve-sid "$SCRATCH/absent.jsonl" 1)"
ck_eq '4 stop_hook_active, no transcript: passes' "$OUT" ''
ck_eq '4 stop_hook_active, no transcript: nothing read, no stderr' "$ERR" ''
rm -rf "$REEVE_HOME"/state/sessions/*/watch-guard.*
in=$(hook reeve-sid "$T")
OUT=$(printf '%s' "$in" | "$G" 2>&1)
ck_has '4 first stop of the turn: sent back' "$OUT" "$BLOCK"
OUT=$(printf '%s' "$in" | "$G" 2>&1)
ck_eq '4 second stop, same turn, no flag: passes' "$OUT" ''
OUT=$(printf '%s' "$(hook reeve-sid "$T" 1)" | "$G" 2>&1)
ck_eq '4 second stop, same turn, flag set: passes' "$OUT" ''
rm -rf "$REEVE_HOME"/state/sessions/*/watch-guard.*
printf '%s' "$in" | "$G" > "$SCRATCH/a" 2>&1 &
printf '%s' "$in" | "$G" > "$SCRATCH/b" 2>&1 &
wait
ck_eq '4 two copies on one stop: sent back once' "$(cat "$SCRATCH/a" "$SCRATCH/b" | grep -c "$BLOCK")" 1
transcript "$SCRATCH/turn2.jsonl" p-two
OUT=$(hook reeve-sid "$SCRATCH/turn2.jsonl" | "$G" 2>&1)
ck_has '4 a later turn: checked afresh' "$OUT" "$BLOCK"
for c in "$REEVE_HOME"/state/sessions/reeve-sid/watch-guard.*; do touch -t 200001010000 "$c"; done
transcript "$SCRATCH/turn3.jsonl" p-three
OUT=$(hook reeve-sid "$SCRATCH/turn3.jsonl" | "$G" 2>&1)
ck_has '4 another turn after old claims: sent back' "$OUT" "$BLOCK"
ck_eq '4 old claims are cleared' "$(ls -d "$REEVE_HOME"/state/sessions/reeve-sid/watch-guard.* | grep -c .)" 1

# --- 5. a watch running ------------------------------------------------------------
fresh 5
errand e5 reeve-sid "working: going"
REEVE_SESSION=reeve-sid "$ROOT/bin/reeve-sentry" --poll 1 --timeout 20 --no-reap >/dev/null 2>&1 &
W=$!
n=0
while [ ! -f "$REEVE_HOME/state/.sentry.watch-reeve-sid" ] && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n+1)); done
run "$(hook reeve-sid "$T")"
ck_eq '5 a real sentry watching: passes' "$OUT" ''
ck_eq '5 a real sentry watching: no stderr' "$ERR" ''
kill "$W" 2>/dev/null; wait "$W" 2>/dev/null
run "$(hook reeve-sid "$T")"
ck_has '5 that watch ended: sent back' "$OUT" "$BLOCK"
marker() { printf '%s %s 15\n' "$2" "$(date +%s)" > "$REEVE_HOME/state/.sentry.watch-$1"; }
marker reeve-sid $$
run "$(hook reeve-sid "$T")"
ck_eq '5 this session marker live: passes' "$OUT" ''
printf '%s %s 15\n' $$ 1000 > "$REEVE_HOME/state/.sentry.watch-reeve-sid"
run "$(hook reeve-sid "$T")"
ck_has '5 marker gone stale: sent back' "$OUT" "$BLOCK"
sh -c 'exit 0' & dead=$!; wait "$dead"
marker reeve-sid "$dead"
run "$(hook reeve-sid "$T")"
ck_has '5 marker of a dead watch: sent back' "$OUT" "$BLOCK"
rm -f "$REEVE_HOME/state/.sentry.watch-reeve-sid"
mkdir -p "$REEVE_HOME/state/sessions/old-sid"
printf 'reeve-sid\n' > "$REEVE_HOME/state/sessions/old-sid/successor"
marker old-sid $$
run "$(hook reeve-sid "$T")"
ck_eq '5 predecessor watch, not yet followed: passes' "$OUT" ''
marker other-sid $$
rm -f "$REEVE_HOME/state/.sentry.watch-old-sid"
run "$(hook reeve-sid "$T")"
ck_has '5 another session watching: sent back' "$OUT" "$BLOCK"

# --- 6. nothing in flight --------------------------------------------------------------
fresh 6
run "$(hook reeve-sid "$T")"
ck_eq '6 no errands at all: passes' "$OUT" ''
ck_eq '6 no errands at all: no stderr' "$ERR" ''
errand d6 reeve-sid "working: going" "done: landed"
errand f6 reeve-sid "working: going" "failed: no"
errand r6 reeve-sid "working: going" "needs-decision [key=a]: which?" "resolved [key=a]: this" "done: ok"
run "$(hook reeve-sid "$T")"
ck_eq '6 only finished errands: passes' "$OUT" ''
errand t6 reeve-sid "working: going"; meta_put t6 tornDown 2026-09-28T21:00:00
run "$(hook reeve-sid "$T")"
ck_eq '6 torn down: passes' "$OUT" ''
errand b6 reeve-sid "working: going"
sed -i.bak -e 's/^target=.*/target=/' -e 's/^dispatched=.*/dispatched=/' "$REEVE_HOME/state/b6.meta"
run "$(hook reeve-sid "$T")"
ck_eq '6 briefed, never sent out: passes' "$OUT" ''
errand o6 other-sid "working: going"
errand n6 '' "working: going"
run "$(hook reeve-sid "$T")"
ck_eq '6 another session and nobody: passes' "$OUT" ''

# --- 7. every unfinished state ------------------------------------------------------------
fresh 7
for c in 'blocked: no env' 'needs-decision [key=k]: which?' 'done: early|needs-decision [key=k]: which?' ''; do
  rm -f "$REEVE_HOME"/state/*.meta
  IFS='|' read -r a b <<<"$c"
  errand s7 reeve-sid ${a:+"$a"} ${b:+"$b"}
  run "$(hook reeve-sid "$T")"
  ck_has "7 [${c:-no line yet}]: sent back" "$OUT" "$BLOCK"
done

# --- 8. stale ------------------------------------------------------------------------------
fresh 8
errand s8 reeve-sid "working: going"
for st in dead missing; do
  OUT=$(STUB_STATE=$st "$G" <<<"$(hook reeve-sid "$T")" 2>&1)
  ck_eq "8 stale only, session $st: passes" "$OUT" ''
done
OUT=$(STUB_STATE=unreadable "$G" <<<"$(hook reeve-sid "$T")" 2>&1)
ck_has '8 session unreadable: still in flight' "$OUT" "$BLOCK"
rm -rf "$REEVE_HOME"/state/sessions/*/watch-guard.*
errand l8 reeve-sid "working: going"
sed -i.bak 's/^target=.*/target=stub:2/' "$REEVE_HOME/state/l8.meta"
cat >> "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_agent_state() { case $1 in stub:2) printf 'alive\n' ;; *) printf '%s\n' "${STUB_STATE:-alive}" ;; esac; }
ADAPTER
OUT=$(STUB_STATE=dead "$G" <<<"$(hook reeve-sid "$T")" 2>&1)
ck_has '8 stale and live together: sent back' "$OUT" "$BLOCK"
ck_has '8 naming only the live one' "$OUT" 'running: l8.'

# --- 9. a watch started this turn ------------------------------------------------------------
fresh 9
errand e9 reeve-sid "working: going"
for cmd in 'bin/reeve-sentry' 'reeve-sentry --poll 15' '"/Users/x/reeve"/bin/reeve-sentry --timeout 3600' \
           'cd /x && bin/reeve-sentry' 'REEVE_SESSION=s nohup bin/reeve-sentry'; do
  transcript "$SCRATCH/t9.jsonl" p-nine '' "$cmd"
  run "$(hook reeve-sid "$SCRATCH/t9.jsonl")"
  ck_eq "9 started this turn [$cmd]: passes" "$OUT" ''
done
transcript "$SCRATCH/t9.jsonl" p-nine 'bin/reeve-sentry' ''
run "$(hook reeve-sid "$SCRATCH/t9.jsonl")"
ck_has '9 started in an earlier turn only: sent back' "$OUT" "$BLOCK"
for cmd in 'bin/reeve-sentry --once' 'bin/reeve-sentry --caretaker' 'bin/reeve-sentry --help' \
           'grep -n reeve-sentry AGENTS.md' 'bin/reeve-sentryx' 'bin/reeve-status'; do
  transcript "$SCRATCH/t9.jsonl" p-nine '' "$cmd"
  run "$(hook reeve-sid "$SCRATCH/t9.jsonl")"
  ck_has "9 not a watch [$cmd]: sent back" "$OUT" "$BLOCK"
done

# --- 10. an undeliverable spool ----------------------------------------------------------------
fresh 10
errand e10 reeve-sid "working: going"
mkdir -p "$REEVE_HOME/state/sessions/reeve-sid/wake"
printf 'errand=e10\nlines=1\nsay=signal: x\n' > "$REEVE_HOME/state/sessions/reeve-sid/wake/1.1.00000"
run "$(hook reeve-sid "$T")"
ck_has '10 a deliverable spool: still sent back' "$OUT" "$BLOCK"
chmod a-w "$REEVE_HOME/state/sessions/reeve-sid/wake"
if [ -w "$REEVE_HOME/state/sessions/reeve-sid/wake" ]; then
  ok '10 spool stuck: skipped, cannot make a directory read only here'
else
  run "$(hook reeve-sid "$T")"
  ck_eq '10 spool stuck, every watch would exit at once: passes' "$OUT" ''
fi
chmod u+w "$REEVE_HOME/state/sessions/reeve-sid/wake"

# --- 11. malformed ---------------------------------------------------------------------------------
fresh 11
errand e11 reeve-sid "working: going"
for c in 'not json' '[1,2]' '{"stop_hook_active": false}' ''; do
  run "$c"
  ck_eq "11 [$c]: exit 0" "$RC" 0
  ck_eq "11 [$c]: no output" "$OUT" ''
  ck_eq "11 [$c]: no stderr" "$ERR" ''
done
for c in '{"session_id": "reeve-sid", "stop_hook_active": fals' \
         '{"session_id": "reeve-sid", "stop_hook_active": false}'; do
  run "$c"
  ck_eq "11 reeve [$c]: no output" "$OUT" ''
  ck_eq "11 reeve [$c]: one stderr line" "$(printf '%s\n' "$ERR" | grep -c 'reeve-watch-guard:')" 1
done
run "$(hook reeve-sid "$SCRATCH/absent.jsonl")"
ck_eq '11 missing transcript: no output' "$OUT" ''
ck_has '11 missing transcript: said' "$ERR" 'not checked'
printf 'garbage\n' > "$SCRATCH/garbage.jsonl"
run "$(hook reeve-sid "$SCRATCH/garbage.jsonl")"
ck_eq '11 garbage transcript: no output' "$OUT" ''
ck_has '11 garbage transcript: said' "$ERR" 'not checked'
in=$(hook reeve-sid "$T")
OUT=$(PATH=$NOPY /bin/bash "$G" <<<"$in" 2>"$SCRATCH/err"); RC=$?
ck_eq '11 no python3: exit 0' "$RC" 0
ck_eq '11 no python3: no output' "$OUT" ''
ck_has '11 no python3: said' "$(cat "$SCRATCH/err")" 'python3'

# --- 12. registrations -------------------------------------------------------------------------------
for f in hooks/hooks.json .claude/settings.json; do
  cmd=$(python3 -c '
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]["Stop"]
print("\n".join(x["command"] for e in h for x in e["hooks"]))' "$ROOT/$f" 2>/dev/null)
  ck_has "12 $f registers the guard for Stop" "$cmd" '/bin/reeve-watch-guard'
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
