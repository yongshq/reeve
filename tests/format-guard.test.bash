#!/usr/bin/env bash
# bin/reeve-format-guard, the Stop hook that sends a reeve back when its reply
# misses the AGENTS.md section 8 report shape. Fed fixture hook inputs and
# transcripts, no Claude Code involved:
#   1. a session with no reeve name passes, silently
#   2. a hand passes, even in a named session
#   3. a reeve reply with both blocks passes, from the hook field or transcript
#   4. a reeve reply missing either, or both, is blocked with JSON naming it
#   5. stop_hook_active passes, whatever the reply says
#   6. malformed input passes, with one stderr note
#   7. two copies on one reply (plugin and project settings) block once
#   8. the plugin and the clone both register it for Stop
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
G="$ROOT/bin/reeve-format-guard"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]: $2" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output mentioned [$3]: $2" ;; *) ok "$1" ;; esac; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-format-guard-test.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

unset CLAUDE_CODE_SESSION_ID REEVE_HAND REEVE_SESSION
export REEVE_HOME="$SCRATCH/home"
mkdir -p "$REEVE_HOME/state/sessions/reeve-sid" "$REEVE_HOME/state/sessions/plain-sid"
printf 'Aldric\n' > "$REEVE_HOME/state/sessions/reeve-sid/name"

GOOD='My liege, the fix landed.

**Done this session**
- Lantern: upload fix built.

**Next action.** Yours: nothing waits.'
NO_DONE='My liege, the fix landed.

**Next action.** Yours: nothing waits.'
NO_NEXT='My liege, the fix landed.

**Done this session**
- Lantern: upload fix built.'

# hook <sid> <reply> [active] [transcript]: a Stop hook input, built by python
# so any reply quotes cleanly.
hook() {
  python3 -c '
import json, sys
h = {"session_id": sys.argv[1], "hook_event_name": "Stop", "cwd": "/x",
     "stop_hook_active": sys.argv[3] == "1", "transcript_path": sys.argv[4]}
if sys.argv[2]:
    h["last_assistant_message"] = sys.argv[2]
print(json.dumps(h))' "$1" "$2" "${3:-0}" "${4:-}"
}
# transcript <file> <final reply>: an earlier turn, a tool round trip, then the
# final reply split over two assistant entries the way Claude Code writes them.
transcript() {
  python3 -c '
import json, sys
half = sys.argv[2].split("\n\n", 1)
rows = [
  {"type": "user", "message": {"role": "user", "content": "earlier"}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "**Done this session**\n**Next action.** old"}]}},
  {"type": "user", "message": {"role": "user", "content": "now"}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]}},
  {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "x"}]}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": half[0]}]}},
  {"type": "system", "content": "noise"},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": half[1] if len(half) > 1 else ""}]}},
]
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")' "$1" "$2"
}
# run <input>: sets OUT, ERR and RC. Claims are cleared first, so each case
# stands alone.
run() {
  rm -rf "$REEVE_HOME"/state/sessions/*/format-guard.*
  OUT=$(printf '%s' "$1" | "$G" 2>"$SCRATCH/err"); RC=$?
  ERR=$(cat "$SCRATCH/err")
}

# --- 1. not a reeve ----------------------------------------------------------
run "$(hook plain-sid "$NO_DONE")"
ck_eq '1 unnamed session: exit 0' "$RC" 0
ck_eq '1 unnamed session: no output' "$OUT" ''
ck_eq '1 unnamed session: no stderr' "$ERR" ''
run "$(hook nobody-sid "$NO_DONE")"
ck_eq '1 session with no record: no output' "$OUT" ''
run "$(hook '../reeve-sid' "$NO_DONE")"
ck_eq '1 unusable session id: no output' "$OUT" ''

# --- 2. a hand -----------------------------------------------------------------
OUT=$(REEVE_HAND=fix-1 "$G" <<<"$(hook reeve-sid "$NO_DONE")" 2>&1); RC=$?
ck_eq '2 hand: exit 0' "$RC" 0
ck_eq '2 hand: no output' "$OUT" ''

# --- 3. both present -----------------------------------------------------------
run "$(hook reeve-sid "$GOOD")"
ck_eq '3 good reply: exit 0' "$RC" 0
ck_eq '3 good reply: no output' "$OUT" ''
ck_eq '3 good reply: no stderr' "$ERR" ''
run "$(hook reeve-sid '## Done this session
- x

### Next action
Yours.')"
ck_eq '3 markdown headings count' "$OUT" ''
run "$(hook reeve-sid '**Done this session**
- x
**Next action:** mine, report it.')"
ck_eq '3 "Next action:" form counts' "$OUT" ''
transcript "$SCRATCH/good.jsonl" "$GOOD"
run "$(hook reeve-sid '' 0 "$SCRATCH/good.jsonl")"
ck_eq '3 good reply from transcript: no output' "$OUT" ''
ck_eq '3 good reply from transcript: no stderr' "$ERR" ''

# --- 4. missing ---------------------------------------------------------------
run "$(hook reeve-sid "$NO_DONE")"
ck_eq '4 no Done: exit 0' "$RC" 0
ck_has '4 no Done: blocks' "$OUT" '"decision": "block"'
ck_has '4 no Done: names it' "$OUT" 'missing **Done this session**.'
ck_has '4 no Done: points at section 8' "$OUT" 'AGENTS.md section 8'
ck_eq '4 no Done: valid JSON' \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"])')" block
run "$(hook reeve-sid "$NO_NEXT")"
ck_has '4 no Next: blocks' "$OUT" '"decision": "block"'
ck_has '4 no Next: names it' "$OUT" 'missing **Next action**.'
ck_not '4 no Next: Done not named' "$OUT" 'missing **Done this session**'
run "$(hook reeve-sid 'My liege, done.')"
ck_has '4 neither: names both' "$OUT" 'missing **Done this session** and **Next action**.'
run "$(hook reeve-sid 'Done this session, and the Next action is mine.')"
ck_has '4 words in prose do not count' "$OUT" '"decision": "block"'
transcript "$SCRATCH/bad.jsonl" "$NO_NEXT"
run "$(hook reeve-sid '' 0 "$SCRATCH/bad.jsonl")"
ck_has '4 from transcript: only the final reply counts' "$OUT" 'missing **Next action**.'

# --- 5. stop_hook_active --------------------------------------------------------
run "$(hook reeve-sid 'My liege, done.' 1)"
ck_eq '5 active: exit 0' "$RC" 0
ck_eq '5 active: no output' "$OUT" ''
run "$(hook reeve-sid '' 1)"
ck_eq '5 active, no reply at all: no output' "$OUT" ''
ck_eq '5 active, no reply at all: no stderr' "$ERR" ''

# --- 6. malformed -----------------------------------------------------------------
for c in 'not json' '[1,2]' '{"stop_hook_active": false}' ''; do
  run "$c"
  ck_eq "6 [$c]: exit 0" "$RC" 0
  ck_eq "6 [$c]: no output" "$OUT" ''
  ck_eq "6 [$c]: one stderr line" "$(printf '%s\n' "$ERR" | grep -c 'reeve-format-guard:')" 1
done
run "$(hook reeve-sid '' 0 "$SCRATCH/absent.jsonl")"
ck_eq '6 missing transcript: no output' "$OUT" ''
ck_has '6 missing transcript: said' "$ERR" 'not checked'
printf 'garbage\n' > "$SCRATCH/garbage.jsonl"
run "$(hook reeve-sid '' 0 "$SCRATCH/garbage.jsonl")"
ck_eq '6 garbage transcript: no output' "$OUT" ''
ck_has '6 garbage transcript: said' "$ERR" 'not checked'
in=$(hook reeve-sid "$NO_DONE")
OUT=$(PATH=/nonexistent /bin/bash "$G" <<<"$in" 2>"$SCRATCH/err"); RC=$?
ck_eq '6 no python3: exit 0' "$RC" 0
ck_eq '6 no python3: no output' "$OUT" ''
ck_has '6 no python3: said' "$(cat "$SCRATCH/err")" 'python3'

# --- 7. two copies, one block ----------------------------------------------------
rm -rf "$REEVE_HOME"/state/sessions/*/format-guard.*
in=$(hook reeve-sid "$NO_DONE")
printf '%s' "$in" | "$G" > "$SCRATCH/a" 2>&1 &
printf '%s' "$in" | "$G" > "$SCRATCH/b" 2>&1 &
wait
n=$(cat "$SCRATCH/a" "$SCRATCH/b" | grep -c '"decision": "block"')
ck_eq '7 concurrent copies: one block' "$n" 1
OUT=$(printf '%s' "$in" | "$G" 2>&1)
ck_eq '7 a late copy on the same reply: passes' "$OUT" ''
for c in "$REEVE_HOME"/state/sessions/reeve-sid/format-guard.*; do touch -t 200001010000 "$c"; done
OUT=$(printf '%s' "$in" | "$G" 2>&1)
ck_has '7 the same reply in a later turn: blocked again' "$OUT" '"decision": "block"'
OUT=$(hook reeve-sid "$NO_NEXT" | "$G" 2>&1)
ck_has '7 a different reply: blocked on its own' "$OUT" 'missing **Next action**.'

# --- 8. registrations ------------------------------------------------------------
for f in hooks/hooks.json .claude/settings.json; do
  cmd=$(python3 -c '
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]["Stop"]
print("\n".join(x["command"] for e in h for x in e["hooks"]))' "$ROOT/$f" 2>/dev/null)
  ck_has "8 $f registers the guard for Stop" "$cmd" '/bin/reeve-format-guard'
done
ck_has '8 the plugin copy runs from the plugin root' \
  "$(cat "$ROOT/hooks/hooks.json")" '${CLAUDE_PLUGIN_ROOT}'
ck_has '8 the clone copy runs from the project dir' \
  "$(cat "$ROOT/.claude/settings.json")" '${CLAUDE_PROJECT_DIR}'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
