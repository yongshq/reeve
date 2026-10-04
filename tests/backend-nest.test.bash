#!/usr/bin/env bash
# A reeve's hands open inside its own group: a tab in its herdr workspace, a
# window in its tmux session, the group labelled with the reeve's name.
#
# What is pinned here is what makes that safe. A nested hand's target names its
# reeve's workspace, so cleaning the hand up must close its tab and NEVER that
# workspace, which is usually the one the reeve itself runs in. Targets recorded
# before nesting, two fields, still parse and still clean up as they did. The
# reeve's own workspace or window is what gets its name, never the liege's tmux
# session. And a backend with no group to give leaves dispatch exactly as it was.
#
# One reeve per workspace. A workspace another live reeve holds is never
# relabelled, nested into or reused; a gone one's may be taken over. A hand,
# which sits in its reeve's workspace, never takes it as its own, and neither
# does a reeve whose workspace id comes from a different herdr server. A group
# follows its name through /clear and claim instead of a new one each session.
#
# herdr and tmux are stubs on PATH that record their argv, so nothing here
# touches a real server. Scratch homes only.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
case $SCRATCH in "$real_home"|"$real_home"/*) printf 'FAIL  refusing: scratch is inside the real home\n'; exit 1 ;; esac
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/home"
export REEVE_NO_CARETAKER=1
export CLAUDE_CONFIG="$SCRATCH/claude.json"
# Nothing from the caller's own terminal may leak in: a real HERDR_WORKSPACE_ID
# or TMUX_PANE is exactly what ensure_group would rename.
unset HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_TAB_ID TMUX TMUX_PANE \
      REEVE_TMUX_SESSION REEVE_BACKEND CLAUDE_CODE_SESSION_ID REEVE_SESSION REEVE_NAME REEVE_HAND

# --- stub binaries -----------------------------------------------------------
FAKE="$SCRATCH/fakebin"; mkdir -p "$FAKE"
LOG="$SCRATCH/argv"; export STUB_LOG="$LOG"
# herdr: STUB_WS lists the workspaces that exist, each labelled $STUB_LABEL.
# tab create answers with a tab and root pane in the workspace it was asked for,
# unless STUB_TAB_FAIL is set. Its one session, `stub`, listens on $STUB_SOCK.
# STUB_PANES lists the panes that exist; pane get on any other is not found, or
# a server error under STUB_PANE_ERR. process-info names $STUB_FG. Error
# envelopes go to stderr, as real herdr writes them (0.9.0).
cat > "$FAKE/herdr" <<'HERDR'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  'session list')
    printf '{"sessions":[{"default":true,"name":"stub","socket_path":"%s"}]}\n' "$STUB_SOCK" ;;
  'workspace get')
    for w in ${STUB_WS:-}; do
      [ "$w" = "$3" ] || continue
      printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"}}}\n' "$3" "${STUB_LABEL:-}"; exit 0
    done
    printf '{"error":{"code":"workspace_not_found"}}\n' >&2; exit 1 ;;
  'workspace create')
    printf '{"result":{"workspace":{"workspace_id":"wNEW"},"tab":{"tab_id":"wNEW:t1"},"root_pane":{"pane_id":"wNEW:p1"}}}\n' ;;
  'tab create')
    [ -n "${STUB_TAB_FAIL:-}" ] && { printf '{"error":{"code":"nope"}}\n' >&2; exit 1; }
    ws=''; prev=''
    for a in "$@"; do [ "$prev" = --workspace ] && ws=$a; prev=$a; done
    printf '{"result":{"tab":{"tab_id":"%s:t9"},"root_pane":{"pane_id":"%s:p9","tab_id":"%s:t9"}}}\n' "$ws" "$ws" "$ws" ;;
  'tab close')
    [ -n "${STUB_TAB_CLOSE_FAIL:-}" ] && exit 1
    printf '{"result":{"type":"ok"}}\n' ;;
  'pane get')
    for p in ${STUB_PANES:-}; do [ "$p" = "$3" ] && { printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"; exit 0; }; done
    [ -n "${STUB_PANE_ERR:-}" ] && { printf '{"error":{"code":"server_error"}}\n' >&2; exit 1; }
    printf '{"error":{"code":"pane_not_found"}}\n' >&2; exit 1 ;;
  'pane process-info')
    printf '{"result":{"process_info":{"foreground_processes":[{"name":"%s"}]}}}\n' "${STUB_FG:-zsh}" ;;
  'workspace rename'|'workspace close'|'tab rename'|'pane close'|'pane run'|'pane send-keys')
    printf '{"result":{"type":"ok"}}\n' ;;
  *) exit 1 ;;
esac
HERDR
# tmux: the reeve runs in pane %3, window @4, session `work`. STUB_SES lists the
# sessions that exist, STUB_TPANES the panes; STUB_TMUX_DOWN, no server.
cat > "$FAKE/tmux" <<'TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
[ "$1" = -S ] && shift 2
case $1 in
  display)
    case $* in *session_name*) echo work ;; *window_id*) echo @4 ;; esac ;;
  has-session)
    t=${3#=}; for s in ${STUB_SES:-}; do [ "$s" = "$t" ] && exit 0; done; exit 1 ;;
  list-panes)
    [ -n "${STUB_TMUX_DOWN:-}" ] && { echo "no server running" >&2; exit 1; }
    printf '%s\n' ${STUB_TPANES:-} ;;
  new-window) echo @9 ;;
  *) exit 0 ;;
esac
TMUX
chmod +x "$FAKE/herdr" "$FAKE/tmux"
export PATH="$FAKE:$PATH"
export REEVE_HERDR_SESSION=stub
export STUB_SOCK="$SCRATCH/herdr.sock"

# h <fn> <args...>   one herdr backend function, in a subshell, its argv log fresh
h() { : > "$LOG"; ( . "$ROOT/backends/herdr.sh"; "reeve_backend_herdr_$@" ); }
t() { : > "$LOG"; ( . "$ROOT/backends/tmux.sh";  "reeve_backend_tmux_$@" ); }
calls() { cat "$LOG"; }

PLAIN="$SCRATCH/plain"; mkdir -p "$PLAIN"   # not a git checkout

echo "--- 1. herdr ensure_group ---"
# Group ids carry their server's socket, so S is the stub server's suffix.
S="@$STUB_SOCK"
out=$(HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Aldric "w7$S")
eq  "1 the reeve's own workspace is preferred to a known one" "$out" "w61$S"
has "1 and renamed to the reeve's name"                       "$(calls)" "workspace rename w61 Aldric --session stub"
nas "1 and nothing is created"                                "$(calls)" "workspace create"

out=$(STUB_LABEL=Aldric STUB_WS='w7' h ensure_group Aldric "w7$S")
eq  "1 outside herdr, a known group still there is reused"   "$out" "w7$S"
nas "1 without creating another"                             "$(calls)" "workspace create"
nas "1 or renaming one already showing the name"             "$(calls)" "workspace rename"
out=$(REEVE_GROUP_NAMES='Bran Old' STUB_LABEL=Old STUB_WS='w7' h ensure_group Aldric "w7$S")
eq  "1 a known group under an older name of this reeve is reused" "$out" "w7$S"
has "1 and relabelled with the name, as set left it"         "$(calls)" "workspace rename w7 Aldric --session stub"
# Ids are counters: after a server restart on the same socket, a known id may
# be someone else's workspace. A label no record of this reeve held is theirs.
out=$(REEVE_GROUP_NAMES='Old' STUB_LABEL=notes STUB_WS='w7' h ensure_group Aldric "w7$S" 2>"$SCRATCH/err")
eq  "1 a known id now showing a foreign label is not reused" "$out" "wNEW$S"
nas "1 nor renamed"                                          "$(calls)" "workspace rename"
has "1 which it says"                                        "$(cat "$SCRATCH/err")" "workspace w7 now shows 'notes'"
out=$(STUB_LABEL='' STUB_WS='w7' h ensure_group Aldric "w7$S" 2>/dev/null)
eq  "1 nor one showing no label at all"                      "$out" "wNEW$S"
nas "1 still renaming nothing"                               "$(calls)" "workspace rename"

# A known id from another server, or one kept before the socket was, names
# some other workspace here, perhaps the liege's. Never reused or renamed.
out=$(STUB_WS='w7' h ensure_group Aldric "w7@/elsewhere.sock")
eq  "1 a known id from another server is not reused"         "$out" "wNEW$S"
nas "1 nor renamed"                                          "$(calls)" "workspace rename"
out=$(STUB_WS='w7' h ensure_group Aldric w7)
eq  "1 a bare known id is on an unknown server: not reused"  "$out" "wNEW$S"
nas "1 nor renamed either"                                   "$(calls)" "workspace rename"

out=$(HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w99 STUB_WS='' h ensure_group Aldric "w7$S")
eq  "1 a gone own workspace and a gone known one: a new one" "$out" "wNEW$S"
has "1 created under the reeve's name, unfocused"            "$(calls)" "workspace create --cwd $HOME --label Aldric --no-focus"

# Workspace ids are per server. An id from another server's socket names some
# other workspace on this one, perhaps the liege's.
out=$(STUB_LABEL=Aldric HERDR_SOCKET_PATH=/elsewhere.sock HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Aldric "w7$S")
eq  "1 an own workspace on another server is not this one"   "$out" "w7$S"
nas "1 and the same-numbered one here is not renamed"        "$(calls)" "workspace rename"
out=$(STUB_LABEL=Aldric HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Aldric "w7$S")
eq  "1 nor when the socket is unknown"                       "$out" "w7$S"
nas "1 still renaming nothing"                               "$(calls)" "workspace rename"

# A hand sits in its reeve's workspace. It never takes it.
out=$(REEVE_HAND=fix-auth HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w61 STUB_WS='w61' h ensure_group Bran)
eq  "1 a hand never takes the workspace it sits in"          "$out" "wNEW$S"
nas "1 and never renames its reeve's"                        "$(calls)" "workspace rename"

# One reeve per workspace.
out=$(STUB_LABEL=Bran HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Bran "w7$S" "w61$S" 2>"$SCRATCH/err")
eq  "1 an own workspace another reeve holds is passed over"  "$out" "w7$S"
nas "1 and not renamed"                                      "$(calls)" "workspace rename"
has "1 which it says in one line"                            "$(cat "$SCRATCH/err")" "workspace w61 belongs to another live reeve"
out=$(STUB_LABEL=Bran HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Bran "w7$S" w61 2>/dev/null)
eq  "1 a bare held id holds that workspace too"              "$out" "w7$S"
out=$(HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Bran "w7$S" "w61@/elsewhere.sock")
eq  "1 one held on another server does not hold this one"    "$out" "w61$S"
out=$(STUB_WS='w7' h ensure_group Bran "w7$S" "w61$S" "w7$S")
eq  "1 a known one another reeve holds is not reused"        "$out" "wNEW$S"
# A server that lists no socket: nothing can be reused, and it says so once.
out=$(STUB_SOCK='' STUB_LABEL=Aldric STUB_WS='w7' h ensure_group Aldric "w7$S" 2>"$SCRATCH/err")
eq  "1 with no socket listed, a new workspace, bare"         "$out" wNEW
eq  "1 said once on stderr"                                  "$(grep -c 'lists no socket path' "$SCRATCH/err")" 1
out=$(STUB_LABEL=Aldric STUB_WS='w7' h ensure_group Aldric "w7$S" 2>"$SCRATCH/err")
eq  "1 and never when the socket is listed"                  "$(cat "$SCRATCH/err")" ''

echo "--- 2. herdr create_endpoint ---"
out=$(h create_endpoint "$PLAIN" "Aldric's scout: x" "w7$S")
# Each ends `#<identity>`, what the endpoint was made as: tests/restart.test.bash.
eq  "2 with a group, a three field target, no socket"     "${out%%#*}" "w7|w7:p9|w7:t9"
has "2 carrying its identity"                              "$out" "w7|w7:p9|w7:t9#c"
has "2 opened as a tab in that workspace"                  "$(calls)" "tab create --workspace w7 --cwd $PLAIN --label Aldric's scout: x --no-focus"
nas "2 and no workspace of its own"                        "$(calls)" "workspace create"

out=$(h create_endpoint "$PLAIN" "scout: x")
eq  "2 without a group, two fields, as before"             "${out%%#*}" "wNEW|wNEW:p1"
has "2 in a workspace of its own"                          "$(calls)" "workspace create --cwd $PLAIN --label scout: x --no-focus"

out=$(STUB_TAB_FAIL=1 h create_endpoint "$PLAIN" "scout: x" w7 2>/dev/null)
eq  "2 a tab herdr refuses falls back to a workspace"      "${out%%#*}" "wNEW|wNEW:p1"

echo "--- 3. parsing both target shapes ---"
eq "3 _h_ws, three fields"   "$( . "$ROOT/backends/herdr.sh"; _h_ws   'w7|w7:p9|w7:t9')" w7
eq "3 _h_pane, three fields" "$( . "$ROOT/backends/herdr.sh"; _h_pane 'w7|w7:p9|w7:t9')" w7:p9
eq "3 _h_tab, three fields"  "$( . "$ROOT/backends/herdr.sh"; _h_tab  'w7|w7:p9|w7:t9')" w7:t9
eq "3 _h_ws, two fields"     "$( . "$ROOT/backends/herdr.sh"; _h_ws   'w5|w5:p1')" w5
eq "3 _h_pane, two fields"   "$( . "$ROOT/backends/herdr.sh"; _h_pane 'w5|w5:p1')" w5:p1
eq "3 _h_tab, two fields"    "$( . "$ROOT/backends/herdr.sh"; _h_tab  'w5|w5:p1')" ''
h target_exists 'w7|w7:p9|w7:t9'
has "3 a nested target addresses its pane"                 "$(calls)" "pane get w7:p9 --session stub"

echo "--- 4. herdr kill never closes a reeve's workspace ---"
h kill 'w7|w7:p9|w7:t9'
has "4 a nested hand's tab is closed"                      "$(calls)" "tab close w7:t9"
nas "4 and its reeve's workspace is NOT"                   "$(calls)" "workspace close"
STUB_TAB_CLOSE_FAIL=1 h kill 'w7|w7:p9|w7:t9'
has "4 a tab that will not close falls back to its pane"   "$(calls)" "pane close w7:p9"
nas "4 still never the workspace"                          "$(calls)" "workspace close"
h kill 'w5|w5:p1'
has "4 a two field target still closes its own workspace"  "$(calls)" "workspace close w5"

echo "--- 5. herdr relabel ---"
h relabel 'w7|w7:p9|w7:t9' "Percy's scout: x"
has "5 a nested hand renames its tab"                      "$(calls)" "tab rename w7:t9 Percy's scout: x"
nas "5 never its reeve's workspace"                        "$(calls)" "workspace rename"
h relabel 'w5|w5:p1' "Percy's scout: x"
has "5 a two field target renames its workspace"           "$(calls)" "workspace rename w5 Percy's scout: x"

echo "--- 6. tmux ensure_group ---"
out=$(TMUX_PANE=%3 t ensure_group Aldric)
eq  "6 inside tmux, the reeve's own session"               "$out" work
has "6 its own window takes the name"                      "$(calls)" "rename-window -t @4 Aldric"
has "6 and keeps it"                                       "$(calls)" "set-window-option -t @4 automatic-rename off"
nas "6 the session is never renamed"                       "$(calls)" "rename-session"
out=$(REEVE_TMUX_SESSION=mine TMUX_PANE=%3 t ensure_group Aldric)
eq  "6 REEVE_TMUX_SESSION wins, as before"                 "$out" mine
nas "6 and renames nothing"                                "$(calls)" "rename-window"
out=$(TMUX_PANE=%3 t ensure_group Aldric '' work 2>"$SCRATCH/err")
eq  "6 a session another live reeve holds is not nested into" "$out" reeve-aldric
nas "6 and nothing in it is renamed"                       "$(calls)" "rename-window"
has "6 which it says"                                      "$(cat "$SCRATCH/err")" "session work belongs to another live reeve"
out=$(REEVE_HAND=fix-auth TMUX_PANE=%3 t ensure_group Bran)
eq  "6 a hand never takes its reeve's session"             "$out" reeve-bran
nas "6 or renames its window"                              "$(calls)" "rename-window"
out=$(t ensure_group Aldric)
eq  "6 outside tmux, a session named for the reeve"        "$out" reeve-aldric
has "6 made detached"                                      "$(calls)" "new-session -d -s reeve-aldric"
out=$(STUB_SES=reeve-aldric t ensure_group Aldric)
nas "6 and not made twice"                                 "$(calls)" "new-session"
# A rename: the detached session made under the old name takes the new one.
out=$(STUB_SES=reeve-aldric t ensure_group Galen reeve-aldric)
eq  "6 a known reeve-* session under an old name is kept"  "$out" reeve-galen
has "6 renamed to the new name"                            "$(calls)" "rename-session -t =reeve-aldric reeve-galen"
nas "6 not made afresh"                                    "$(calls)" "new-session"
out=$(STUB_SES=reeve-galen t ensure_group Galen reeve-galen)
nas "6 one already under the name is not renamed"          "$(calls)" "rename-session"
out=$(STUB_SES='work' t ensure_group Galen work)
nas "6 a session the liege named is never renamed"         "$(calls)" "rename-session"
has "6 a reeve-* one is made instead"                      "$(calls)" "new-session -d -s reeve-galen"
out=$(STUB_SES='' t ensure_group Galen reeve-aldric)
nas "6 a known session that is gone is not renamed"        "$(calls)" "rename-session"
has "6 a new one is made"                                  "$(calls)" "new-session -d -s reeve-galen"
out=$(STUB_SES='reeve-aldric reeve-galen' t ensure_group Galen reeve-aldric)
nas "6 nor when the new name is taken already"             "$(calls)" "rename-session"
eq  "6 which is then the group"                            "$out" reeve-galen
out=$(STUB_SES=reeve-aldric t ensure_group Galen reeve-aldric reeve-aldric)
nas "6 nor one another live reeve holds"                   "$(calls)" "rename-session"

echo "--- 7. tmux create_endpoint ---"
out=$(STUB_SES=work t create_endpoint "$PLAIN" "Aldric's scout: x" work)
eq  "7 a window in the group, the target shape unchanged"  "$out" "work|@9"
has "7 opened in that session"                             "$(calls)" "new-window -dP -F #{window_id} -t work: -n Aldric's scout: x"

echo "--- 8. dispatch, with and without a group ---"
git init -q "$SCRATCH/web"
git -C "$SCRATCH/web" -c user.email=r@invalid -c user.name=r -c commit.gpgsign=false commit -q --allow-empty -m init
python3 - "$CLAUDE_CONFIG" "$SCRATCH/web" <<'PY'
import json,sys,os
json.dump({"projects":{os.path.realpath(sys.argv[2]):{"hasTrustDialogAccepted":True}}},open(sys.argv[1],"w"))
PY
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/nest.sh" <<'ADAPTER'
reeve_backend_nest_available()       { return 0; }
reeve_backend_nest_describe()        { printf 'nest backend\n'; }
reeve_backend_nest_ensure_group()    { printf 'ensure_group %s\n' "$*" >> "$STUB_LOG"; printf 'grp1\n'; }
reeve_backend_nest_create_endpoint() { printf 'create_endpoint %s\n' "$#:${3:-}" >> "$STUB_LOG"; printf 'nest:1\n'; }
reeve_backend_nest_launch()          { return 0; }
ADAPTER
# A backend with no ensure_group at all, which the contract allows.
sed '/ensure_group/d; s/nest/bare/g' "$STUB/backends/nest.sh" > "$STUB/backends/bare.sh"
cat > "$STUB/harnesses/stub.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {prompt}"
prompt_mode = "argv"
HARNESS
"$ROOT/bin/reeve-survey" --register web --manor product --path "$SCRATCH/web" >/dev/null
REEVE_SESSION=lead "$ROOT/bin/reeve-name" claim Escanor >/dev/null 2>&1

go() { # go <id> <backend> [args...] -> OUT/RC
  local id=$1 b=$2; shift 2
  REEVE_SESSION=lead "$ROOT/bin/reeve-brief" "$id" web --office scout >/dev/null 2>&1
  local f="$REEVE_HOME/errands/$id/brief.md"
  sed -e 's/{INTENT}/x/' -e 's/{SPEC}/y/' "$f" > "$f.f" && mv "$f.f" "$f"
  : > "$LOG"
  OUT=$(REEVE_SESSION=lead REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" "$id" --backend "$b" --harness stub "$@" 2>&1); RC=$?
}

go one nest
eq  "8 a dispatch with a group succeeds"                     "$RC" 0
has "8 it asks for the reeve's group by name"                "$(calls)" "ensure_group Escanor"
has "8 and opens the hand inside it"                         "$(calls)" "create_endpoint 3:grp1"
eq  "8 the group id is kept, per backend"                    "$(cat "$REEVE_HOME/state/sessions/lead/group.nest" 2>/dev/null)" grp1
go two nest
has "8 the next dispatch hands the kept id back"             "$(calls)" "ensure_group Escanor grp1"

go three bare
eq  "8 a backend with no ensure_group still dispatches"      "$RC" 0
has "8 opening the hand as before, with no group"            "$(calls)" "create_endpoint 2:"
has "8 and says so once"                                     "$OUT" "gave Escanor no group"
eq  "8 the note is said once"                                "$(printf '%s\n' "$OUT" | grep -c 'no group')" 1

go four nest --dry-run
has "8 a dry run prints the ensure_group it would run"       "$OUT" "would run: reeve-backend call ensure_group Escanor \"grp1\" --backend nest"
has "8 and the group it would pass"                          "$OUT" "\"<group>\" --backend nest"
eq  "8 and calls nothing"                                    "$(calls)" ''
# The hand's own environment marks it, and loses the two variables that would
# make its reeve's workspace look like its own.
has "8 the hand is launched marked, its workspace and pane unset" "$OUT" \
    "env -u HERDR_WORKSPACE_ID -u TMUX_PANE REEVE_HAND='four' true"
# The dry run passes what the real call would: the held ids too.
mkdir -p "$REEVE_HOME/state/sessions/rival"; printf 'grpX\n' > "$REEVE_HOME/state/sessions/rival/group.nest"
printf '%s\n' "$(date +%s)" > "$REEVE_HOME/state/sessions/rival/seen"
go five nest --dry-run
has "8 a dry run prints every held id the real call passes"  "$OUT" "would run: reeve-backend call ensure_group Escanor \"grp1\" grpX --backend nest"
go six nest
has "8 which is the call the real dispatch makes"            "$(calls)" "ensure_group Escanor grp1 grpX"
rm -rf "$REEVE_HOME/state/sessions/rival"

echo "--- 9. reeve-name labels the reeve's own group ---"
: > "$LOG"
out=$(HERDR_ENV=1 REEVE_SESSION=lead REEVE_BACKEND=nest REEVE_ROOT="$STUB" "$ROOT/bin/reeve-name" 2>&1)
eq  "9 it still prints the name"                             "$out" Escanor
has "9 and asks the backend for the group"                   "$(calls)" "ensure_group Escanor grp1"
out=$(HERDR_ENV=1 REEVE_SESSION=lead REEVE_BACKEND=bare REEVE_ROOT="$STUB" "$ROOT/bin/reeve-name" 2>/dev/null); rc=$?
eq  "9 a backend with no group is no failure"                "$rc:$out" "0:Escanor"
: > "$LOG"
out=$(REEVE_SESSION=lead REEVE_BACKEND=nest REEVE_ROOT="$STUB" "$ROOT/bin/reeve-name" 2>&1)
eq  "9 outside any backend's session it prints the name"     "$out" Escanor
eq  "9 and makes no group: only a dispatch does"             "$(calls)" ''
out=$(REEVE_HAND=one HERDR_ENV=1 REEVE_SESSION=lead REEVE_BACKEND=nest REEVE_ROOT="$STUB" "$ROOT/bin/reeve-name" 2>&1)
eq  "9 from inside a hand it prints the name"                "$out" Escanor
eq  "9 and touches no group"                                 "$(calls)" ''

echo "--- 10. one reeve per workspace, through reeve-name and herdr ---"
# The real herdr backend over the stub, as a reeve inside herdr runs it.
SESS="$REEVE_HOME/state/sessions"
inherdr() { # inherdr <sid> <pane> <ws> [args...]   reeve-name inside herdr
  local sid=$1 pane=$2 ws=$3; shift 3
  : > "$LOG"
  env HERDR_ENV=1 HERDR_SOCKET_PATH="$STUB_SOCK" HERDR_PANE_ID="$pane" ${ws:+HERDR_WORKSPACE_ID="$ws"} \
    REEVE_SESSION="$sid" "$ROOT/bin/reeve-name" "$@" 2>"$SCRATCH/err"
}
export STUB_WS='w61 w7 w8'
export STUB_PANES='w61:p1 w61:p2 w61:p3 w9:p1 w5:p1'
out=$(inherdr r1 w61:p1 w61)
has "10 the first reeve takes its own workspace"             "$(calls)" "workspace rename w61 $out --session stub"
eq  "10 and keeps it, with its server"                       "$(cat "$SESS/r1/group.herdr")" "w61$S"
out=$(inherdr r2 w61:p2 w61)
nas "10 a second reeve in that workspace does not rename it" "$(calls)" "workspace rename w61"
has "10 it gets a workspace of its own, under its own name"  "$(calls)" "workspace create --cwd $HOME --label $out --no-focus"
eq  "10 kept as its own"                                     "$(cat "$SESS/r2/group.herdr")" "wNEW$S"
eq  "10 and it says why, in one line"                        "$(grep -c 'belongs to another live reeve' "$SCRATCH/err")" 1
has "10 the holder's pane is asked of its own server"        "$(calls)" "pane get w61:p1 --session stub"

# Taking over: only once the holder's pane is closed, whatever its heartbeat.
printf '1\n' > "$SESS/r1/seen"
out=$(inherdr r3 w61:p3 w61)
nas "10 a quiet reeve whose pane is open keeps its workspace" "$(calls)" "workspace rename w61"
out=$(STUB_PANES='w61:p2 w61:p3' STUB_PANE_ERR=1 inherdr r3 w61:p3 w61)
nas "10 a pane that cannot be checked keeps it too"          "$(calls)" "workspace rename w61"
printf 'w61:p1@/elsewhere.sock\n' > "$SESS/r1/pane"
out=$(STUB_PANES='w61:p2 w61:p3' inherdr r3 w61:p3 w61)
nas "10 so does a pane on a server no session answers for"   "$(calls)" "workspace rename w61"
printf 'w61:p1\n' > "$SESS/r1/pane"
out=$(STUB_PANES='w61:p2 w61:p3' inherdr r3 w61:p3 w61)
nas "10 and a bare pane, which names no server to ask"       "$(calls)" "workspace rename w61"
printf 'w61:p1@%s\n' "$STUB_SOCK" > "$SESS/r1/pane"
printf '%s\n' "$(date +%s)" > "$SESS/r1/seen"
out=$(STUB_PANES='w61:p2 w61:p3' inherdr r3 w61:p3 w61)
has "10 a closed pane frees it, however fresh the heartbeat" "$(calls)" "workspace rename w61 $out --session stub"
eq  "10 and the taker keeps it"                              "$(cat "$SESS/r3/group.herdr")" "w61$S"
rm -rf "$SESS/r1" "$SESS/r2" "$SESS/r3"

# /clear: a new session id on the same pane takes the name, and its group, even
# where there is no own workspace to fall back on.
mkdir -p "$SESS/old"; printf 'Merek\n' > "$SESS/old/name"; printf 'w9:p1@%s\n' "$STUB_SOCK" > "$SESS/old/pane"
printf '%s\n' "$(date +%s)" > "$SESS/old/seen"; printf 'w7%s\n' "$S" > "$SESS/old/group.herdr"
out=$(STUB_LABEL=Merek inherdr new w9:p1 '')
eq  "10 /clear keeps the name"                               "$out" Merek
nas "10 and makes no new workspace"                          "$(calls)" "workspace create"
eq  "10 it keeps the group its name had"                     "$(cat "$SESS/new/group.herdr" 2>/dev/null)" "w7$S"
rm -rf "$SESS/new"
# A record from before the socket was kept: its bare pane is this same pane,
# so the name carries over and its group is not held against it. Its bare
# group id names an unknown server, so that is not reused.
printf 'w9:p1\n' > "$SESS/old/pane"; printf 'w7\n' > "$SESS/old/group.herdr"
out=$(inherdr new w9:p1 w7)
eq  "10 an old bare pane record is this pane: the name stays" "$out" Merek
has "10 and its workspace is not held against it"            "$(calls)" "workspace rename w7 Merek --session stub"
rm -rf "$SESS/new"
out=$(inherdr new w9:p1 '')
nas "10 an old bare group id is not reused"                  "$(calls)" "workspace get w7"
eq  "10 a new one is made instead"                           "$(cat "$SESS/new/group.herdr" 2>/dev/null)" "wNEW$S"
rm -rf "$SESS/old" "$SESS/new"

# claim: a handoff's name brings the group that name kept.
mkdir -p "$SESS/gone"; printf 'Wulf\n' > "$SESS/gone/name"; printf '1\n' > "$SESS/gone/seen"
printf 'w8%s\n' "$S" > "$SESS/gone/group.herdr"
out=$(STUB_LABEL=Wulf inherdr heir w5:p1 '' claim Wulf)
eq  "10 claim takes the name"                                "$out" Wulf
nas "10 and makes no new workspace"                          "$(calls)" "workspace create"
eq  "10 it takes the group the name kept"                    "$(cat "$SESS/heir/group.herdr" 2>/dev/null)" "w8$S"
# set: the reeve keeps its group, relabelled under the new name.
out=$(STUB_LABEL=Wulf inherdr heir w5:p1 '' set Galen)
has "10 set relabels the reeve's own group"                  "$(calls)" "workspace rename w8 Galen --session stub"
nas "10 and makes no second one"                             "$(calls)" "workspace create"
# Outside herdr, set has nothing to relabel yet. It keeps the group, and the
# next dispatch renames it, rather than leaving it under the old name.
: > "$LOG"
REEVE_SESSION=heir "$ROOT/bin/reeve-name" set Percy >/dev/null 2>&1
eq  "10 set outside herdr keeps the group"                   "$(cat "$SESS/heir/group.herdr" 2>/dev/null)" "w8$S"
eq  "10 and touches no backend"                              "$(calls)" ''
out=$(STUB_LABEL=Galen REEVE_SESSION=heir bash -c '. "$1/bin/reeve-lib.sh"; reeve_group "$1/bin" herdr Percy' _ "$ROOT" 2>/dev/null)
eq  "10 the next dispatch reuses it"                         "$out" "w8$S"
has "10 relabelled with the new name"                        "$(calls)" "workspace rename w8 Percy --session stub"
nas "10 and none is made"                                    "$(calls)" "workspace create"
# Only a label this reeve's records held is renamed: one the liege gave the
# id since, as after a server restart, is left alone and a new one made.
: > "$LOG"
out=$(STUB_LABEL=notes REEVE_SESSION=heir bash -c '. "$1/bin/reeve-lib.sh"; reeve_group "$1/bin" herdr Percy' _ "$ROOT" 2>/dev/null)
eq  "10 a known id showing a foreign label is not reused"    "$out" "wNEW$S"
nas "10 nor renamed"                                         "$(calls)" "workspace rename"
eq  "10 every name the reeve held is recorded"               "$(tr '\n' ' ' < "$SESS/heir/names")" "Wulf Galen Percy "

echo "--- 11. the herdr launch proof finds the binary behind env ---"
B="$SCRATCH/brief.md"; : > "$B"
for f in "$ROOT"/harnesses/*.toml; do
  n=$(basename "$f" .toml)
  line=$("$ROOT/bin/reeve-harness" render "$n" "$B" --settings "$SCRATCH/s.json" --hand fix-x 2>/dev/null)
  want=$(basename -- "$("$ROOT/bin/reeve-harness" get "$n" bin "$n")")
  case $line in 'env -u '*) ;; *) bad "11 $n renders the hand prefix" "$line"; continue ;; esac
  eq "11 $n: the binary behind the --hand prefix" "$( . "$ROOT/backends/herdr.sh"; _h_expected_bin "$line")" "$want"
done
xb() { ( . "$ROOT/backends/herdr.sh"; _h_expected_bin "$1" ); }
eq "11 -i, -u=X, --unset Y, --unset=Z and - are all skipped" \
   "$(xb "env -i -u=A --unset B --unset=C - -u D E='1 2' /usr/local/bin/claude --x")" claude
eq "11 a quoted value with a quote inside"   "$(xb "env A='it'\\''s a b' B='c d' pi go")" pi
eq "11 assignments with no env still are"     "$(xb "A=1 B=2 codex run")" codex
eq "11 a stdin line reads after the pipe"     "$(xb "printf '%s' 'Read the * file' | env -u X REEVE_HAND='a' gemini")" gemini
eq "11 a glob in the line is not expanded"    "$(cd "$SCRATCH" && xb "* claude")" '*'
line=$("$ROOT/bin/reeve-harness" render claude "$B" --settings "$SCRATCH/s.json" --hand fix-x 2>/dev/null)
STUB_FG=claude h launch 'w7|w7:p9|w7:t9' "$line"; rc=$?
eq  "11 launch proves the hand once claude is in the foreground" "$rc" 0
has "11 the line was run in the hand's pane"                     "$(calls)" "pane run w7:p9"
has "11 its foreground was read"                                 "$(calls)" "pane process-info --pane w7:p9"
nas "11 and no Enter was nudged into it"                         "$(calls)" "send-keys"

echo "--- 12. pane_gone, per backend ---"
pg() { ( . "$ROOT/backends/$1.sh"; shift; "reeve_backend_$@" ) && echo gone || echo here; }
eq "12 herdr: a pane its server says is not found is gone" "$(STUB_PANES='' pg herdr herdr_pane_gone w1:p1 "$STUB_SOCK")" gone
eq "12 herdr: an existing pane is not"                     "$(STUB_PANES='w1:p1' pg herdr herdr_pane_gone w1:p1 "$STUB_SOCK")" here
eq "12 herdr: a server error proves nothing"               "$(STUB_PANES='' STUB_PANE_ERR=1 pg herdr herdr_pane_gone w1:p1 "$STUB_SOCK")" here
eq "12 herdr: nor does a socket no session listens on"     "$(STUB_PANES='' pg herdr herdr_pane_gone w1:p1 /elsewhere.sock)" here
eq "12 herdr: nor does no socket at all"                   "$(STUB_PANES='' pg herdr herdr_pane_gone w1:p1 '')" here
: > "$LOG"
eq "12 tmux: a pane its server does not list is gone"      "$(STUB_TPANES='%1 %2' pg tmux tmux_pane_gone %3 /tmp/t.sock)" gone
has "12 tmux: asked of that socket"                        "$(calls)" "-S /tmp/t.sock list-panes -a"
eq "12 tmux: a listed pane is not"                         "$(STUB_TPANES='%1 %3' pg tmux tmux_pane_gone %3 /tmp/t.sock)" here
eq "12 tmux: a server that does not answer proves nothing" "$(STUB_TMUX_DOWN=1 pg tmux tmux_pane_gone %3 /tmp/t.sock)" here

pe() { bash -c '. "$1/bin/reeve-lib.sh"; pane_eq "$2" "$3"' _ "$ROOT" "$1" "$2" && echo same || echo other; }
eq "12 pane_eq: one key"                              "$(pe '%3@/a' '%3@/a')" same
eq "12 pane_eq: an old bare key matches by id"        "$(pe '%3' '%3@/a')" same
eq "12 pane_eq: either way round"                     "$(pe 'w1:p1@/a' 'w1:p1')" same
eq "12 pane_eq: two servers are two panes"            "$(pe '%3@/a' '%3@/b')" other
eq "12 pane_eq: no pane is no match"                  "$(pe '' '%3')" other

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
