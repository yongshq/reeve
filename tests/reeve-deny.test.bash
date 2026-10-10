#!/usr/bin/env bash
# bin/reeve-deny, against a stub backend so no terminal is involved, then the
# herdr op it rests on, against a fake herdr. Covered:
#   1. a dialog that goes: the key is sent once, it says so, and says steer next
#   2. a dialog that persists, or a session that cannot be read after, is said
#      as such, and exits 2
#   3. a session not at a dialog, or one it cannot tell is not, gets no key
#   4. an unknown, cleaned up or sessionless errand, or a gone session, is
#      refused and gets no key
#   5. a backend that cannot deny, or a send that fails, records nothing
#   6. the denial is one line in the errand's record, never the status file
#   7. herdr: Escape to the target's own pane, and nothing to a pane that is not
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
ck_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
ck_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "output did not mention [$3]: $2" ;; esac; }
ck_not() { case $2 in *"$3"*) bad "$1" "output should not have said [$3]: $2" ;; *) ok "$1" ;; esac; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/reeve-deny-test.XXXXXX") || exit 1
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

unset CLAUDE_CODE_SESSION_ID
export REEVE_SESSION=''
export REEVE_ROOT="$SCRATCH/root"
export REEVE_HOME="$SCRATCH/home"
export REEVE_DENY_TRIES=2
mkdir -p "$REEVE_ROOT/backends" "$REEVE_HOME/state" "$REEVE_HOME/errands/hung"

# STUB_ATTN is what attention_state reads now. STUB_AFTER, when there, is what
# it reads once the key has been sent, one line per reading, the last one
# holding: so a test says what the dialog does. Each reading after the key is
# logged in STUB_ACTS.
export STUB_ATTN="$SCRATCH/attn" STUB_AFTER="$SCRATCH/after" STUB_SEQ="$SCRATCH/seq" \
       STUB_ACTS="$SCRATCH/acts" STUB_LIVE="$SCRATCH/live" STUB_SENDFAIL="$SCRATCH/sendfail"
cat > "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()        { return 0; }
reeve_backend_stub_describe()         { echo stub; }
reeve_backend_stub_agent_state()      { cat "$STUB_LIVE" 2>/dev/null || echo alive; }
reeve_backend_stub_attention_state()  {
  [ -f "$STUB_SEQ" ] || { cat "$STUB_ATTN"; return; }
  head -1 "$STUB_SEQ"; echo read >> "$STUB_ACTS"
  [ "$(wc -l < "$STUB_SEQ")" -gt 1 ] && sed -i.bak 1d "$STUB_SEQ" && rm -f "$STUB_SEQ.bak"
  return 0
}
reeve_backend_stub_send_text_submit() { printf 'send %s\n' "$*" >> "$STUB_ACTS"; }
reeve_backend_stub_dismiss_dialog()   {
  [ -f "$STUB_SENDFAIL" ] && return 1
  printf 'deny %s\n' "$*" >> "$STUB_ACTS"
  [ -f "$STUB_AFTER" ] && cp "$STUB_AFTER" "$STUB_SEQ"
  return 0
}
STUB
# The same backend, without the optional op.
sed -e '/dismiss_dialog/,/^}/d' -e 's/_stub_/_bare_/' "$REEVE_ROOT/backends/stub.sh" > "$REEVE_ROOT/backends/bare.sh"

META="$REEVE_HOME/state/hung.meta"
STATUS="$REEVE_HOME/errands/hung/status"
fresh() { # fresh <attention now> [<each attention after the key>...]
  printf 'target=s|s:p1\nbackend=stub\noffice=artificer\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=yes\ndispatched=2026-10-01T21:30:00\n' > "$META"
  printf 'working: rewriting the parser\n' > "$STATUS"
  printf '%s\n' "$1" > "$STUB_ATTN"
  shift
  if [ $# -gt 0 ]; then printf '%s\n' "$@" > "$STUB_AFTER"; else rm -f "$STUB_AFTER"; fi
  rm -f "$STUB_SEQ" "$STUB_LIVE" "$STUB_SENDFAIL"; : > "$STUB_ACTS"
}
deny() { OUT=$("$ROOT/bin/reeve-deny" "$@" 2>&1); RC=$?; }
sent()   { grep -v '^read$' "$STUB_ACTS"; }
reads()  { grep -c '^read$' "$STUB_ACTS"; }
denied() { grep '^denied=' "$META" 2>/dev/null; }

# --- 1. a dialog that goes --------------------------------------------------
fresh waiting settled
deny hung
ck_eq  "1 a dialog that goes is a success"                 "$RC" 0
ck_eq  "1 the key is sent once, to the hand's target"      "$(sent)" "deny s|s:p1"
ck_eq  "1 and the session read once after it"              "$(reads)" 1
ck_has "1 it says the dialog is gone"                      "$OUT" "it is gone, the hand is settled"
ck_has "1 and says to steer next"                          "$OUT" "steer it next: bin/reeve-steer hung <text>"
ck_eq  "1 one fact per line, two lines"                    "$(printf '%s\n' "$OUT" | grep -c .)" 2
ck_not "1 nothing is typed, only the key"                  "$(sent)" "send "
fresh waiting working
deny hung
ck_eq  "1 a hand back at work after it is a success too"   "$RC" 0
ck_has "1 and says so"                                     "$OUT" "the hand is working"

# --- 2. a dialog that stays --------------------------------------------------
fresh waiting waiting
deny hung
ck_eq  "2 a dialog still standing exits 2"                 "$RC" 2
ck_eq  "2 read as often as REEVE_DENY_TRIES, no more"      "$(reads)" 2
ck_eq  "2 the key was sent once, not once per reading"     "$(sent | grep -c .)" 1
ck_has "2 it says a dialog still stands"                   "$OUT" "a dialog still stands"
ck_has "2 and what to do"                                  "$OUT" "bring it to the liege"
ck_not "2 and never says to steer"                         "$OUT" "steer it next"
for a in unknown ''; do
  fresh waiting "$a"
  deny hung
  ck_eq  "2 after the key, attention '${a}' exits 2"        "$RC" 2
  ck_has "2 and says it cannot tell"                       "$OUT" "cannot tell whether it is gone"
  ck_not "2 and never says to steer"                       "$OUT" "steer it next"
done
# A screen read before it repaints: the dialog reads once more, then goes.
fresh waiting waiting settled
deny hung
ck_eq  "2 a dialog read again before it counts"            "$RC" 0
ck_eq  "2 twice"                                           "$(reads)" 2
ck_eq  "2 still one key"                                   "$(sent | grep -c .)" 1

# --- 3. no dialog, or no telling ------------------------------------------------
for a in settled working unknown ''; do
  fresh "$a"
  deny hung
  ck_eq  "3 attention '${a}' is refused"                    "$RC" 1
  ck_eq  "3 and gets no key"                               "$(sent)" ""
  ck_eq  "3 and nothing is recorded"                       "$(denied)" ""
  case $a in
    settled|working) ck_has "3 and says it is not at a dialog" "$OUT" "is $a, not at a dialog" ;;
    *)               ck_has "3 and says it cannot tell"       "$OUT" "cannot tell whether the hand at s|s:p1 is at a dialog" ;;
  esac
done

# --- 4. nothing to deny -------------------------------------------------------
fresh waiting settled
deny nosuch
ck_eq  "4 an unknown errand is refused"                    "$RC" 1
ck_has "4 by name"                                         "$OUT" "no errand 'nosuch'"
deny 'Bad_Id'
ck_eq  "4 a malformed id is refused"                       "$RC" 1
deny
ck_eq  "4 no id is refused"                                "$RC" 1
printf 'tornDown=2026-10-02T10:00:00\n' >> "$META"
deny hung
ck_eq  "4 a cleaned up errand is refused"                  "$RC" 1
ck_has "4 and says so"                                     "$OUT" "was cleaned up"
fresh waiting settled
sed -i.bak 's/^target=.*/target=/' "$META"; rm -f "$META.bak"
deny hung
ck_eq  "4 a freed session is refused"                      "$RC" 1
ck_has "4 and says there is no session"                    "$OUT" "has no session"
for s in dead missing unreadable; do
  fresh waiting settled
  printf '%s\n' "$s" > "$STUB_LIVE"
  deny hung
  ck_eq  "4 a $s session is refused"                       "$RC" 1
  ck_has "4 and the refusal names it"                      "$OUT" "the hand is $s"
done
ck_eq  "4 none of them got a key"                          "$(sent)" ""

# --- 5. a key that cannot be sent ------------------------------------------------
fresh waiting settled
touch "$STUB_SENDFAIL"
deny hung
ck_eq  "5 a failed send fails"                             "$RC" 1
ck_has "5 and says so"                                     "$OUT" "could not deny the dialog"
ck_eq  "5 and records nothing"                             "$(denied)" ""
fresh waiting settled
sed -i.bak 's/^backend=.*/backend=bare/' "$META"; rm -f "$META.bak"
deny hung
ck_eq  "5 a backend that cannot deny is refused"           "$RC" 1
ck_has "5 by the backend's own word"                       "$OUT" "does not implement 'dismiss_dialog'"
ck_eq  "5 and records nothing"                             "$(denied)" ""

# --- 6. on disk, in the record ------------------------------------------------------
fresh waiting settled
before=$(cat "$STATUS")
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
touch -t 200001010000 "$STATUS"; mbefore=$(mtime "$STATUS")
deny hung
ck_eq  "6 one line in the errand's record"                 "$(denied | grep -c .)" 1
ck_has "6 with its outcome"                                "$(denied)" " cleared"
ck_has "6 and its time"                                    "$(denied)" "denied=20"
fresh waiting waiting; deny hung
ck_has "6 a dialog that stayed is recorded as such"        "$(denied)" " still-standing"
fresh waiting waiting; printf 'denied=old\n' >> "$META"; deny hung
ck_eq  "6 a second denial replaces the line, not adds one" "$(denied | grep -c .)" 1
fresh waiting settled
before=$(cat "$STATUS"); touch -t 200001010000 "$STATUS"; mbefore=$(mtime "$STATUS")
deny hung
ck_eq  "6 the status file is unchanged"                    "$(cat "$STATUS")" "$before"
ck_eq  "6 not even its mtime"                              "$(mtime "$STATUS")" "$mbefore"
fresh waiting settled
chmod a-w "$REEVE_HOME/state"
deny hung
chmod u+w "$REEVE_HOME/state"
ck_eq  "6 a record that cannot be written still denies"    "$RC" 0
ck_has "6 and says it is not on disk"                      "$OUT" "this denial is not on disk"

# --- 7. herdr ---------------------------------------------------------------------
# A fake herdr: STUB_CWD is the directory every pane reports, STUB_KEYFAIL makes
# send-keys fail, and argv is logged.
if ! command -v jq >/dev/null 2>&1; then
  printf 'skip  the herdr op needs jq, which this backend requires anyway\n'
else
  FAKE="$SCRATCH/fakebin"; mkdir -p "$FAKE"
  export STUB_LOG="$SCRATCH/argv"
  cat > "$FAKE/herdr" <<'HERDR'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  'pane get')       printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s"}}}\n' "$3" "${STUB_CWD:-}" ;;
  'tab get')        printf '{"result":{"tab":{"tab_id":"%s","label":"someone else"}}}\n' "$3" ;;
  'pane send-keys') [ -n "${STUB_KEYFAIL:-}" ] && exit 1; printf '{"result":{"type":"ok"}}\n' ;;
  *) exit 1 ;;
esac
HERDR
  chmod +x "$FAKE/herdr"
  hd() { : > "$STUB_LOG"; ( PATH="$FAKE:$PATH" REEVE_HERDR_SESSION=stub REEVE_IDENT_TRIES=1; \
         . "$ROOT/backends/herdr.sh"; reeve_backend_herdr_dismiss_dialog "$@" ) 2>/dev/null; }
  copy="$SCRATCH/copy"; mkdir -p "$copy"; copy=$(cd -P "$copy" && pwd -P)
  sum=$(printf '%s' "$copy" | cksum | cut -d' ' -f1)
  hd 'w7|w7:p9|w7:t9'; rc=$?
  ck_eq  "7 herdr sends Escape"                            "$rc" 0
  ck_has "7 to the target's own pane, on its session"      "$(cat "$STUB_LOG")" "pane send-keys w7:p9 esc --session stub"
  ck_not "7 and nothing that could answer yes"             "$(cat "$STUB_LOG")" "enter"
  ck_not "7 nor any text"                                  "$(cat "$STUB_LOG")" "pane run"
  STUB_KEYFAIL=1 hd 'w7|w7:p9|w7:t9'; rc=$?
  ck_eq  "7 a key herdr did not take is a failure"         "$rc" 1
  STUB_CWD=$copy hd "w7|w7:p9|w7:t9#c${sum}l1"; rc=$?
  ck_eq  "7 a pane that is still its own gets the key"     "$rc" 0
  ck_has "7 so"                                            "$(cat "$STUB_LOG")" "pane send-keys w7:p9 esc"
  STUB_CWD=/elsewhere hd "w7|w7:p9|w7:t9#c${sum}l1"; rc=$?
  ck_eq  "7 a pane that is someone else's now is refused"  "$rc" 1
  ck_not "7 and gets no key"                               "$(cat "$STUB_LOG")" "send-keys"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
