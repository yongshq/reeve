#!/usr/bin/env bash
# bin/reeve-session-end and bin/reeve-session-start, the hooks that carry a
# reeve across /clear, exit and resume, and the successor record behind them.
# Fixture hook inputs and transcripts, no Claude Code and no backend involved:
#   1. the digest: last 30 liege messages, oldest first, replies cut to
#      Opening, Waiting on you and Next action, no tool calls or results,
#      notifications kept short, caps on each message and the whole
#   2. session-end: silent, a trail for a reeve only, keyed by pane, else cwd,
#      and the chain of transcripts carried on
#   3. session-start: nothing for a hand, a stranger, a stale trail or a
#      resume of another session; for the next session the successor, the
#      name, the errands, the watch, the handoff and the digest; one copy wins
#   3b. after anything but /clear an offer only, until --resume takes it
#   3c. a session seen again, by a resume elsewhere or its heartbeat, is never
#      taken over: its trail goes, and nobody takes its name or errands
#   3d. a name live again on another pane is never offered or resumed, but
#      the reeve's own earlier sessions are no rival (chained /clear)
#   4. the successor record: adopt, name and the sentry all honour it, until
#      the old session is seen again
#   5. both registrations, with their matcher and short timeouts
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
END="$ROOT/bin/reeve-session-end"
START="$ROOT/bin/reeve-session-start"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]: $(printf '%s' "$2" | head -c 600)" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output mentioned [$3]" ;; *) ok "$1" ;; esac; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-session-resume-test.XXXXXX") || exit 1
SCRATCH=$(cd -P "$SCRATCH" && pwd)
trap 'rm -rf "$SCRATCH"' EXIT

# Whatever session, pane or hand this suite itself runs in is not the one
# under test.
unset CLAUDE_CODE_SESSION_ID REEVE_HAND REEVE_SESSION REEVE_NAME \
  HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID

# A stubbed code root, so no backend is ever asked anything real.
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_launch()          { return 0; }
reeve_backend_stub_agent_state()     { printf 'alive\n'; }
reeve_backend_stub_attention_state() { printf 'settled\n'; }
reeve_backend_stub_wait_change()     { return 2; }
reeve_backend_stub_kill()            { return 0; }
ADAPTER
export REEVE_ROOT="$STUB"

fresh_home() {
  export REEVE_HOME="$SCRATCH/$1"
  mkdir -p "$REEVE_HOME/state/sessions" "$REEVE_HOME/config"
  printf 'stub\n' > "$REEVE_HOME/config/backend"
}
# reeve <sid> <name> [<pane>]: a session record holding a reeve name, seen now
reeve() {
  local d="$REEVE_HOME/state/sessions/$1"
  mkdir -p "$d"
  printf '%s\n' "$2" > "$d/name"
  date +%s > "$d/seen"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$d/pane"
  return 0
}
# hook <event> <sid> <transcript> [<source or reason>] [<cwd>]
hook() {
  python3 -c '
import json, sys
ev, sid, tp, extra, cwd = sys.argv[1:6]
h = {"session_id": sid, "transcript_path": tp, "cwd": cwd, "hook_event_name": ev}
h["reason" if ev == "SessionEnd" else "source"] = extra
print(json.dumps(h))' "$1" "$2" "$3" "${4:-clear}" "${5:-$SCRATCH/work}" 2>/dev/null
}
mkdir -p "$SCRATCH/work"
trails() { ls "$REEVE_HOME/state/trails" 2>/dev/null | grep -vc '\.taken\.' ; }
ctx_of() { printf '%s' "$1" | python3 -c '
import json, sys
o = json.load(sys.stdin)["hookSpecificOutput"]
assert o["hookEventName"] == "SessionStart"
print(o["additionalContext"])' 2>/dev/null; }

# --- fixture transcript --------------------------------------------------------
# fixture <file> <prompts>: per prompt a tool round trip with output nobody
# should see, a reply in the report shape, and every fifth one a background
# notification. Plus Claude Code's own meta, a /clear and command output.
fixture() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, n = sys.argv[1], int(sys.argv[2])
rows = []
ts = lambda i: "2021-10-07T10:%02d:%02dZ" % (i // 60, i % 60)
def user(c, i, **kw):
    r = {"type": "user", "timestamp": ts(i), "message": {"role": "user", "content": c}}
    r.update(kw); return r
def asst(blocks, i):
    return {"type": "assistant", "timestamp": ts(i), "message": {"role": "assistant", "content": blocks}}
rows.append(user("<local-command-caveat>Caveat</local-command-caveat>", 0, isMeta=True))
rows.append(user("<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>", 0))
rows.append(user("<local-command-stdout>LOCAL-STDOUT</local-command-stdout>", 0))
for k in range(1, n + 1):
    i = k * 2
    rows.append(user("liege prompt %02d: please do thing %02d" % (k, k), i))
    rows.append(asst([{"type": "text", "text": "Looking into it."}], i))
    rows.append(asst([{"type": "tool_use", "id": "t%d" % k, "name": "Bash", "input": {"command": "TOOL-INPUT-%02d" % k}}], i))
    rows.append(user([{"type": "tool_result", "tool_use_id": "t%d" % k, "content": "TOOL-OUTPUT-%02d" % k}], i))
    rows.append(user("<system-reminder>META-%02d</system-reminder>" % k, i, isMeta=True))
    rows.append(asst([{"type": "thinking", "thinking": "THINKING-%02d" % k}], i))
    rows.append(asst([{"type": "text", "text":
        "My liege, opening %02d.\n\n**Done this session**\n- DONE-ITEM-%02d\n\n**Lantern**\n1. GROUP-ITEM-%02d\n\n"
        "**My side**\n- MYSIDE-%02d\n\n**Waiting on you**\n\nLantern:\n\n1. WAIT-ITEM-%02d?\n\n"
        "**Next action.** Yours: NEXT-%02d." % (k, k, k, k, k, k)}], i + 1))
    if k % 5 == 0:
        rows.append(user("<task-notification>\n<task-id>x</task-id>\n<status>completed</status>\n"
                         "<summary>NOTE-%02d finished</summary>\n<output-file>/tmp/OUTFILE</output-file>\n"
                         "</task-notification>" % k, i + 1))
        rows.append(asst([{"type": "text", "text": "My liege, NOTE-REPLY-%02d.\n\n**Done this session**\n- x\n\n**Next action.** Mine: wait." % k}], i + 1))
rows.append(user([{"type": "text", "text": "a picture"}, {"type": "image", "source": {}}], 9999))
rows.append(asst([{"type": "text", "text": "Plain reply without the shape, first paragraph.\n\nSECOND-PARAGRAPH"}], 9999))
with open(path, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
}

echo '--- 1. digest ---'
fixture "$SCRATCH/t1.jsonl" 34
D=$("$START" --digest "$SCRATCH/t1.jsonl")
ck_eq '1 thirty liege messages' "$(printf '%s\n' "$D" | grep -c '^\[liege\]')" 30
ck_not '1 the oldest beyond thirty dropped' "$D" 'liege prompt 05:'
ck_has '1 the thirtieth newest kept' "$D" 'liege prompt 06:'
ck_has '1 liege verbatim' "$D" '[liege] liege prompt 34: please do thing 34'
ck_has '1 the newest last' "$(printf '%s\n' "$D" | tail -n 1)" 'Plain reply without the shape'
first=$(printf '%s\n' "$D" | grep -n 'liege prompt 20:' | cut -d: -f1)
second=$(printf '%s\n' "$D" | grep -n 'liege prompt 21:' | cut -d: -f1)
if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then ok '1 oldest first'; else bad '1 oldest first' "20 at $first, 21 at $second"; fi
for x in TOOL-OUTPUT TOOL-INPUT THINKING META- LOCAL-STDOUT Caveat /clear OUTFILE; do
  ck_not "1 no $x" "$D" "$x"
done
ck_has '1 Opening kept' "$D" 'My liege, opening 34.'
ck_has '1 Waiting on you kept, with its label' "$D" '**Waiting on you**

Lantern:

1. WAIT-ITEM-34?'
ck_has '1 Next action kept' "$D" '**Next action.** Yours: NEXT-34.'
for x in DONE-ITEM GROUP-ITEM MYSIDE 'Looking into it'; do
  ck_not "1 reply trimmed: no $x" "$D" "$x"
done
ck_has '1 notification by its summary' "$D" '[notification] NOTE-30 finished'
ck_has '1 a reply to a notification kept' "$D" 'NOTE-REPLY-30'
ck_has '1 an image noted' "$D" '[liege] a picture
[image]'
ck_has '1 a reply without the shape: its first paragraph' "$D" '[reeve] Plain reply without the shape, first paragraph.'
ck_not '1 ... and only that' "$D" 'SECOND-PARAGRAPH'
# The chain: an older transcript first.
fixture "$SCRATCH/t0.jsonl" 3
D=$("$START" --digest "$SCRATCH/t0.jsonl" "$SCRATCH/t1.jsonl")
ck_has '1 a chain reads oldest transcript first' "$(printf '%s\n' "$D" | head -n 1)" 'liege prompt 06:'
fixture "$SCRATCH/t2.jsonl" 3
D=$("$START" --digest "$SCRATCH/t2.jsonl")
ck_has '1 a short chain keeps everything' "$D" 'liege prompt 01:'
# Caps: one huge message, and a total over about 6k tokens.
python3 - "$SCRATCH/big.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for k in range(30):
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content": ("BIG%02d " % k) + "x" * 5000}}) + "\n")
        f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "My liege, r%02d. " % k + "y" * 5000}]}}) + "\n")
PY
D=$("$START" --digest "$SCRATCH/big.jsonl")
n=$(printf '%s' "$D" | wc -c | tr -d ' ')
if [ "$n" -le 24500 ]; then ok "1 total capped ($n chars)"; else bad '1 total capped' "$n chars"; fi
ck_has '1 a long message cut, marked' "$D" ' [...]'
ck_has '1 the cap drops the oldest, keeps the newest' "$(printf '%s\n' "$D" | tail -n 2)" 'r29'
ck_not '1 ... the oldest gone' "$D" 'BIG00'
ck_eq '1 an unreadable transcript: empty' "$("$START" --digest "$SCRATCH/absent.jsonl")" ''
printf 'not json\n{"type": "user"\n' > "$SCRATCH/junk.jsonl"
ck_eq '1 a garbage transcript: empty' "$("$START" --digest "$SCRATCH/junk.jsonl")" ''
# One malformed entry costs that entry, not the digest.
python3 - "$SCRATCH/odd.jsonl" <<'PY'
import json, sys
rows = [{"type": "user", "message": {"role": "user", "content": "GOOD-ONE"}},
        {"type": "assistant", "message": "oops"},
        {"type": "user", "message": "also oops"},
        {"type": "assistant", "message": {"content": 7}},
        {"type": "user", "message": {"role": "user", "content": "GOOD-TWO"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "My liege, REPLY-TWO."}]}}]
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
D=$("$START" --digest "$SCRATCH/odd.jsonl" 2>&1)
ck_has '1 a malformed entry: the one before kept' "$D" '[liege] GOOD-ONE'
ck_has '1 a malformed entry: the one after kept' "$D" '[liege] GOOD-TWO'
ck_has '1 a malformed entry: its reply kept' "$D" 'REPLY-TWO'

echo '--- 2. session-end ---'
fresh_home home2
reeve old-sid Aldric
mkdir -p "$REEVE_HOME/state/sessions/plain-sid"
OUT=$(hook SessionEnd plain-sid "$SCRATCH/t1.jsonl" | "$END" 2>&1); RC=$?
ck_eq '2 stranger: exit 0' "$RC" 0
ck_eq '2 stranger: silent' "$OUT" ''
ck_eq '2 stranger: no trail' "$(trails)" 0
OUT=$(hook SessionEnd old-sid "$SCRATCH/t1.jsonl" | REEVE_HAND=x "$END" 2>&1)
ck_eq '2 hand: silent' "$OUT" ''
ck_eq '2 hand: no trail' "$(trails)" 0
OUT=$(printf 'garbage' | "$END" 2>&1); RC=$?
ck_eq '2 garbage: exit 0, silent' "$RC:$OUT" '0:'
OUT=$(hook SessionEnd old-sid "$SCRATCH/t1.jsonl" clear | "$END" 2>&1); RC=$?
ck_eq '2 reeve: exit 0' "$RC" 0
ck_eq '2 reeve: silent' "$OUT" ''
ck_eq '2 reeve, no pane: one trail' "$(trails)" 1
T=$(cat "$REEVE_HOME/state/trails/"* 2>/dev/null)
ck_has '2 keyed by cwd' "$T" "key=cwd $SCRATCH/work"
ck_has '2 session' "$T" 'session=old-sid'
ck_has '2 name' "$T" 'name=Aldric'
ck_has '2 reason' "$T" 'reason=clear'
ck_has '2 transcript' "$T" "transcript=$SCRATCH/t1.jsonl"
rm -rf "$REEVE_HOME/state/trails"
OUT=$(hook SessionEnd old-sid "$SCRATCH/t1.jsonl" | HERDR_PANE_ID=w1:p2 "$END" 2>&1)
T=$(cat "$REEVE_HOME/state/trails/"* 2>/dev/null)
ck_has '2 inside herdr: keyed by pane' "$T" 'key=pane w1:p2'
ck_eq '2 inside herdr: one trail only' "$(trails)" 1
rm -rf "$REEVE_HOME/state/trails"
printf '%s\n%s\n' "$SCRATCH/a.jsonl" "$SCRATCH/b.jsonl" > "$REEVE_HOME/state/sessions/old-sid/resumed-from"
hook SessionEnd old-sid "$SCRATCH/c.jsonl" | "$END"
ck_eq '2 the chain: resumed-from, then its own' \
  "$(sed -n 's/^transcript=//p' "$REEVE_HOME/state/trails/"* | tr '\n' ' ')" \
  "$SCRATCH/a.jsonl $SCRATCH/b.jsonl $SCRATCH/c.jsonl "
printf '%s\n%s\n%s\n' "$SCRATCH/z.jsonl" "$SCRATCH/a.jsonl" "$SCRATCH/b.jsonl" > "$REEVE_HOME/state/sessions/old-sid/resumed-from"
hook SessionEnd old-sid "$SCRATCH/c.jsonl" | "$END"
ck_eq '2 the chain keeps the last three' \
  "$(sed -n 's/^transcript=//p' "$REEVE_HOME/state/trails/"* | tr '\n' ' ')" \
  "$SCRATCH/a.jsonl $SCRATCH/b.jsonl $SCRATCH/c.jsonl "
rm -f "$REEVE_HOME/state/sessions/old-sid/resumed-from"
# Two copies on one end (plugin and project settings): still one trail.
in=$(hook SessionEnd old-sid "$SCRATCH/t1.jsonl")
printf '%s' "$in" | "$END" & printf '%s' "$in" | "$END" & wait
ck_eq '2 two copies: one trail' "$(trails)" 1

echo '--- 3. session-start ---'
# A new session after /clear, outside herdr: errands of the old session, one
# under another reeve's name, a handoff written since.
setup3() {
  fresh_home "$1"
  reeve old-sid Aldric
  mkdir -p "$REEVE_HOME/errands/e1" "$REEVE_HOME/errands/e2" "$REEVE_HOME/handoffs"
  printf 'office=scout\nbackend=stub\ndispatched=2026-10-07T10:00:00\nsession=old-sid\nreeve=Aldric\n' > "$REEVE_HOME/state/e1.meta"
  printf 'office=scout\nbackend=stub\ndispatched=2026-10-07T10:00:00\nsession=gone-sid\nreeve=Bran\n' > "$REEVE_HOME/state/e2.meta"
  printf 'working: started\n' > "$REEVE_HOME/errands/e1/status"
  printf 'working: started\n' > "$REEVE_HOME/errands/e2/status"
  mkdir -p "$REEVE_HOME/state/sessions/gone-sid"
  printf '1\n' > "$REEVE_HOME/state/sessions/gone-sid/seen"
  hook SessionEnd old-sid "$SCRATCH/t1.jsonl" "${2:-clear}" | "$END"
  printf '# Handoff\n\n- **Reeve:** Aldric\n' > "$REEVE_HOME/handoffs/reeve-2026-10-07-1200.md"
}
setup3 home3
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | REEVE_HAND=x "$START" 2>&1)
ck_eq '3 hand: silent' "$OUT" ''
ck_eq '3 hand: trail left' "$(trails)" 1
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear "$SCRATCH" | "$START" 2>&1)
ck_eq '3 another directory: silent' "$OUT" ''
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | HERDR_PANE_ID=w9:p9 "$START" 2>&1)
ck_has '3 a pane with no trail of its own falls back to the directory' "$(ctx_of "$OUT")" 'Reeve resume'
setup3 home3b
OUT=$(hook SessionStart other-sid "$SCRATCH/x.jsonl" resume | "$START" 2>&1)
ck_eq '3 resume of another session: silent' "$OUT" ''
ck_eq '3 resume of another session: trail left' "$(trails)" 1
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" compact | "$START" 2>&1)
ck_eq '3 compact: silent' "$OUT" ''
printf '60\n' > "$REEVE_HOME/config/resume-window"
sed -i.bak 's/^ended=.*/ended=1/' "$REEVE_HOME/state/trails/"*; rm -f "$REEVE_HOME/state/trails/"*.bak
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)
ck_eq '3 a stale trail: silent' "$OUT" ''
rm -f "$REEVE_HOME/config/resume-window"

setup3 home3c
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>"$SCRATCH/err"); RC=$?
C=$(ctx_of "$OUT")
ck_eq '3 resume: exit 0' "$RC" 0
ck_eq '3 resume: nothing on stderr' "$(cat "$SCRATCH/err")" ''
ck_has '3 resume: SessionStart additionalContext' "$C" 'Reeve resume: this session carries on reeve Aldric'"'"'s session old-sid'
ck_eq '3 the trail is taken' "$(trails)" 0
ck_eq '3 successor recorded' "$(cat "$REEVE_HOME/state/sessions/old-sid/successor" 2>/dev/null)" new-sid
ck_eq '3 the name claimed' "$(cat "$REEVE_HOME/state/sessions/new-sid/name" 2>/dev/null)" Aldric
ck_has '3 the name said' "$C" 'Name: Aldric, claimed'
ck_eq '3 its own errand adopted, though the old heartbeat is fresh' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" new-sid
ck_eq "3 another reeve's orphan left alone" "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e2.meta")" gone-sid
ck_has '3 adoption said' "$C" "errand 'e1' adopted"
ck_has '3 the rest left for the liege' "$C" 'left for the liege: e2'
ck_has '3 no watch: start one' "$C" 'Watch, now: none running, whatever the conversation below says. If anything is in flight, start bin/reeve-sentry'
ck_has '3 handoff pointed at' "$C" 'reeve-2026-10-07-1200.md was written'
ck_has '3 the digest' "$C" '[liege] liege prompt 34: please do thing 34'
ck_has '3 the contract pointer' "$C" 'reeve-contract'
ck_eq '3 the chain for the next trail' "$(cat "$REEVE_HOME/state/sessions/new-sid/resumed-from")" "$SCRATCH/t1.jsonl"
ck_has '3 logged' "$(cat "$REEVE_HOME/state/session-hooks.log")" 'session-start new-sid resumed from old-sid (clear), 30 liege message(s)'
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)
ck_eq '3 taken once: a second start is silent' "$OUT" ''

# The watch from before is still running: its marker, under the old id.
setup3 home3d
printf '%s %s 15\n' "$$" "$(date +%s)" > "$REEVE_HOME/state/.sentry.watch-old-sid"
C=$(ctx_of "$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)")
ck_has '3 a live watch: still running' "$C" 'Watch, now: still running'
ck_not '3 a live watch: no second one' "$C" 'start bin/reeve-sentry'
# Another reeve's handoff, newer, is not this one's.
setup3 home3d2
printf '# Handoff\n\n- **Reeve:** Bran\n' > "$REEVE_HOME/handoffs/lantern-2026-10-07-1300.md"
touch -t 202001010000 "$REEVE_HOME/handoffs/reeve-2026-10-07-1200.md"
python3 -c 'import os, sys, time; os.utime(sys.argv[1], (time.time() + 60,) * 2)' "$REEVE_HOME/handoffs/lantern-2026-10-07-1300.md"
C=$(ctx_of "$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)")
ck_not "3 another reeve's handoff: not pointed at" "$C" 'lantern-'
setup3 home3d3
printf '# Handoff\n\n- **Reeve:** Bran\n' > "$REEVE_HOME/handoffs/lantern-2026-10-07-1300.md"
python3 -c 'import os, sys, time; os.utime(sys.argv[1], (time.time() + 60,) * 2)' "$REEVE_HOME/handoffs/lantern-2026-10-07-1300.md"
C=$(ctx_of "$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)")
ck_has "3 this reeve's own, past a newer one of another's" "$C" 'reeve-2026-10-07-1200.md was written'
# A handoff older than the digest's span is not pointed at.
setup3 home3e
touch -t 202001010000 "$REEVE_HOME/handoffs/"*.md
C=$(ctx_of "$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)")
ck_not '3 an old handoff: not pointed at' "$C" 'Handoff:'

# The same session resumed (`claude --resume`): name and watch, no digest, no
# adoption, no successor.
setup3 home3f
C=$(ctx_of "$(hook SessionStart old-sid "$SCRATCH/t1.jsonl" resume | "$START" 2>&1)")
ck_has '3 same session: resumed' "$C" "this is reeve Aldric's session old-sid, resumed"
ck_has '3 same session: name' "$C" 'Name: Aldric, already'
ck_not '3 same session: no digest' "$C" '[liege]'
ck_not '3 same session: no adoption' "$C" 'Errands:'
ck_eq '3 same session: no successor' "$(ls "$REEVE_HOME/state/sessions/old-sid/successor" 2>/dev/null)" ''

# A live reeve on another pane holds the name: no takeover, the trail dropped
# before anything is claimed, and nothing adopted under a pool name.
setup3 home3g
reeve rival-sid Aldric w7:p7
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)
ck_eq '3 live holder: silent' "$OUT" ''
ck_eq '3 live holder: no pool name' "$(cat "$REEVE_HOME/state/sessions/new-sid/name" 2>/dev/null)" ''
ck_eq '3 live holder: nothing adopted' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" old-sid
ck_has '3 live holder: logged' "$(cat "$REEVE_HOME/state/session-hooks.log")" 'is live again as rival-sid'

# The claim refused after the pre-check passed: a rival appears in between.
# Said, no pool name, nothing adopted. Run through a copy of bin/ whose
# reeve-name creates the rival first.
setup3 home3g2
rm -rf "$SCRATCH/binrace"; cp -R "$ROOT/bin" "$SCRATCH/binrace"
cat > "$SCRATCH/binrace/reeve-name" <<STUB
#!/usr/bin/env bash
d="\$REEVE_HOME/state/sessions/rival-sid"
mkdir -p "\$d"; printf 'Aldric\n' > "\$d/name"; printf 'w7:p7\n' > "\$d/pane"; date +%s > "\$d/seen"
exec "$ROOT/bin/reeve-name" "\$@"
STUB
chmod +x "$SCRATCH/binrace/reeve-name"
C=$(ctx_of "$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$SCRATCH/binrace/reeve-session-start" 2>&1)")
ck_has '3 claim refused: said' "$C" 'Name: claiming Aldric REFUSED'
ck_eq '3 claim refused: no pool name' "$(cat "$REEVE_HOME/state/sessions/new-sid/name" 2>/dev/null)" ''
ck_eq '3 claim refused: nothing adopted' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" old-sid
ck_has '3 claim refused: logged' "$(cat "$REEVE_HOME/state/session-hooks.log")" 'refused'

# Inside herdr: the pane's trail, not the directory's.
fresh_home home3h
reeve old-sid Aldric w1:p2
hook SessionEnd old-sid "$SCRATCH/t2.jsonl" | HERDR_PANE_ID=w1:p2 "$END"
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | HERDR_PANE_ID=w1:p3 "$START" 2>&1)
ck_eq '3 another pane: silent' "$OUT" ''
C=$(ctx_of "$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | HERDR_PANE_ID=w1:p2 "$START" 2>&1)")
ck_has '3 the same pane: resumed' "$C" 'Reeve resume'
ck_eq '3 the same pane: pane recorded for the name' "$(cat "$REEVE_HOME/state/sessions/new-sid/pane" 2>/dev/null)" w1:p2

# Two copies on one start: one context, one claim.
setup3 home3i
in=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear)
printf '%s' "$in" | "$START" > "$SCRATCH/a" 2>&1 &
printf '%s' "$in" | "$START" > "$SCRATCH/b" 2>&1 &
wait
ck_eq '3 two copies: one context' "$(cat "$SCRATCH/a" "$SCRATCH/b" | grep -c 'additionalContext')" 1

# A stranger's start costs no python: fine without it, and silent.
fresh_home home3j
NOPY="$SCRATCH/nopy"; mkdir -p "$NOPY"
for t in /bin/* /usr/bin/*; do
  case ${t##*/} in python3*) continue ;; esac
  [ -e "$NOPY/${t##*/}" ] || ln -s "$t" "$NOPY/${t##*/}"
done
in=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear)
OUT=$(PATH=$NOPY /bin/bash "$START" <<<"$in" 2>&1); RC=$?
ck_eq '3 no trails, no python3: exit 0, silent' "$RC:$OUT" '0:'
in=$(hook SessionEnd new-sid "$SCRATCH/new.jsonl")
OUT=$(PATH=$NOPY /bin/bash "$END" <<<"$in" 2>&1); RC=$?
ck_eq '3 end, stranger, no python3: exit 0, silent' "$RC:$OUT" '0:'
# Trails exist, none of them here and none naming it: still no python.
setup3 home3k
in=$(hook SessionStart stranger-sid "$SCRATCH/new.jsonl" startup "$SCRATCH")
OUT=$(PATH=$NOPY /bin/bash "$START" <<<"$in" 2>&1); RC=$?
ck_eq '3 trails elsewhere, no python3: exit 0, silent' "$RC:$OUT" '0:'
ck_not '3 trails elsewhere: never reached for python' "$(cat "$REEVE_HOME/state/session-hooks.log" 2>/dev/null)" 'python3'
in=$(hook SessionStart stranger-sid "$SCRATCH/new.jsonl" resume "$SCRATCH")
OUT=$(PATH=$NOPY /bin/bash "$START" <<<"$in" 2>&1); RC=$?
ck_eq '3 a stranger resumed, trails elsewhere, no python3: exit 0, silent' "$RC:$OUT" '0:'
ck_not '3 ... never reached for python' "$(cat "$REEVE_HOME/state/session-hooks.log" 2>/dev/null)" 'python3'

# A transcript path is one argument, never globbed.
fresh_home home3l
reeve old-sid Aldric
python3 - "$SCRATCH/g[ab].jsonl" "$SCRATCH/ga.jsonl" <<'PY'
import json, sys
for path, word in zip(sys.argv[1:], ("LITERAL-PATH", "GLOBBED-PATH")):
    with open(path, "w") as f:
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content": word}}) + "\n")
PY
hook SessionEnd old-sid "$SCRATCH/g[ab].jsonl" clear | "$END"
C=$(ctx_of "$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)")
ck_has '3 a transcript path with [ ]: read as written' "$C" 'LITERAL-PATH'
ck_not '3 ... not globbed' "$C" 'GLOBBED-PATH'

echo '--- 3b. after anything but /clear: an offer ---'
# ended_ago <seconds>: the trail, and the old session's last heartbeat with it
ended_ago() {
  local t=$(( $(date +%s) - $1 ))
  sed -i.bak "s/^ended=.*/ended=$t/" "$REEVE_HOME/state/trails/"*; rm -f "$REEVE_HOME/state/trails/"*.bak
  printf '%s\n' "$t" > "$REEVE_HOME/state/sessions/old-sid/seen"
}
sys_of() { printf '%s' "$1" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("systemMessage", ""))' 2>/dev/null; }
setup3 home3m prompt_input_exit
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" startup | "$START" 2>"$SCRATCH/err"); RC=$?
C=$(ctx_of "$OUT")
ck_eq '3b exit: exit 0, nothing on stderr' "$RC:$(cat "$SCRATCH/err")" '0:'
ck_eq '3b exit: one line on screen' "$(sys_of "$OUT")" 'Aldric was here, say resume to pick up.'
ck_has '3b exit: the session told how to take it' "$C" 'reeve-session-start --resume'
ck_has '3b exit: ... and only if the liege says so' "$C" 'Only if the liege says resume'
ck_not '3b exit: no digest' "$C" '[liege]'
ck_eq '3b exit: the trail stays' "$(trails)" 1
ck_eq '3b exit: no successor' "$(ls "$REEVE_HOME/state/sessions/old-sid/successor" 2>/dev/null)" ''
ck_eq '3b exit: no name claimed' "$(cat "$REEVE_HOME/state/sessions/new-sid/name" 2>/dev/null)" ''
ck_eq '3b exit: nothing adopted' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" old-sid
# --resume, once the liege says so: everything the /clear path does, printed.
OUT=$(cd "$SCRATCH/work" && REEVE_SESSION=new-sid "$START" --resume 2>&1); RC=$?
ck_eq '3b --resume: exit 0' "$RC" 0
ck_has '3b --resume: carries on' "$OUT" "Reeve resume: this session carries on reeve Aldric's session old-sid"
ck_has '3b --resume: says it did the steps' "$OUT" 'reeve-session-start --resume already did'
ck_has '3b --resume: the name' "$OUT" 'Name: Aldric, claimed'
ck_eq '3b --resume: the name recorded' "$(cat "$REEVE_HOME/state/sessions/new-sid/name" 2>/dev/null)" Aldric
ck_eq '3b --resume: its errand adopted' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" new-sid
ck_has '3b --resume: the digest' "$OUT" '[liege] liege prompt 34: please do thing 34'
ck_eq '3b --resume: successor recorded' "$(cat "$REEVE_HOME/state/sessions/old-sid/successor" 2>/dev/null)" new-sid
ck_eq '3b --resume: the trail is taken' "$(trails)" 0
OUT=$(cd "$SCRATCH/work" && REEVE_SESSION=new-sid "$START" --resume 2>&1); RC=$?
ck_eq '3b --resume twice: refused' "$RC" 1
ck_has '3b --resume twice: said' "$OUT" 'nothing to resume'
OUT=$(REEVE_SESSION=new-sid "$START" --resume "$SCRATCH" 2>&1); RC=$?
ck_eq '3b --resume elsewhere: refused' "$RC" 1
# The directory as the offer names it.
setup3 home3n prompt_input_exit
OUT=$(REEVE_SESSION=new-sid "$START" --resume "$SCRATCH/work" 2>&1); RC=$?
ck_eq '3b --resume <dir>: taken' "$RC" 0
# A /clear trail that a startup finds, not a clear: an offer.
setup3 home3o
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" startup | "$START" 2>&1)
ck_eq '3b a /clear trail, a startup: an offer' "$(sys_of "$OUT")" 'Aldric was here, say resume to pick up.'
ck_eq '3b ... nothing claimed' "$(cat "$REEVE_HOME/state/sessions/new-sid/name" 2>/dev/null)" ''
# A /clear trail past resume-clear-window: an offer; the window is config.
setup3 home3p
ended_ago 700
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)
ck_eq '3b a /clear trail past ten minutes: an offer' "$(sys_of "$OUT")" 'Aldric was here, say resume to pick up.'
printf '1000\n' > "$REEVE_HOME/config/resume-clear-window"
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | "$START" 2>&1)
ck_has '3b config/resume-clear-window widens it' "$(ctx_of "$OUT")" 'Reeve resume: this session carries on'
# An offer past resume-window: nothing, and --resume refuses.
setup3 home3q prompt_input_exit
ended_ago 259300
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" startup | "$START" 2>&1)
ck_eq '3b an offer past three days: silent' "$OUT" ''
OUT=$(REEVE_SESSION=new-sid "$START" --resume "$SCRATCH/work" 2>&1); RC=$?
ck_eq '3b ... --resume refused' "$RC" 1
printf '400000\n' > "$REEVE_HOME/config/resume-window"
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" startup | "$START" 2>&1)
ck_eq '3b config/resume-window widens it' "$(sys_of "$OUT")" 'Aldric was here, say resume to pick up.'

echo '--- 3c. a session seen again is never taken over ---'
# The probed case: reeve A exits in pane p1, the liege resumes A in pane p2,
# and a new session later opens in p1.
setup3c() {
  fresh_home "$1"
  reeve old-sid Aldric w1:p1
  mkdir -p "$REEVE_HOME/errands/e1"
  printf 'office=scout\nbackend=stub\ndispatched=2026-10-07T10:00:00\nsession=old-sid\nreeve=Aldric\n' > "$REEVE_HOME/state/e1.meta"
  printf 'working: started\n' > "$REEVE_HOME/errands/e1/status"
  hook SessionEnd old-sid "$SCRATCH/t1.jsonl" "${2:-prompt_input_exit}" | HERDR_PANE_ID=w1:p1 "$END"
}
setup3c home3r
printf '1\n' > "$REEVE_HOME/state/sessions/old-sid/seen"
OUT=$(hook SessionStart old-sid "$SCRATCH/t1.jsonl" resume | HERDR_PANE_ID=w1:p2 "$START" 2>&1)
ck_eq '3c resumed elsewhere: silent' "$OUT" ''
ck_eq '3c resumed elsewhere: its trail in p1 removed' "$(trails)" 0
ck_eq '3c resumed elsewhere: its pane now p2' "$(cat "$REEVE_HOME/state/sessions/old-sid/pane")" w1:p2
ck_eq '3c resumed elsewhere: its heartbeat stamped' "$(REEVE_SESSION=x bash -c '. "$1/bin/reeve-lib.sh"; session_state old-sid' _ "$ROOT")" alive
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" startup | HERDR_PANE_ID=w1:p1 "$START" 2>&1)
ck_eq '3c a new session in p1: nothing offered' "$OUT" ''
OUT=$(REEVE_SESSION=new-sid HERDR_PANE_ID=w1:p1 "$START" --resume "$SCRATCH/work" 2>&1); RC=$?
ck_eq '3c ... --resume refused' "$RC" 1
OUT=$(REEVE_SESSION=new-sid HERDR_PANE_ID=w1:p1 "$ROOT/bin/reeve-name" claim Aldric 2>&1); RC=$?
ck_eq '3c ... the live reeve keeps its name' "$RC" 1
OUT=$(REEVE_SESSION=new-sid HERDR_PANE_ID=w1:p1 "$ROOT/bin/reeve-adopt" --mine 2>&1)
ck_eq '3c ... and its errand' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" old-sid
# The same, with no hook where it resumed (another harness, outside herdr):
# its heartbeat, newer than the trail's end, voids the trail.
setup3c home3s
sed -i.bak "s/^ended=.*/ended=$(( $(date +%s) - 120 ))/" "$REEVE_HOME/state/trails/"*; rm -f "$REEVE_HOME/state/trails/"*.bak
date +%s > "$REEVE_HOME/state/sessions/old-sid/seen"
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" startup | HERDR_PANE_ID=w1:p1 "$START" 2>&1)
ck_eq '3c seen after it ended: nothing offered' "$OUT" ''
ck_eq '3c seen after it ended: the trail removed' "$(trails)" 0
ck_has '3c seen after it ended: logged' "$(cat "$REEVE_HOME/state/session-hooks.log")" 'seen after it ended'
setup3c home3t clear
sed -i.bak "s/^ended=.*/ended=$(( $(date +%s) - 120 ))/" "$REEVE_HOME/state/trails/"*; rm -f "$REEVE_HOME/state/trails/"*.bak
date +%s > "$REEVE_HOME/state/sessions/old-sid/seen"
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | HERDR_PANE_ID=w1:p1 "$START" 2>&1)
ck_eq '3c a /clear trail, seen after: no takeover' "$OUT" ''
ck_eq '3c ... no successor' "$(ls "$REEVE_HOME/state/sessions/old-sid/successor" 2>/dev/null)" ''
ck_eq '3c ... its errand kept' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" old-sid
# Inside the slack (a watch's last poll before /clear): still taken.
setup3c home3u clear
sed -i.bak "s/^ended=.*/ended=$(( $(date +%s) - 20 ))/" "$REEVE_HOME/state/trails/"*; rm -f "$REEVE_HOME/state/trails/"*.bak
date +%s > "$REEVE_HOME/state/sessions/old-sid/seen"
C=$(ctx_of "$(hook SessionStart new-sid "$SCRATCH/new.jsonl" clear | HERDR_PANE_ID=w1:p1 "$START" 2>&1)")
ck_has '3c seen inside resume-slack: taken' "$C" 'Reeve resume: this session carries on'

echo '--- 3d. the name is live again elsewhere: no offer ---'
# A exits in p1 (trail left), the liege starts a fresh reeve R in p2 that
# claims Aldric, and a plain session N then opens in p1.
setup3c home3v
reeve rival-sid Aldric w1:p2
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" startup | HERDR_PANE_ID=w1:p1 "$START" 2>"$SCRATCH/err"); RC=$?
ck_eq '3d live holder: exit 0, nothing offered' "$RC:$OUT:$(cat "$SCRATCH/err")" '0::'
ck_eq '3d live holder: the trail dropped' "$(trails)" 0
ck_has '3d live holder: logged' "$(cat "$REEVE_HOME/state/session-hooks.log")" 'is live again as rival-sid'
setup3c home3w
reeve rival-sid Aldric w1:p2
OUT=$(REEVE_SESSION=new-sid HERDR_PANE_ID=w1:p1 "$START" --resume "$SCRATCH/work" 2>&1); RC=$?
ck_eq '3d --resume, live holder: refused' "$RC" 1
ck_has '3d --resume, live holder: said' "$OUT" 'is live again as session rival-sid'
ck_eq '3d --resume, live holder: no successor record' "$(ls "$REEVE_HOME/state/sessions/old-sid/successor" 2>/dev/null)" ''
ck_eq '3d --resume, live holder: the trail not consumed' "$(trails)" 1
ck_eq '3d --resume, live holder: errand kept' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" old-sid
# The same trail, the rival gone: the offer stands.
rm -rf "$REEVE_HOME/state/sessions/rival-sid"
OUT=$(hook SessionStart new-sid "$SCRATCH/new.jsonl" startup | HERDR_PANE_ID=w1:p1 "$START" 2>&1)
ck_eq '3d no live holder: offered' "$(sys_of "$OUT")" 'Aldric was here, say resume to pick up.'

# Outside herdr, the reeve's own earlier session is no rival: A (fresh
# heartbeat) is cleared into S1, S1 is cleared again into S2 within the stale
# window. S2 takes over.
setup3 home3x
hook SessionStart s1-sid "$SCRATCH/s1.jsonl" clear | "$START" >/dev/null 2>&1
hook SessionEnd s1-sid "$SCRATCH/s1.jsonl" clear | "$END"
C=$(ctx_of "$(hook SessionStart s2-sid "$SCRATCH/s2.jsonl" clear | "$START" 2>&1)")
ck_has '3d chained /clear: taken over' "$C" 'Reeve resume: this session carries on'
ck_eq '3d chained /clear: the name' "$(cat "$REEVE_HOME/state/sessions/s2-sid/name" 2>/dev/null)" Aldric
ck_eq '3d chained /clear: errand adopted' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" s2-sid
# Clear, then exit, then a plain start and --resume.
setup3 home3y
hook SessionStart s1-sid "$SCRATCH/s1.jsonl" clear | "$START" >/dev/null 2>&1
hook SessionEnd s1-sid "$SCRATCH/s1.jsonl" other | "$END"
OUT=$(hook SessionStart s2-sid "$SCRATCH/s2.jsonl" startup | "$START" 2>&1)
ck_eq '3d clear then exit: offered' "$(sys_of "$OUT")" 'Aldric was here, say resume to pick up.'
OUT=$(REEVE_SESSION=s2-sid "$START" --resume "$SCRATCH/work" 2>&1); RC=$?
ck_eq '3d clear then exit: --resume ok' "$RC" 0
ck_eq '3d clear then exit: errand adopted' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" s2-sid
# A genuine live rival still blocks, outside herdr too.
setup3 home3z
hook SessionStart s1-sid "$SCRATCH/s1.jsonl" clear | "$START" >/dev/null 2>&1
hook SessionEnd s1-sid "$SCRATCH/s1.jsonl" clear | "$END"
reeve rival-sid Aldric
OUT=$(REEVE_SESSION=s2-sid "$START" --resume "$SCRATCH/work" 2>&1); RC=$?
ck_eq '3d rival outside herdr: --resume refused' "$RC" 1
ck_has '3d rival outside herdr: says elsewhere' "$OUT" 'is live again as session rival-sid elsewhere'
OUT=$(hook SessionStart s2-sid "$SCRATCH/s2.jsonl" clear | "$START" 2>&1)
ck_eq '3d rival outside herdr: silent' "$OUT" ''
ck_eq '3d rival outside herdr: errand kept' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e1.meta")" s1-sid

echo '--- 4. the successor record ---'
fresh_home home4
reeve old-sid Aldric
reeve new-sid Aldric
mkdir -p "$REEVE_HOME/errands/e1"
printf 'office=scout\nbackend=stub\ndispatched=2026-10-07T10:00:00\nsession=old-sid\nreeve=Aldric\n' > "$REEVE_HOME/state/e1.meta"
printf 'working: started\n' > "$REEVE_HOME/errands/e1/status"
OUT=$(REEVE_SESSION=new-sid "$ROOT/bin/reeve-adopt" e1 2>&1); RC=$?
ck_eq '4 adopt from a live owner with no successor: refused' "$RC" 1
printf 'new-sid\n' > "$REEVE_HOME/state/sessions/old-sid/successor"
# Written a moment after any watch below starts, as /clear does to a running one.
future() { python3 -c 'import os, sys, time; os.utime(sys.argv[1], (time.time() + 30,) * 2)' "$1"; }
future "$REEVE_HOME/state/sessions/old-sid/successor"
OUT=$(REEVE_SESSION=new-sid "$ROOT/bin/reeve-adopt" e1 2>&1); RC=$?
ck_eq '4 adopt from the session it succeeded: taken' "$RC" 0
OUT=$(REEVE_SESSION=new-sid "$ROOT/bin/reeve-name" claim Aldric 2>&1); RC=$?
ck_eq '4 claim against the session it succeeded: no rival' "$RC" 0
# A watch started as the old session follows the record: it sees the errand
# the new session now owns, rather than nothing in flight.
OUT=$(REEVE_SESSION=old-sid "$ROOT/bin/reeve-sentry" --once --poll 1 2>&1); RC=$?
ck_eq '4 the old watch follows: still watching' "$RC" 4
ck_has '4 the old watch follows: one errand working' "$OUT" 'quiet: 1 errand(s) working'
printf 'done: finished\n' >> "$REEVE_HOME/errands/e1/status"
OUT=$(REEVE_SESSION=old-sid "$ROOT/bin/reeve-sentry" --once --poll 1 --no-reap 2>&1); RC=$?
ck_eq '4 the old watch reports for the new session' "$RC" 0
ck_has '4 ... the finished errand' "$OUT" 'e1'
rm -f "$REEVE_HOME/state/sessions/old-sid/successor"
OUT=$(REEVE_SESSION=old-sid "$ROOT/bin/reeve-sentry" --once --poll 1 2>&1); RC=$?
ck_eq '4 without the record: nothing of its own in flight' "$RC" 3
# The old session resumed after /clear, and starts a watch: the record is from
# before that watch, so it watches as itself, never as its successor.
sed -i.bak '/^done:/d' "$REEVE_HOME/errands/e1/status"; rm -f "$REEVE_HOME/errands/e1/status.bak"
printf 'new-sid\n' > "$REEVE_HOME/state/sessions/old-sid/successor"
touch -t 202001010000 "$REEVE_HOME/state/sessions/old-sid/successor"
OUT=$(REEVE_SESSION=old-sid "$ROOT/bin/reeve-sentry" --once --poll 1 2>&1); RC=$?
ck_eq '4 a watch started after the record: watches as itself' "$RC" 3
ck_eq '4 ... publishes its own marker' "$(ls "$REEVE_HOME/state/" | grep -c '^\.sentry\.watch-new-sid')" 0
# The record older than the old session's heartbeat is void: it came back.
lib() { REEVE_SESSION=$1 bash -c '. "$1/bin/reeve-lib.sh"; shift; "$@"' _ "$ROOT" "${@:2}"; }
date +%s > "$REEVE_HOME/state/sessions/old-sid/seen"
date +%s > "$REEVE_HOME/state/sessions/new-sid/seen"
ck_eq '4 a void record: followed nowhere' "$(lib x session_follow old-sid)" old-sid
lib new-sid session_replaced old-sid; ck_eq '4 a void record: not replaced' "$?" 1
printf 'office=scout\nbackend=stub\ndispatched=2026-10-07T10:00:00\nsession=old-sid\nreeve=Aldric\n' > "$REEVE_HOME/state/e3.meta"
mkdir -p "$REEVE_HOME/errands/e3"; printf 'working: started\n' > "$REEVE_HOME/errands/e3/status"
OUT=$(REEVE_SESSION=new-sid "$ROOT/bin/reeve-adopt" e3 2>&1); RC=$?
ck_eq '4 a void record: adopt from the live owner refused' "$RC" 1
OUT=$(REEVE_SESSION=new-sid "$ROOT/bin/reeve-adopt" --mine 2>&1)
ck_eq '4 a void record: --mine leaves it' "$(sed -n 's/^session=//p' "$REEVE_HOME/state/e3.meta")" old-sid
rm -f "$REEVE_HOME/state/sessions/new-sid/name"
OUT=$(REEVE_SESSION=new-sid "$ROOT/bin/reeve-name" claim Aldric 2>&1); RC=$?
ck_eq '4 a void record: the live reeve keeps its name' "$RC" 1
OUT=$(lib x name_live_elsewhere Aldric '' new-sid); ck_eq '4 a void record: name live elsewhere' "$OUT" old-sid
# Inside resume-slack it stands.
touch "$REEVE_HOME/state/sessions/old-sid/successor"
ck_eq '4 seen inside resume-slack: still followed' "$(lib x session_follow old-sid)" new-sid
rm -f "$REEVE_HOME/state/sessions/old-sid/successor" "$REEVE_HOME/state/e3.meta"
# A loop in the records is bounded.
printf 'b\n' > "$REEVE_HOME/state/sessions/old-sid/successor"
mkdir -p "$REEVE_HOME/state/sessions/b"; printf 'old-sid\n' > "$REEVE_HOME/state/sessions/b/successor"
OUT=$(REEVE_SESSION=old-sid bash -c '. "$1/bin/reeve-lib.sh"; session_follow old-sid' _ "$ROOT" 2>&1); RC=$?
ck_eq '4 a loop ends' "$RC" 0

echo '--- 5. registrations ---'
for f in hooks/hooks.json .claude/settings.json; do
  r=$(python3 -c '
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
for ev in ("SessionStart", "SessionEnd"):
    for e in h[ev]:
        for x in e["hooks"]:
            print(ev, e.get("matcher", "-"), x["timeout"], x["command"])' "$ROOT/$f" 2>&1)
  ck_has "5 $f: SessionEnd" "$r" 'SessionEnd - 5 '
  ck_has "5 $f: SessionEnd runs the end hook" "$r" '/bin/reeve-session-end'
  ck_has "5 $f: SessionStart on startup, clear and resume" "$r" 'SessionStart startup|clear|resume 30 '
  ck_has "5 $f: SessionStart runs the start hook" "$r" '/bin/reeve-session-start'
done
ck_has '5 the plugin runs from the plugin root' "$(cat "$ROOT/hooks/hooks.json")" '${CLAUDE_PLUGIN_ROOT}\"/bin/reeve-session-start'
ck_has '5 the clone runs from the project dir' "$(cat "$ROOT/.claude/settings.json")" '${CLAUDE_PROJECT_DIR}\"/bin/reeve-session-end'

# /clear waits for the end hook, so it must be quick well inside its timeout.
fresh_home home5
reeve old-sid Aldric
in=$(hook SessionEnd old-sid "$SCRATCH/t1.jsonl")
t0=$(date +%s); printf '%s' "$in" | "$END"; t1=$(date +%s)
if [ $((t1 - t0)) -le 2 ]; then ok "5 the end hook is quick ($((t1 - t0))s)"; else bad '5 the end hook is quick' "$((t1 - t0))s"; fi
in=$(hook SessionStart stranger-sid "$SCRATCH/new.jsonl" startup)
t0=$(date +%s); printf '%s' "$in" | HERDR_PANE_ID=w5:p5 "$START" >/dev/null; t1=$(date +%s)
if [ $((t1 - t0)) -le 2 ]; then ok "5 a start with no trail of its own is quick ($((t1 - t0))s)"; else bad '5 a start with no trail is quick' "$((t1 - t0))s"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
