#!/usr/bin/env bash
# What a restart does to names, groups and hands: a herdr server that comes
# back, a reeve that crashed and was relaunched, a reboot that orphans
# every errand at once.
#
# Pinned here, one block per gap the restart survey found:
#   2  a stored target is checked against what it was made for before anything
#      kills, relabels or types into it: ids are counters a restart hands out
#      again, so a kept id can name someone else's tab
#   3  a pane key is its id on its server, and herdr restores both, so the
#      same key after a restart is the same pane
#   4  a name is held only while its holder's pane still runs a harness, and a
#      refused claim says to retry rather than take a pool name
#   5  the session /clear replaced in this pane is adoptable at once
#   6  reeve-adopt --mine takes only this reeve's orphans and lists the rest
#   7  --orphans names the one dead reeve its errands carry, and how to resume it
#   8  a reeve that moved keeps the workspace its live hands are in
#   9  a hand lost with its reeve's closed workspace is named as such
#  11  a stale names lock from a crash is broken, and a missing name is said
#  12  doctor does not list the session /clear replaced as a live rival
#
# herdr is a stub on PATH writing its errors to stderr as real herdr does. Never
# the liege's server.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
SCRATCH=$(mktemp -d /tmp/rvrs.XXXXXX) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
case $SCRATCH in "$real_home"|"$real_home"/*) printf 'FAIL  refusing: scratch is inside the real home\n'; exit 1 ;; esac
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/home"
export REEVE_NO_CARETAKER=1
unset HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID \
      REEVE_BACKEND CLAUDE_CODE_SESSION_ID REEVE_SESSION REEVE_NAME REEVE_HAND

# --- stubs -------------------------------------------------------------------
FAKE="$SCRATCH/fakebin"; mkdir -p "$FAKE"
LOG="$SCRATCH/argv"; export STUB_LOG="$LOG"
# herdr: one session, `stub`, on $STUB_SOCK. STUB_PANES the panes that exist,
# each in working directory $STUB_CWD, or the next line of file $STUB_CWDS while
# it has one; STUB_FG the foreground process of every
# pane; STUB_WS the workspaces, labelled $STUB_LABEL. Errors on stderr.
cat > "$FAKE/herdr" <<'HERDR'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  'session list')
    printf '{"sessions":[{"default":true,"name":"stub","socket_path":"%s"}]}\n' "$STUB_SOCK" ;;
  'status server') exit 0 ;;
  'workspace get')
    for w in ${STUB_WS:-}; do
      [ "$w" = "$3" ] || continue
      printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"}}}\n' "$3" "${STUB_LABEL:-}"; exit 0
    done
    printf '{"error":{"code":"workspace_not_found"}}\n' >&2; exit 1 ;;
  'workspace create')
    printf '{"result":{"workspace":{"workspace_id":"wNEW"},"tab":{"tab_id":"wNEW:t1"},"root_pane":{"pane_id":"wNEW:p1"}}}\n' ;;
  'tab create')
    ws=''; prev=''
    for a in "$@"; do [ "$prev" = --workspace ] && ws=$a; prev=$a; done
    printf '{"result":{"tab":{"tab_id":"%s:t9"},"root_pane":{"pane_id":"%s:p9","tab_id":"%s:t9"}}}\n' "$ws" "$ws" "$ws" ;;
  'pane get')
    for p in ${STUB_PANES:-}; do
      [ "$p" = "$3" ] || continue
      c=${STUB_CWD:-}
      if [ -n "${STUB_CWDS:-}" ] && [ -s "$STUB_CWDS" ]; then
        c=$(head -n 1 "$STUB_CWDS"); sed 1d "$STUB_CWDS" > "$STUB_CWDS.n"; mv "$STUB_CWDS.n" "$STUB_CWDS"
      fi
      printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s"}}}\n' "$3" "$c"; exit 0
    done
    printf '{"error":{"code":"pane_not_found"}}\n' >&2; exit 1 ;;
  'pane process-info')
    printf '{"result":{"process_info":{"foreground_processes":[{"name":"%s"}]}}}\n' "${STUB_FG:-zsh}" ;;
  'agent get') printf '{"result":{"agent":{}}}\n' ;;
  'tab get') printf '{"result":{"tab":{"tab_id":"%s","label":"%s"}}}\n' "$3" "${STUB_TLABEL:-}" ;;
  'tab close'|'tab rename'|'workspace rename'|'workspace close'|'pane close'|'pane run'|'pane send-keys')
    printf '{"result":{"type":"ok"}}\n' ;;
  *) exit 1 ;;
esac
HERDR
chmod +x "$FAKE/herdr"
export PATH="$FAKE:$PATH"
export REEVE_HERDR_SESSION=stub
export STUB_SOCK="$SCRATCH/herdr.sock"
S="@$STUB_SOCK"

h() { : > "$LOG"; ( . "$ROOT/backends/herdr.sh"; "reeve_backend_herdr_$@" ); }
calls() { cat "$LOG"; }
lib() { bash -c '. "$0/bin/reeve-lib.sh"; "$@"' "$ROOT" "$@"; }

SESS="$REEVE_HOME/state/sessions"
NOW=$(date +%s)
fresh() { rm -rf "$REEVE_HOME"; mkdir -p "$SESS" "$REEVE_HOME/config" "$REEVE_HOME/errands"; }
# record <sid> <name> <alive|dead> [<pane>]
record() {
  mkdir -p "$SESS/$1"
  printf '%s\n' "$2" > "$SESS/$1/name"
  if [ "$3" = alive ]; then printf '%s\n' "$NOW" > "$SESS/$1/seen"
  else printf '%s\n' "$(( NOW - 100000 ))" > "$SESS/$1/seen"; fi
  [ -n "${4:-}" ] && printf '%s\n' "$4" > "$SESS/$1/pane"
  return 0
}
# errand <id> <owner sid> <reeve name> [<target>] [<backend>]
errand() {
  mkdir -p "$REEVE_HOME/errands/$1"
  printf 'working: on it\n' > "$REEVE_HOME/errands/$1/status"
  printf 'session=%s\nreeve=%s\noffice=scout\ntarget=%s\nbackend=%s\nrepo=\nworktree=\nbranch=\nbase=main\n' \
    "$2" "$3" "${4:-}" "${5:-herdr}" > "$REEVE_HOME/state/$1.meta"
}
sum() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
ident_of() { printf 'c%sl%s' "$(sum "$1")" "$(sum "$2")"; } # ident_of <dir> <label>

echo "--- 2. herdr: a target is checked against the pane it was made for ---"
# One reading each: a mismatch is read again before it counts, tested below.
export REEVE_IDENT_TRIES=1
export STUB_CWD=$SCRATCH
ID=$(ident_of "$SCRATCH" "Aldric's scout: a")
out=$(STUB_PANES='w7:p9' STUB_CWD=/a/plugin/dir h create_endpoint "$SCRATCH" "Aldric's scout: a" "w7$S")
eq  "2 a target carries the identity of the directory asked for, and its label" "$out" "w7|w7:p9|w7:t9#$ID"
T=$out
eq  "2 the same pane, restored with its directory, is itself" \
    "$(STUB_PANES='w7:p9' STUB_FG=claude h agent_state "$T")" alive
eq  "2 another pane under the reused id is missing"         \
    "$(STUB_PANES='w7:p9' STUB_CWD=/liege/notes STUB_FG=claude h agent_state "$T")" missing
STUB_PANES='w7:p9' STUB_CWD=/liege/notes h kill "$T" 2>"$SCRATCH/err"; rc=$?
eq  "2 and it is never closed"                              "$rc" 1
nas "2 no tab close went out"                               "$(calls)" "tab close"
has "2 which it says"                                       "$(cat "$SCRATCH/err")" "not the pane this target was made for"
STUB_PANES='w7:p9' STUB_CWD=/liege/notes h relabel "$T" "Bran's scout: a" 2>/dev/null
nas "2 nor relabelled"                                      "$(calls)" "tab rename"
STUB_PANES='w7:p9' STUB_CWD=/liege/notes h send_text_submit "$T" "carry on" 2>/dev/null
nas "2 nor typed into"                                      "$(calls)" "pane run"
STUB_PANES='w7:p9' STUB_CWD=/liege/notes h target_exists "$T"; rc=$?
eq  "2 nor said to exist"                                   "$rc" 1
STUB_PANES='w7:p9' h kill "$T"
has "2 its own pane is closed as before"                    "$(calls)" "tab close w7:t9"
STUB_PANES='w7:p9' STUB_CWD=/liege/notes h kill "w7|w7:p9|w7:t9"
has "2 a target from before identities is trusted as before" "$(calls)" "tab close w7:t9"
# A restored shell passes through other directories as it starts.
printf '%s\n' /a/plugin/dir > "$SCRATCH/cwds"
eq  "2 a passing directory is read again, not taken as another pane" \
    "$(STUB_CWDS="$SCRATCH/cwds" REEVE_IDENT_TRIES=3 STUB_PANES='w7:p9' STUB_FG=claude h agent_state "$T")" alive
STUB_PANES='w7:p9' STUB_CWD='' h kill "$T" 2>/dev/null
nas "2 a pane that shows neither directory nor label is never acted on" "$(calls)" "tab close"
# A restored shell's startup files were measured leaving it in another
# directory for good. Its label still says whose it is.
eq  "2 a restored tab in another directory is itself by its label" \
    "$(STUB_PANES='w7:p9' STUB_CWD=/a/plugin/dir STUB_TLABEL="Aldric's scout: a" STUB_FG=claude h agent_state "$T")" alive
eq  "2 a stranger's label on the reused id is not" \
    "$(STUB_PANES='w7:p9' STUB_CWD=/liege/notes STUB_TLABEL="notes" STUB_FG=claude h agent_state "$T")" missing
T2=$(STUB_PANES='w7:p9' h relabel "$T" "Bran's scout: a")
eq  "2 a relabel hands back the target with its new label" "$T2" "w7|w7:p9|w7:t9#$(ident_of "$SCRATCH" "Bran's scout: a")"
unset REEVE_IDENT_TRIES

echo "--- 3. a herdr pane key is its id on its server ---"
eq "3 the key is the pane id and its socket" \
   "$(HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=/s lib reeve_pane)" 'w1:p1@/s'
eq "3 bare when the socket is unknown"    "$(HERDR_PANE_ID=w1:p1 lib reeve_pane)" 'w1:p1'
eq "3 and nothing outside herdr"          "$(lib reeve_pane)" ''
eq "3 one key, one pane"                  "$(lib pane_eq "w1:p1$S" "w1:p1$S" && echo y || echo n)" y
eq "3 the same id on two servers is two"  "$(lib pane_eq 'w1:p1@/a' 'w1:p1@/b' && echo y || echo n)" n
# herdr restores its panes with their ids, so a relaunch in the restored pane
# is the reeve that ran there.
fresh
record old Aldric dead "w1:p1$S"
got=$(REEVE_SESSION=new HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=$STUB_SOCK "$ROOT/bin/reeve-name" 2>/dev/null)
eq "3 a restored pane keeps the dead reeve's name"                    "$got" Aldric

echo "--- 4. a name is held only while its holder's pane runs a harness ---"
fresh
record old Aldric alive "w3:p1$S"
got=$(REEVE_SESSION=new STUB_PANES='' "$ROOT/bin/reeve-name" claim Aldric 2>&1)
eq  "4 a fresh heartbeat on a closed pane holds nothing"     "$got" Aldric
fresh
record old Aldric alive "w3:p1$S"
got=$(REEVE_SESSION=new STUB_PANES='w3:p1' STUB_FG=zsh "$ROOT/bin/reeve-name" claim Aldric 2>&1)
eq  "4 nor on a pane fallen back to a shell"                 "$got" Aldric
fresh
record old Aldric alive "w3:p1$S"
got=$(REEVE_SESSION=new STUB_PANES='w3:p1' STUB_FG=claude "$ROOT/bin/reeve-name" claim Aldric 2>&1); rc=$?
eq  "4 a pane still running the harness holds it"            "$rc" 1
has "4 and the refusal says to retry"                        "$got" "retry reeve-name claim Aldric"
has "4 and to take a pool name only with the liege"          "$got" "only if the liege agrees"
fresh
record old Aldric alive "w3:p1@/elsewhere.sock"
got=$(REEVE_SESSION=new "$ROOT/bin/reeve-name" claim Aldric 2>&1); rc=$?
eq  "4 a pane that cannot be asked still holds it"           "$rc" 1

echo "--- 5. the session /clear replaced is adoptable at once ---"
fresh
record old Aldric alive "w3:p1$S"
errand e5 old Aldric
out=$(REEVE_SESSION=new HERDR_PANE_ID=w3:p1 HERDR_SOCKET_PATH=$STUB_SOCK "$ROOT/bin/reeve-adopt" e5 2>&1); rc=$?
eq  "5 an owner on this very pane is replaced, not alive"    "$rc" 0
eq  "5 and the errand is this session's"                     "$(grep '^session=' "$REEVE_HOME/state/e5.meta")" session=new
fresh
record old Aldric dead
errand e5b old Aldric "w7|w7:p9|w7:t9#$(ident_of "$SCRATCH" "Aldric's scout: e5b")" herdr
REEVE_SESSION=new STUB_CWD=$SCRATCH STUB_PANES='w7:p9' "$ROOT/bin/reeve-adopt" e5b >/dev/null 2>&1
eq  "5 an adopted hand's target keeps its new label as identity" \
    "$(grep '^target=' "$REEVE_HOME/state/e5b.meta")" "target=w7|w7:p9|w7:t9#$(ident_of "$SCRATCH" "Bran's scout: e5b")"
fresh
record old Aldric alive "w3:p1$S"
errand e5 old Aldric
out=$(REEVE_SESSION=new HERDR_PANE_ID=w4:p1 HERDR_SOCKET_PATH=$STUB_SOCK STUB_PANES='w3:p1' STUB_FG=claude \
      "$ROOT/bin/reeve-adopt" e5 2>&1); rc=$?
eq  "5 an owner alive on another pane is still refused"      "$rc" 1
out=$(REEVE_SESSION=new HERDR_PANE_ID=w3:p1 HERDR_SOCKET_PATH=$STUB_SOCK "$ROOT/bin/reeve-status" --orphans --no-wake 2>/dev/null)
has "5 --orphans lists the replaced owner's errand"          "$out" "e5"

echo "--- 6. reeve-adopt --mine takes this reeve's orphans only ---"
fresh
record me Aldric alive
record deadA Aldric dead
record deadB Bran dead
errand a1 deadA Aldric
errand a2 deadA Aldric
errand b1 deadB Bran
out=$(REEVE_SESSION=me "$ROOT/bin/reeve-adopt" --mine 2>&1)
eq  "6 both of Aldric's are adopted"   "$(grep -h '^session=' "$REEVE_HOME/state/a1.meta" "$REEVE_HOME/state/a2.meta" | sort -u)" session=me
eq  "6 Bran's is left where it was"    "$(grep '^session=' "$REEVE_HOME/state/b1.meta")" session=deadB
has "6 and named for the liege"        "$out" "left for the liege: b1, reeve Bran, owner deadB"
has "6 with a count"                   "$out" "adopted 2 orphan(s) of Aldric's, left 1 for the liege"

echo "--- 7. --orphans names the one dead reeve and how to bring it back ---"
fresh
record deadB Bran dead
errand b1 deadB Bran
errand b2 deadB Bran
printf 'claude\n' > "$SESS/deadB/harness"
out=$(REEVE_SESSION=new "$ROOT/bin/reeve-status" --orphans --no-wake 2>/dev/null)
has "7 the name every orphan carries"  "$out" "reeve-name claim Bran, then reeve-adopt --mine"
has "7 and the full recovery"          "$out" "claude --resume deadB"
# Errands briefed before and after a /clear have two owners: one valid line
# each, newest first, never one command naming both.
record deadB2 Bran dead
printf '%s\n' "$(( NOW - 50000 ))" > "$SESS/deadB2/seen"
errand b3 deadB2 Bran
out=$(REEVE_SESSION=new "$ROOT/bin/reeve-status" --orphans --no-wake 2>/dev/null)
eq  "7 one resume line per owner session" "$(printf '%s\n' "$out" | grep -c 'restore that reeve whole')" 2
eq  "7 newest first" "$(printf '%s\n' "$out" | grep 'restore that reeve whole' | head -1 | grep -c deadB2)" 1
nas "7 never two ids on one line"        "$out" "deadB2 deadB"
has "7 a session of no known harness gets no claude command" "$out" \
    "resume session deadB2 with its harness's own resume command"
nas "7 and not claude's form"            "$out" "claude --resume deadB2"
rm -rf "$SESS/deadB2" "$REEVE_HOME/state/b3.meta" "$REEVE_HOME/errands/b3"
record liveB Bran alive
out=$(REEVE_SESSION=new "$ROOT/bin/reeve-status" --orphans --no-wake 2>/dev/null)
nas "7 never a name a live reeve holds" "$out" "reeve-name claim Bran"
fresh
record deadA Aldric dead
record deadB Bran dead
errand a1 deadA Aldric
errand b1 deadB Bran
out=$(REEVE_SESSION=new "$ROOT/bin/reeve-status" --orphans --no-wake 2>/dev/null)
nas "7 nor a guess between two names"   "$out" "reeve-name claim"

echo "--- 8. a reeve that moved keeps the workspace its hands are in ---"
grp() { REEVE_SESSION=me HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' STUB_LABEL=Aldric \
        lib reeve_group "$ROOT/bin" herdr Aldric 2>/dev/null; }
fresh
record me Aldric alive
printf 'w7%s\n' "$S" > "$SESS/me/group.herdr"
errand h1 old Aldric "w7|w7:p9|w7:t9" herdr
eq "8 a live hand tab in the old workspace keeps it" "$(STUB_PANES='w7:p9' grp)" "w7$S"
eq "8 none left, and the current workspace is taken" "$(STUB_PANES='' grp)" "w61$S"
errand h1 old Bran "w7|w7:p9|w7:t9" herdr
eq "8 another reeve's hand there keeps nothing"       "$(STUB_PANES='w7:p9' grp)" "w61$S"
# The old record of this same name, its pane now a shell, no longer holds it.
fresh
record me Aldric alive "w61:p1$S"
record old Aldric alive "w7:p1$S"
printf 'w7%s\n' "$S" > "$SESS/old/group.herdr"
errand h1 old Aldric "w7|w7:p9|w7:t9" herdr
eq "8 its own crashed past holds nothing against it" \
   "$(STUB_PANES='w7:p9 w7:p1' STUB_FG=zsh HERDR_PANE_ID=w61:p1 grp)" "w7$S"

echo "--- 9. a hand lost with its reeve's workspace is named so ---"
eq "9 a tab whose workspace is gone"     "$(STUB_WS='' h group_gone "w7|w7:p9|w7:t9" && echo y || echo n)" y
eq "9 not while the workspace is there"  "$(STUB_WS='w7' h group_gone "w7|w7:p9|w7:t9" && echo y || echo n)" n
eq "9 never for a hand with its own"     "$(STUB_WS='' h group_gone "w7|w7:p9" && echo y || echo n)" n
# The sentry's line, through a stub backend that says so.
SR="$SCRATCH/root"; mkdir -p "$SR/backends"
cat > "$SR/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()        { return 0; }
reeve_backend_stub_describe()         { echo stub; }
reeve_backend_stub_agent_state()      { echo missing; }
reeve_backend_stub_attention_state()  { echo unknown; }
reeve_backend_stub_capture()          { :; }
reeve_backend_stub_wait_change()      { return 2; }
reeve_backend_stub_kill()             { :; }
reeve_backend_stub_send_text_submit() { :; }
reeve_backend_stub_launch()           { :; }
reeve_backend_stub_group_gone()       { [ -n "${STUB_GONE:-}" ]; }
STUB
fresh
errand lost '' Aldric "g|p|t" stub
out=$(REEVE_ROOT=$SR REEVE_SESSION='' STUB_GONE=1 "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1)
has "9 the watch names the cause"        "$out" "stale: lost left no result and its session is missing, closed with its reeve's workspace"
fresh
errand lost '' Aldric "g|p|t" stub
out=$(REEVE_ROOT=$SR REEVE_SESSION='' STUB_GONE='' "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1)
has "9 and only when it is so"           "$out" "stale: lost left no result and its session is missing, last reported"

echo "--- 11. a stale names lock is broken, a missing name is said ---"
fresh
sh -c 'exit 0' & dead=$!; wait "$dead"
mkdir -p "$REEVE_HOME/state/.lock-names"; printf '%s\n' "$dead" > "$REEVE_HOME/state/.lock-names/pid"
old=$(( NOW - 600 ))
touch -t "$(date -r "$old" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old" +%Y%m%d%H%M.%S)" "$REEVE_HOME/state/.lock-names"
got=$(REEVE_SESSION=s11 "$ROOT/bin/reeve-name" 2>"$SCRATCH/err")
eq  "11 a dead holder's old lock is broken and a name given" "$got" Aldric
has "11 which it says"                                       "$(cat "$SCRATCH/err")" "broke stale lock names"
fresh
mkdir -p "$REEVE_HOME/state/.lock-names"; printf '%s\n' "$$" > "$REEVE_HOME/state/.lock-names/pid"
out=$(REEVE_SESSION=s11 lib reeve_name 2>&1 >/dev/null)
has "11 a live holder is never broken, and the empty name is said" "$out" "no name: the names lock"
rm -rf "$REEVE_HOME/state/.lock-names"

echo "--- 12. doctor does not list the session /clear replaced ---"
fresh
record old Aldric alive "w3:p1$S"
record new Aldric alive "w3:p1$S"
record other Bran alive "w9:p1$S"
out=$(REEVE_SESSION=new HERDR_PANE_ID=w3:p1 HERDR_SOCKET_PATH=$STUB_SOCK "$ROOT/bin/reeve-doctor" 2>&1)
has "12 the other live reeve is listed"  "$out" "Bran (other)"
nas "12 the replaced one is not"         "$out" "Aldric (old)"

echo "--- 13. herdr: only a trailing identity is split off a target ---"
export REEVE_IDENT_TRIES=1
# A `#` inside an id, should a herdr ever hand one out, stays part of the id.
STUB_PANES='w#1:p9' h kill "w#1|w#1:p9|w#1:t9"
has "13 a target with no identity keeps every # in its ids" "$(calls)" "tab close w#1:t9"
TH="w#1|w#1:p9|w#1:t9#$(ident_of "$SCRATCH" "Ab#c's scout: x")"
STUB_PANES='w#1:p9' STUB_CWD=$SCRATCH h kill "$TH"
has "13 and one with an identity acts on its own tab"       "$(calls)" "tab close w#1:t9"
STUB_PANES='w#1:p9' STUB_CWD=/liege/notes h kill "$TH" 2>/dev/null
nas "13 still refusing a stranger under that id"            "$(calls)" "tab close"
eq  "13 the pane is read whole"  "$(STUB_PANES='w#1:p9' STUB_FG=claude h agent_state "$TH")" alive
T13=$(STUB_PANES='w#1:p9' h relabel "$TH" "Bran#2's scout: x")
eq  "13 a relabel to a label with a # keeps the ids whole" "$T13" \
    "w#1|w#1:p9|w#1:t9#$(ident_of "$SCRATCH" "Bran#2's scout: x")"
has "13 and renames that tab"                                "$(calls)" "tab rename w#1:t9"
T13=$(STUB_PANES='w#1:p9' h relabel "w#1|w#1:p9|w#1:t9" "Bran's scout: x")
eq  "13 a target with no identity is handed back as nothing new" "$T13" ""
unset REEVE_IDENT_TRIES

echo "--- 14. a resumed reeve's heartbeat moves its pane record ---"
# Reeve A crashed in w1:p1, the liege resumed it in w2:p1, and reeve B starts
# in the restored w1:p1. A only heartbeats, never asks its name.
fresh
record A Aldric alive "w1:p1$S"
printf 'w1%s\n' "$S" > "$SESS/A/group.herdr"
errand a14 A Aldric
REEVE_SESSION=A HERDR_PANE_ID=w2:p1 HERDR_SOCKET_PATH=$STUB_SOCK "$ROOT/bin/reeve-status" --no-wake >/dev/null 2>&1
eq  "14 the heartbeat rewrites the pane record" "$(cat "$SESS/A/pane")" "w2:p1$S"
B14() { REEVE_SESSION=B HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=$STUB_SOCK STUB_PANES='w1:p1 w2:p1' STUB_FG=claude "$@"; }
# Before any adopt below, which would move a14 off A and pass this unearned.
out=$(B14 "$ROOT/bin/reeve-status" --orphans --no-wake 2>/dev/null)
nas "14 B does not see A's errand as an orphan"        "$out" "a14"
got=$(B14 "$ROOT/bin/reeve-name" 2>/dev/null)
eq  "14 B in A's old pane gets a pool name"           "$got" Bran
out=$(B14 "$ROOT/bin/reeve-adopt" --mine 2>&1)
eq  "14 B's --mine leaves A's errand"                  "$(grep '^session=' "$REEVE_HOME/state/a14.meta")" session=A
out=$(B14 "$ROOT/bin/reeve-adopt" a14 2>&1); rc=$?
eq  "14 and B cannot adopt it"                         "$rc" 1
got=$(B14 env HERDR_WORKSPACE_ID=w1 STUB_WS=w1 STUB_LABEL=Aldric bash -c ". \"\$0/bin/reeve-lib.sh\"; reeve_group \"\$0/bin\" herdr Bran" "$ROOT" 2>"$SCRATCH/err")
eq  "14 nor takes A's workspace"                       "$got" "wNEW$S"
has "14 which it says"                                 "$(cat "$SCRATCH/err")" "belongs to another live reeve"

echo "--- 15. the refusal says when a crashed holder lets go ---"
fresh
record old Aldric alive "w3:p1$S"
got=$(REEVE_SESSION=new STUB_PANES='w3:p1' STUB_FG=claude "$ROOT/bin/reeve-name" claim Aldric 2>&1)
has "15 once its heartbeat is that old, not within it" "$got" "once its last heartbeat is 900s old"

echo "--- 16. file mtime reads clean on this platform ---"
touch "$SCRATCH/mt"
m=$(lib file_mtime "$SCRATCH/mt")
case $m in ''|*[!0-9]*) bad "16 file_mtime prints epoch seconds only" "got [$m]" ;; *) ok "16 file_mtime prints epoch seconds only" ;; esac
d=$(( $(date +%s) - m )); [ "$d" -ge 0 ] && [ "$d" -lt 60 ] && ok "16 and the right ones" || bad "16 and the right ones" "off by $d"

echo "--- 17. a hand's heartbeat writes no pane or harness record ---"
fresh
REEVE_HAND=x1 CLAUDE_CODE_SESSION_ID=handsid REEVE_SESSION=handsid HERDR_PANE_ID=w1:p3 \
  HERDR_SOCKET_PATH=$STUB_SOCK "$ROOT/bin/reeve-status" --no-wake >/dev/null 2>&1
[ -f "$SESS/handsid/seen" ] && ok "17 the hand still heartbeats" || bad "17 the hand still heartbeats" "no seen"
[ -e "$SESS/handsid/pane" ] && bad "17 but stores no pane" "$(cat "$SESS/handsid/pane")" || ok "17 but stores no pane"
[ -e "$SESS/handsid/harness" ] && bad "17 nor a harness" "$(cat "$SESS/handsid/harness")" || ok "17 nor a harness"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
