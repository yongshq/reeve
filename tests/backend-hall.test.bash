#!/usr/bin/env bash
# The hall backend: a copy of the herdr one that speaks only to hall.
#
# What is pinned here is the part that differs from herdr.sh, and why it is
# safe. hall is reached by socket, never by --session, so a session name can
# never carry a call to another server. herdr is never run and HERDR_* is never
# read: a trap herdr sits first on PATH and records any call, and every HERDR_*
# variable is set to a bogus value that must not show up anywhere. Then the
# herdr backend's own guarantees, re-run against hall: a reeve's group, a hand
# as a tab, kill never closing the workspace, label_own touching only its own
# tab, relabel by id.
#
# hall is a stub named by REEVE_HALL_BIN that records its argv and the server
# variables it was run with, so nothing here touches a real server. Scratch
# homes only.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not on PATH, which the hall backend needs"; echo "passed=0 failed=0"; exit 0; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
case $SCRATCH in "$real_home"|"$real_home"/*) printf 'FAIL  refusing: scratch is inside the real home\n'; exit 1 ;; esac
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/home"
export REEVE_NO_CARETAKER=1
export CLAUDE_CONFIG="$SCRATCH/claude.json"
mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/config"
unset CLAUDE_CODE_SESSION_ID REEVE_SESSION REEVE_NAME REEVE_HAND REEVE_BACKEND REEVE_ROOT \
      HALL_ENV HALL_PANE_ID HALL_SOCKET_PATH HALL_TAB_ID HALL_WORKSPACE_ID HALL_BIN_PATH \
      HALL_SESSION HALL_CLIENT_SOCKET_PATH REEVE_HALL_BIN REEVE_HALL_SOCKET REEVE_HALL_SESSION \
      REEVE_HERDR_SESSION
# Bogus herdr values, all of them: none may reach a hall call or a decision.
export HERDR_ENV=1 HERDR_PANE_ID=hp:BOGUS HERDR_SOCKET_PATH=/bogus/herdr.sock HERDR_TAB_ID=ht:BOGUS \
       HERDR_WORKSPACE_ID=hwBOGUS HERDR_BIN_PATH="$SCRATCH/fakebin/herdr" HERDR_SESSION=bogus

# --- stubs -----------------------------------------------------------------
FAKE="$SCRATCH/fakebin"; mkdir -p "$FAKE"
LOG="$SCRATCH/argv"; export STUB_LOG="$LOG"
TRAP="$SCRATCH/herdr-called"; export TRAP
cat > "$FAKE/herdr" <<'HERDR'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TRAP"
exit 1
HERDR
chmod +x "$FAKE/herdr"
# hall: each call logs `<argv> |sock=<HALL_SOCKET_PATH>|ses=<HALL_SESSION>|cli=<...>`.
# Only the server on $STUB_SOCK answers; any other socket is refused the way a
# socket nothing listens on is. Its sessions: `other`, then the default one,
# named $STUB_SES, on $STUB_SOCK. STUB_WS, STUB_PANES, STUB_TABS, STUB_FG and
# STUB_LABEL as in tests/backend-nest.test.bash.
cat > "$FAKE/hall" <<'HALL'
#!/usr/bin/env bash
printf '%s |sock=%s|ses=%s|cli=%s\n' "$*" "${HALL_SOCKET_PATH-}" "${HALL_SESSION-}" "${HALL_CLIENT_SOCKET_PATH-}" >> "$STUB_LOG"
case $1 in --version) echo "hall 0.1.0"; exit 0 ;; esac
case "$1 $2" in
  'session list')
    printf '{"sessions":[{"name":"other","default":false,"running":true,"socket_path":"/other.sock","session_dir":"/d"},{"name":"%s","default":true,"running":true,"socket_path":"%s","session_dir":"/d"}]}\n' \
      "${STUB_SES:-main}" "$STUB_SOCK"; exit 0 ;;
esac
[ "${HALL_SOCKET_PATH-}" = "$STUB_SOCK" ] || { printf '{"error":{"code":"connect_failed"}}\n' >&2; exit 1; }
case "$1 $2" in
  'status server') [ -n "${STUB_DOWN:-}" ] && exit 1; printf '{"result":{}}\n' ;;
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
  'tab get')
    for t in ${STUB_TABS:-}; do [ "$t" = "$3" ] && { printf '{"result":{"tab":{"tab_id":"%s"}}}\n' "$3"; exit 0; }; done
    printf '{"error":{"code":"tab_not_found"}}\n' >&2; exit 1 ;;
  'pane get')
    for p in ${STUB_PANES:-}; do [ "$p" = "$3" ] && { printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"; exit 0; }; done
    [ -n "${STUB_PANE_ERR:-}" ] && { printf '{"error":{"code":"server_error"}}\n' >&2; exit 1; }
    printf '{"error":{"code":"pane_not_found"}}\n' >&2; exit 1 ;;
  'pane process-info')
    printf '{"result":{"process_info":{"foreground_processes":[{"name":"%s"}]}}}\n' "${STUB_FG:-zsh}" ;;
  'workspace rename'|'workspace close'|'tab rename'|'tab close'|'pane close'|'pane run'|'pane send-keys')
    printf '{"result":{"type":"ok"}}\n' ;;
  *) exit 1 ;;
esac
HALL
chmod +x "$FAKE/hall"
export PATH="$FAKE:$PATH"
export REEVE_HALL_BIN="$FAKE/hall"
export STUB_SOCK="$SCRATCH/hall.sock"
S="@$STUB_SOCK"

# h <fn> <args...>   one hall backend function, in a subshell, its argv log fresh
h() { : > "$LOG"; ( . "$ROOT/bin/reeve-lib.sh"; . "$ROOT/backends/hall.sh"; "reeve_backend_hall_$@" ); }
hp() { ( . "$ROOT/bin/reeve-lib.sh"; . "$ROOT/backends/hall.sh"; "$@" ); }   # a private helper
calls() { cat "$LOG"; }

echo "--- 1. the server is found by socket, never by --session ---"
eq  "1 with nothing set, the default session hall lists"   "$(hp _h_sock)" "$STUB_SOCK"
eq  "1 HALL_SOCKET_PATH, as hall sets it in its panes"      "$(HALL_SOCKET_PATH=/pane.sock hp _h_sock)" /pane.sock
eq  "1 REEVE_HALL_SOCKET over both"                         "$(REEVE_HALL_SOCKET=/over.sock HALL_SOCKET_PATH=/pane.sock hp _h_sock)" /over.sock
: > "$LOG"; HALL_SESSION=x HALL_CLIENT_SOCKET_PATH=/c.sock hp _h pane get w1:p1 >/dev/null
has "1 a call names the server by its socket"               "$(calls)" "pane get w1:p1 |sock=$STUB_SOCK|"
nas "1 never with --session"                                "$(calls)" "--session"
has "1 with hall's own session variables taken away"        "$(calls)" "|ses=|cli="
eq  "1 the session name, outside hall: the default listed"  "$(STUB_SES=dev hp _h_place)" dev
eq  "1 inside a hall pane, its own session"                 "$(HALL_SOCKET_PATH=/p.sock HALL_SESSION=dev hp _h_place)" dev
eq  "1 which hall leaves unset for its default one"         "$(HALL_SOCKET_PATH=/p.sock hp _h_place)" default
eq  "1 REEVE_HALL_SESSION over everything"                  "$(REEVE_HALL_SESSION=x HALL_SESSION=dev hp _h_place)" x
eq  "1 place prints it, for the record and the listing"     "$(STUB_SES=dev h place)" dev
: > "$LOG"; out=$(REEVE_HALL_BIN="$SCRATCH/none" hp _h_sock); rc=$?
eq  "1 no binary: no socket, and nothing run"               "$out:$(calls)" ":"

echo "--- 2. the binary is hall's own, never herdr's ---"
eq  "2 REEVE_HALL_BIN"                                      "$(hp _hb)" "$FAKE/hall"
eq  "2 HALL_BIN_PATH, which hall sets in its panes, first"  "$(HALL_BIN_PATH=/x/hall hp _hb)" /x/hall
printf '/cfg/hall\n' > "$REEVE_HOME/config/hall-bin"
eq  "2 then config/hall-bin"                                "$(REEVE_HALL_BIN='' hp _hb)" /cfg/hall
rm -f "$REEVE_HOME/config/hall-bin"
eq  "2 then hall on PATH"                                   "$(REEVE_HALL_BIN='' hp _hb)" "$FAKE/hall"
eq  "2 and never HERDR_BIN_PATH, even with no hall at all"  "$(REEVE_HALL_BIN='' PATH=/usr/bin:/bin hp _hb; echo "rc=$?")" "rc=1"

echo "--- 3. available and describe ---"
h available; rc=$?
eq  "3 a server answering on the socket is available"       "$rc" 0
has "3 asked on that socket"                                "$(calls)" "status server --json |sock=$STUB_SOCK|"
out=$(STUB_DOWN=1 h available 2>&1); rc=$?
eq  "3 one that does not answer is not"                     "$rc" 1
has "3 saying where it looked"                              "$out" "hall server not running at $STUB_SOCK"
out=$(REEVE_HALL_BIN='' PATH=/usr/bin:/bin h available 2>&1); rc=$?
eq  "3 no binary is not available"                          "$rc" 1
has "3 saying how to name one"                              "$out" "set REEVE_HALL_BIN or config/hall-bin"
has "3 describe names hall, its version and its session"    "$(STUB_SES=dev h describe)" "hall 0.1.0 (session dev)"

echo "--- 4. ensure_group, as herdr.sh's ---"
out=$(HALL_SOCKET_PATH=$STUB_SOCK HALL_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Aldric "w7$S")
eq  "4 the reeve's own workspace is preferred to a known one" "$out" "w61$S"
has "4 and renamed to the reeve's name"                     "$(calls)" "workspace rename w61 Aldric |sock=$STUB_SOCK"
nas "4 never HERDR_WORKSPACE_ID's"                          "$(calls)" "hwBOGUS"
out=$(STUB_LABEL=Aldric STUB_WS='w7' h ensure_group Aldric "w7$S")
eq  "4 outside hall, a known group still there is reused"   "$out" "w7$S"
nas "4 without creating another"                            "$(calls)" "workspace create"
out=$(STUB_WS='w7' h ensure_group Aldric "w7@/elsewhere.sock")
eq  "4 a known id from another server is not reused"        "$out" "wNEW$S"
out=$(REEVE_HAND=fix HALL_SOCKET_PATH=$STUB_SOCK HALL_WORKSPACE_ID=w61 STUB_WS='w61' h ensure_group Bran)
eq  "4 a hand never takes the workspace it sits in"         "$out" "wNEW$S"
out=$(STUB_LABEL=Bran HALL_SOCKET_PATH=$STUB_SOCK HALL_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Bran "w7$S" "w61$S" 2>"$SCRATCH/err")
eq  "4 an own workspace another reeve holds is passed over" "$out" "w7$S"
has "4 which it says"                                       "$(cat "$SCRATCH/err")" "hall: workspace w61 belongs to another live reeve"
out=$(STUB_LABEL=Aldric HALL_SOCKET_PATH=/elsewhere.sock REEVE_HALL_SOCKET=$STUB_SOCK HALL_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Aldric "w7$S")
eq  "4 an own workspace on another server is not this one"  "$out" "w7$S"
nas "4 and the same-numbered one here is not renamed"       "$(calls)" "workspace rename"

echo "--- 5. create_endpoint, kill, relabel ---"
PLAIN="$SCRATCH/plain"; mkdir -p "$PLAIN"
out=$(h create_endpoint "$PLAIN" "Scout of Aldric" "w7$S")
eq  "5 with a group, a three field target"                  "${out%%#*}" "w7|w7:p9|w7:t9"
has "5 carrying its identity"                               "$out" "w7|w7:p9|w7:t9#c"
has "5 opened as a tab in that workspace"                   "$(calls)" "tab create --workspace w7 --cwd $PLAIN --label Scout of Aldric --no-focus"
out=$(h create_endpoint "$PLAIN" "scout: x")
eq  "5 without a group, a workspace of its own"             "${out%%#*}" "wNEW|wNEW:p1"
h kill 'w7|w7:p9|w7:t9'
has "5 kill closes a nested hand's tab"                     "$(calls)" "tab close w7:t9"
nas "5 and never its reeve's workspace"                     "$(calls)" "workspace close"
h kill 'w5|w5:p1'
has "5 a two field target closes its own workspace"         "$(calls)" "workspace close w5"
h relabel 'w7|w7:p9|w7:t9' "Scout of Percy"
has "5 relabel renames the tab by id"                       "$(calls)" "tab rename w7:t9 Scout of Percy"
nas "5 never the workspace"                                 "$(calls)" "workspace rename"
STUB_PANES='w7:p9' STUB_FG=claude h launch 'w7|w7:p9|w7:t9' "env -u HERDR_WORKSPACE_ID -u HALL_WORKSPACE_ID REEVE_HAND='x' claude --go"; rc=$?
eq  "5 launch proves the harness behind both unsets"        "$rc" 0
has "5 run in the hand's pane, on the socket"               "$(calls)" "pane run w7:p9 env -u HERDR_WORKSPACE_ID"

echo "--- 6. label_own: its own tab only ---"
export STUB_TABS='w61:t1'
HALL_SOCKET_PATH=$STUB_SOCK HALL_TAB_ID=w61:t1 h label_own Aldric; rc=$?
eq  "6 its own tab, by HALL_TAB_ID"                         "$rc:$(grep '^tab rename' "$LOG" | cut -d'|' -f1)" "0:tab rename w61:t1 Aldric "
HALL_SOCKET_PATH=$STUB_SOCK h label_own Aldric 2>"$SCRATCH/err"; rc=$?
eq  "6 never HERDR_TAB_ID's"                                "$rc:$(grep -c '^tab rename' "$LOG")" "1:0"
has "6 saying it has none of its own"                       "$(cat "$SCRATCH/err")" "no HALL_TAB_ID"
REEVE_HALL_SOCKET=/elsewhere.sock HALL_SOCKET_PATH=$STUB_SOCK HALL_TAB_ID=w61:t1 h label_own Aldric 2>/dev/null; rc=$?
eq  "6 never a tab on another server"                       "$rc:$(grep -c '^tab rename' "$LOG")" "1:0"
REEVE_HAND=one HALL_SOCKET_PATH=$STUB_SOCK HALL_TAB_ID=w61:t1 h label_own Aldric 2>/dev/null; rc=$?
eq  "6 never from a hand"                                   "$rc:$(grep -c '^tab rename' "$LOG")" "1:0"
unset STUB_TABS

echo "--- 7. pane_gone and pane_vacant ask the socket they are given ---"
pg() { h "$@" && echo yes || echo no; }
eq  "7 gone: a pane its server says is not found"           "$(STUB_PANES='' pg pane_gone w1:p1 "$STUB_SOCK")" yes
has "7 asked on that socket directly"                       "$(calls)" "pane get w1:p1 |sock=$STUB_SOCK|"
nas "7 with no session lookup"                              "$(calls)" "session list"
eq  "7 an existing pane is not gone"                        "$(STUB_PANES='w1:p1' pg pane_gone w1:p1 "$STUB_SOCK")" no
eq  "7 a server error proves nothing"                       "$(STUB_PANES='' STUB_PANE_ERR=1 pg pane_gone w1:p1 "$STUB_SOCK")" no
eq  "7 nor a socket nothing answers on"                     "$(STUB_PANES='' pg pane_gone w1:p1 /elsewhere.sock)" no
eq  "7 nor no socket at all"                                "$(STUB_PANES='' pg pane_gone w1:p1 '')" no
eq  "7 vacant: a pane running only a shell"                 "$(STUB_PANES='w1:p1' STUB_FG=zsh pg pane_vacant w1:p1 "$STUB_SOCK")" yes
eq  "7 not vacant: a pane running a harness"                "$(STUB_PANES='w1:p1' STUB_FG=claude pg pane_vacant w1:p1 "$STUB_SOCK")" no

echo "--- 8. through reeve-backend ---"
eq  "8 REEVE_BACKEND=hall resolves hall"                    "$(REEVE_BACKEND=hall "$ROOT/bin/reeve-backend" resolve)" hall
eq  "8 and herdr stays the default"                         "$("$ROOT/bin/reeve-backend" resolve)" herdr
: > "$LOG"
STUB_PANES='w7:p9' "$ROOT/bin/reeve-backend" call target_exists 'w7|w7:p9|w7:t9' --backend hall; rc=$?
eq  "8 a call reaches hall"                                 "$rc" 0
has "8 on its socket"                                       "$(calls)" "pane get w7:p9 |sock=$STUB_SOCK|"
has "8 list shows hall available"                           "$("$ROOT/bin/reeve-backend" list 2>&1)" "hall     available   hall 0.1.0"
# list asks every backend, and herdr's own row runs herdr: the trap's, here.
# That is herdr.sh, not this one, so the trap starts over.
: > "$TRAP"

echo "--- 9. a reeve inside hall: its pane key, its place, its name gate ---"
SESS="$REEVE_HOME/state/sessions"
inhall() { # inhall <sid> <pane> [args...]   reeve-name inside hall
  local sid=$1 pane=$2; shift 2
  : > "$LOG"
  env HALL_ENV=1 HALL_SOCKET_PATH="$STUB_SOCK" HALL_PANE_ID="$pane" HALL_TAB_ID=w61:t2 \
    HALL_WORKSPACE_ID=w61 HALL_SESSION=dev REEVE_BACKEND=hall REEVE_SESSION="$sid" \
    STUB_WS=w61 STUB_TABS=w61:t2 "$ROOT/bin/reeve-name" "$@" 2>"$SCRATCH/err"
}
out=$(inhall r1 w61:p1)
eq  "9 the pane key is hall's pane on hall's socket"        "$(cat "$SESS/r1/pane")" "w61:p1@$STUB_SOCK"
eq  "9 its place: hall and the session it is in"            "$(cat "$SESS/r1/place")" "hall dev"
has "9 HALL_ENV opens the label gate: its workspace"        "$(calls)" "workspace rename w61 $out |sock=$STUB_SOCK"
has "9 and its own tab"                                     "$(calls)" "tab rename w61:t2 $out |sock=$STUB_SOCK"
eq  "9 its group is kept per backend"                       "$(cat "$SESS/r1/group.hall")" "w61$S"
REEVE_SESSION=r1 HERDR_ENV='' HALL_ENV='' HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=/h.sock \
  bash -c '. "$1/bin/reeve-lib.sh"; pane_store r1' _ "$ROOT"
eq  "9 moved to a herdr pane: the herdr key"                "$(cat "$SESS/r1/pane")" "w1:p1@/h.sock"
eq  "9 and no place, so it reads herdr as before"           "$([ -f "$SESS/r1/place" ] && echo kept || echo gone)" gone
eq  "9 session_backend reads herdr without one"             "$(bash -c '. "$1/bin/reeve-lib.sh"; session_backend r1' _ "$ROOT")" herdr
printf 'hall dev\n' > "$SESS/r1/place"
eq  "9 and hall with one"                                   "$(bash -c '. "$1/bin/reeve-lib.sh"; session_backend r1' _ "$ROOT")" hall

echo "--- 10. a dispatch on hall ---"
git init -q "$SCRATCH/web"
git -C "$SCRATCH/web" -c user.email=r@invalid -c user.name=r -c commit.gpgsign=false commit -q --allow-empty -m init
python3 - "$CLAUDE_CONFIG" "$SCRATCH/web" <<'PY'
import json,sys,os
json.dump({"projects":{os.path.realpath(sys.argv[2]):{"hasTrustDialogAccepted":True}}},open(sys.argv[1],"w"))
PY
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
cp "$ROOT/backends/hall.sh" "$STUB/backends/hall.sh"
cat > "$STUB/harnesses/stub.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {prompt}"
prompt_mode = "argv"
HARNESS
"$ROOT/bin/reeve-survey" --register web --manor product --path "$SCRATCH/web" >/dev/null
# The reeve runs in a hall pane, as hall starts one: its own variables and
# REEVE_BACKEND=hall beside the herdr ones it also carries.
lead() { env REEVE_SESSION=lead HALL_ENV=1 HALL_SOCKET_PATH="$STUB_SOCK" HALL_PANE_ID=w3:p1 \
           HALL_WORKSPACE_ID=w3 REEVE_BACKEND=hall STUB_SES=dev "$@"; }
lead "$ROOT/bin/reeve-name" claim Escanor >/dev/null 2>&1
lead "$ROOT/bin/reeve-brief" one web --office scout >/dev/null 2>&1
f="$REEVE_HOME/errands/one/brief.md"
sed -e 's/{INTENT}/x/' -e 's/{SPEC}/y/' "$f" > "$f.f" && mv "$f.f" "$f"
: > "$LOG"
OUT=$(lead REEVE_ROOT="$STUB" STUB_WS=wNEW STUB_FG=true "$ROOT/bin/reeve-dispatch" one --harness stub 2>&1); RC=$?
eq  "10 a dispatch on hall succeeds"                        "$RC" 0
M="$REEVE_HOME/state/one.meta"
eq  "10 the record says hall"                               "$(grep '^backend=' "$M")" "backend=hall"
eq  "10 and the session the hand is in"                     "$(grep '^place=' "$M")" "place=default"
has "10 its target is a tab in the reeve's group"           "$(grep '^target=' "$M")" "target=wNEW|wNEW:p9|wNEW:t9#c"
has "10 the hand loses hall's workspace variable too"       "$(calls)" "pane run wNEW:p9 env -u HERDR_WORKSPACE_ID -u HALL_WORKSPACE_ID REEVE_HAND='one' true"
nas "10 every call on the socket, none by session"          "$(calls)" "--session"

echo "--- 11. herdr was never run, HERDR_* never read ---"
eq  "11 the trap herdr was never called"                    "$(cat "$TRAP" 2>/dev/null)" ''
nas "11 no bogus herdr value reached any hall call"         "$(cat "$LOG")" "BOGUS"
eq  "11 hall.sh reads no HERDR_ variable"                   "$(grep -nE '\$\{?HERDR_' "$ROOT/backends/hall.sh")" ''
eq  "11 and never runs herdr or passes --session"           "$(grep -nE '(^|[^_a-z])herdr [a-z]|--session' "$ROOT/backends/hall.sh" | grep -v '^[0-9]*: *#')" ''

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
