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
# herdr: STUB_WS lists the workspaces that exist. tab create answers with a tab
# and root pane in the workspace it was asked for, unless STUB_TAB_FAIL is set.
# Its one session, `stub`, listens on $STUB_SOCK.
cat > "$FAKE/herdr" <<'HERDR'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  'session list')
    printf '{"sessions":[{"default":true,"name":"stub","socket_path":"%s"}]}\n' "$STUB_SOCK" ;;
  'workspace get')
    for w in ${STUB_WS:-}; do [ "$w" = "$3" ] && { printf '{"result":{"workspace":{"workspace_id":"%s"}}}\n' "$3"; exit 0; }; done
    printf '{"error":{"code":"workspace_not_found"}}\n'; exit 1 ;;
  'workspace create')
    printf '{"result":{"workspace":{"workspace_id":"wNEW"},"tab":{"tab_id":"wNEW:t1"},"root_pane":{"pane_id":"wNEW:p1"}}}\n' ;;
  'tab create')
    [ -n "${STUB_TAB_FAIL:-}" ] && { printf '{"error":{"code":"nope"}}\n'; exit 1; }
    ws=''; prev=''
    for a in "$@"; do [ "$prev" = --workspace ] && ws=$a; prev=$a; done
    printf '{"result":{"tab":{"tab_id":"%s:t9"},"root_pane":{"pane_id":"%s:p9","tab_id":"%s:t9"}}}\n' "$ws" "$ws" "$ws" ;;
  'tab close')
    [ -n "${STUB_TAB_CLOSE_FAIL:-}" ] && exit 1
    printf '{"result":{"type":"ok"}}\n' ;;
  'workspace rename'|'workspace close'|'tab rename'|'pane close')
    printf '{"result":{"type":"ok"}}\n' ;;
  *) exit 1 ;;
esac
HERDR
# tmux: the reeve runs in pane %3, window @4, session `work`. STUB_SES lists the
# sessions that exist.
cat > "$FAKE/tmux" <<'TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case $1 in
  display)
    case $* in *session_name*) echo work ;; *window_id*) echo @4 ;; esac ;;
  has-session)
    t=${3#=}; for s in ${STUB_SES:-}; do [ "$s" = "$t" ] && exit 0; done; exit 1 ;;
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
out=$(HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Aldric w7)
eq  "1 the reeve's own workspace is preferred to a known one" "$out" w61
has "1 and renamed to the reeve's name"                       "$(calls)" "workspace rename w61 Aldric --session stub"
nas "1 and nothing is created"                                "$(calls)" "workspace create"

out=$(STUB_WS='w7' h ensure_group Aldric w7)
eq  "1 outside herdr, a known group still there is reused"   "$out" w7
nas "1 without creating another"                             "$(calls)" "workspace create"
nas "1 or renaming one it did not ask about"                 "$(calls)" "workspace rename"

out=$(HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w99 STUB_WS='' h ensure_group Aldric w7)
eq  "1 a gone own workspace and a gone known one: a new one" "$out" wNEW
has "1 created under the reeve's name, unfocused"            "$(calls)" "workspace create --cwd $HOME --label Aldric --no-focus"

# Workspace ids are per server. An id from another server's socket names some
# other workspace on this one, perhaps the liege's.
out=$(HERDR_SOCKET_PATH=/elsewhere.sock HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Aldric w7)
eq  "1 an own workspace on another server is not this one"   "$out" w7
nas "1 and the same-numbered one here is not renamed"        "$(calls)" "workspace rename"
out=$(HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Aldric w7)
eq  "1 nor when the socket is unknown"                       "$out" w7
nas "1 still renaming nothing"                               "$(calls)" "workspace rename"

# A hand sits in its reeve's workspace. It never takes it.
out=$(REEVE_HAND=fix-auth HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w61 STUB_WS='w61' h ensure_group Bran)
eq  "1 a hand never takes the workspace it sits in"          "$out" wNEW
nas "1 and never renames its reeve's"                        "$(calls)" "workspace rename"

# One reeve per workspace.
out=$(HERDR_SOCKET_PATH=$STUB_SOCK HERDR_WORKSPACE_ID=w61 STUB_WS='w61 w7' h ensure_group Bran w7 w61 2>"$SCRATCH/err")
eq  "1 an own workspace another live reeve holds is passed over" "$out" w7
nas "1 and not renamed"                                      "$(calls)" "workspace rename"
has "1 which it says in one line"                            "$(cat "$SCRATCH/err")" "workspace w61 belongs to another live reeve"
out=$(STUB_WS='w7' h ensure_group Bran w7 w61 w7)
eq  "1 a known one another live reeve holds is not reused"   "$out" wNEW

echo "--- 2. herdr create_endpoint ---"
out=$(h create_endpoint "$PLAIN" "Aldric's scout: x" w7)
eq  "2 with a group, a three field target"                 "$out" "w7|w7:p9|w7:t9"
has "2 opened as a tab in that workspace"                  "$(calls)" "tab create --workspace w7 --cwd $PLAIN --label Aldric's scout: x --no-focus"
nas "2 and no workspace of its own"                        "$(calls)" "workspace create"

out=$(h create_endpoint "$PLAIN" "scout: x")
eq  "2 without a group, two fields, as before"             "$out" "wNEW|wNEW:p1"
has "2 in a workspace of its own"                          "$(calls)" "workspace create --cwd $PLAIN --label scout: x --no-focus"

out=$(STUB_TAB_FAIL=1 h create_endpoint "$PLAIN" "scout: x" w7 2>/dev/null)
eq  "2 a tab herdr refuses falls back to a workspace"      "$out" "wNEW|wNEW:p1"

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
out=$(inherdr r1 w61:p1 w61)
has "10 the first reeve takes its own workspace"             "$(calls)" "workspace rename w61 $out --session stub"
eq  "10 and keeps it"                                        "$(cat "$SESS/r1/group.herdr")" w61
out=$(inherdr r2 w61:p2 w61)
nas "10 a second reeve in that workspace does not rename it" "$(calls)" "workspace rename w61"
has "10 it gets a workspace of its own, under its own name"  "$(calls)" "workspace create --cwd $HOME --label $out --no-focus"
eq  "10 kept as its own"                                     "$(cat "$SESS/r2/group.herdr")" wNEW
eq  "10 and it says why, in one line"                        "$(grep -c 'belongs to another live reeve' "$SCRATCH/err")" 1
# The first reeve is gone. Its workspace is free to take over.
printf '1\n' > "$SESS/r1/seen"
out=$(inherdr r3 w61:p3 w61)
has "10 a gone reeve's workspace may be taken over"          "$(calls)" "workspace rename w61 $out --session stub"

# /clear: a new session id on the same pane takes the name, and its group, even
# where there is no own workspace to fall back on.
mkdir -p "$SESS/old"; printf 'Merek\n' > "$SESS/old/name"; printf 'w9:p1@%s\n' "$STUB_SOCK" > "$SESS/old/pane"
printf '%s\n' "$(date +%s)" > "$SESS/old/seen"; printf 'w7\n' > "$SESS/old/group.herdr"
out=$(inherdr new w9:p1 '')
eq  "10 /clear keeps the name"                               "$out" Merek
nas "10 and makes no new workspace"                          "$(calls)" "workspace create"
eq  "10 it keeps the group its name had"                     "$(cat "$SESS/new/group.herdr" 2>/dev/null)" w7

# claim: a handoff's name brings the group that name kept.
mkdir -p "$SESS/gone"; printf 'Wulf\n' > "$SESS/gone/name"; printf '1\n' > "$SESS/gone/seen"
printf 'w8\n' > "$SESS/gone/group.herdr"
out=$(inherdr heir w5:p1 '' claim Wulf)
eq  "10 claim takes the name"                                "$out" Wulf
nas "10 and makes no new workspace"                          "$(calls)" "workspace create"
eq  "10 it takes the group the name kept"                    "$(cat "$SESS/heir/group.herdr" 2>/dev/null)" w8
# set: a group kept under the old name goes with the old name.
out=$(inherdr heir w5:p1 '' set Galen)
has "10 set takes a group under the new name"                "$(calls)" "workspace create --cwd $HOME --label Galen --no-focus"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
