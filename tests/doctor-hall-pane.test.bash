#!/usr/bin/env bash
# reeve-doctor and reeve-backend list never run herdr from a hall pane.
#
# A hall pane carries herdr's variables too, set to hall's own server, and
# herdr's checks with no session of their own read herdr's config folder: from
# a live hall pane, the live one. So with HALL_ENV=1 neither asks herdr anything
# and each says so in one line. Outside hall (a herdr pane, a plain terminal)
# both run exactly the herdr calls they always did and print what they always
# printed.
#
# herdr and hall are fakes first on PATH that record their argv, so nothing
# here touches a real server. Scratch home only.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not on PATH, which the herdr backend needs"; echo "passed=0 failed=0"; exit 0; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
case $SCRATCH in "$real_home"|"$real_home"/*) printf 'FAIL  refusing: scratch is inside the real home\n'; exit 1 ;; esac
trap 'rm -rf "${SCRATCH:?}"' EXIT
export REEVE_HOME="$SCRATCH/home"
export REEVE_NO_CARETAKER=1
export CLAUDE_CONFIG="$SCRATCH/claude.json"
mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/config"
unset CLAUDE_CODE_SESSION_ID REEVE_NAME REEVE_HAND REEVE_BACKEND REEVE_ROOT \
      HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH \
      HERDR_SESSION REEVE_HERDR_SESSION \
      HALL_ENV HALL_PANE_ID HALL_SOCKET_PATH HALL_TAB_ID HALL_WORKSPACE_ID HALL_BIN_PATH \
      HALL_SESSION HALL_CLIENT_SOCKET_PATH REEVE_HALL_BIN REEVE_HALL_SOCKET REEVE_HALL_SESSION
# One session id throughout, so two doctor runs read the same records.
export REEVE_SESSION=doc-test

FAKE="$SCRATCH/fakebin"; mkdir -p "$FAKE"
HERDR_LOG="$SCRATCH/herdr-calls"; HALL_LOG="$SCRATCH/hall-calls"; export HERDR_LOG HALL_LOG
# herdr answers like a running one with a default session, so outside hall its
# row reads available and every check it makes is visible in the log.
cat > "$FAKE/herdr" <<'HERDR'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_LOG"
case "$1 ${2:-}" in
  '--version ') echo "herdr 0.9.0" ;;
  'status server') printf '{"result":{}}\n' ;;
  'session list') printf '{"sessions":[{"name":"default","default":true,"socket_path":"/fake/herdr.sock"}]}\n' ;;
  *) exit 1 ;;
esac
HERDR
cat > "$FAKE/hall" <<'HALL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HALL_LOG"
case "$1 ${2:-}" in
  '--version ') echo "hall 0.1.0" ;;
  *) exit 1 ;;
esac
HALL
chmod +x "$FAKE/herdr" "$FAKE/hall"
export PATH="$FAKE:$PATH"

reset() { : > "$HERDR_LOG"; : > "$HALL_LOG"; }
# A hall pane: HALL_ENV and hall's own pair, with herdr's pair set to the same
# server, as hall sets both in its panes.
inhall() {
  env HALL_ENV=1 HALL_PANE_ID=w1:p1 HALL_SOCKET_PATH=/fake/hall.sock HALL_WORKSPACE_ID=w1 \
      HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=/fake/hall.sock HERDR_WORKSPACE_ID=w1 \
      REEVE_BACKEND=hall "$@"
}

# Warm the home once, so the runs compared below see the same records.
"$ROOT/bin/reeve-doctor" >/dev/null 2>&1

echo "--- 1. outside hall: herdr is asked, as before ---"
reset
list=$("$ROOT/bin/reeve-backend" list 2>&1)
has "1 list: herdr available, with its version and session"  "$list" "herdr    available   herdr 0.9.0 (session default)"
eq  "1 list: the herdr calls it always made"                  "$(cat "$HERDR_LOG")" "status server --json
session list --json
--version
session list --json"
reset
plain=$("$ROOT/bin/reeve-doctor" 2>&1)
has "1 doctor: herdr's version in tools"                      "$plain" "herdr   ok    0.9.0"
has "1 doctor: herdr available in backends"                   "$plain" "  herdr    available   herdr 0.9.0 (session default)"
eq  "1 doctor: --version, then the list's calls"              "$(cat "$HERDR_LOG")" "--version
status server --json
session list --json
--version
session list --json"
nas "1 doctor: no hall-pane note"                             "$plain" "hall pane"

echo "--- 2. inside a hall pane: herdr is never run ---"
reset
list=$(inhall "$ROOT/bin/reeve-backend" list 2>&1)
eq  "2 list: no herdr call"                                   "$(cat "$HERDR_LOG")" ''
has "2 list: one line says herdr was not probed, and where to" "$list" "herdr    not probed from a hall pane. run reeve-backend list in a herdr pane or a plain terminal to check it"
eq  "2 list: that is herdr's only line"                       "$(printf '%s\n' "$list" | grep -c '^herdr')" 1
reset
inpane=$(inhall "$ROOT/bin/reeve-doctor" 2>&1)
eq  "2 doctor: no herdr call"                                 "$(cat "$HERDR_LOG")" ''
has "2 doctor: tools says herdr was not probed"               "$inpane" "  herdr   not probed (hall pane)"
nas "2 doctor: and never calls that row ok"                   "$inpane" "herdr   ok"
has "2 doctor: backends says herdr was not probed"            "$inpane" "  herdr    not probed from a hall pane."
has "2 doctor: hall is still checked"                         "$(cat "$HALL_LOG")" "--version"

echo "--- 3. and only those two lines differ ---"
# Same home, same session, HALL_ENV the one difference: everything but herdr's
# two rows and the default backend (section 5) reads the same.
reset
gated=$(HALL_ENV=1 "$ROOT/bin/reeve-doctor" 2>&1)
eq  "3 HALL_ENV alone: no herdr call"                         "$(cat "$HERDR_LOG")" ''
eq  "3 the rest of the doctor is the same in both"            "$(diff <(printf '%s\n' "$plain") <(printf '%s\n' "$gated") | grep '^[<>]' | sed 's/^[<>] //' | sort)" \
"  default     hall
  default     herdr
  herdr    available   herdr 0.9.0 (session default)
  herdr    not probed from a hall pane. run reeve-backend list in a herdr pane or a plain terminal to check it
  herdr   not probed (hall pane)
  herdr   ok    0.9.0"

echo "--- 4. HALL_ENV set to anything else is not a hall pane ---"
reset
HALL_ENV=0 "$ROOT/bin/reeve-backend" list >/dev/null 2>&1
has "4 HALL_ENV=0: herdr asked as before"                     "$(cat "$HERDR_LOG")" "status server --json"

echo "--- 5. a hall pane with no backend named resolves hall ---"
# Hall sets REEVE_BACKEND=hall in its panes. Without it (an older hall, a shell
# that unset it) the default must still not be herdr, or reeve-name and
# dispatch would make a workspace on the live herdr server.
eq  "5 HALL_ENV=1 alone resolves hall"                        "$(HALL_ENV=1 "$ROOT/bin/reeve-backend" resolve)" hall
eq  "5 REEVE_BACKEND still wins"                              "$(HALL_ENV=1 REEVE_BACKEND=herdr "$ROOT/bin/reeve-backend" resolve)" herdr
eq  "5 so does --backend"                                     "$(HALL_ENV=1 "$ROOT/bin/reeve-backend" resolve --backend herdr)" herdr
printf 'herdr\n' > "$REEVE_HOME/config/backend"
eq  "5 and so does config/backend"                            "$(HALL_ENV=1 "$ROOT/bin/reeve-backend" resolve)" herdr
rm -f "${REEVE_HOME:?}/config/backend"
eq  "5 outside hall the default is herdr"                     "$("$ROOT/bin/reeve-backend" resolve)" herdr
eq  "5 HALL_ENV=0 is not a hall pane"                         "$(HALL_ENV=0 "$ROOT/bin/reeve-backend" resolve)" herdr
reset
env HALL_ENV=1 HALL_PANE_ID=w1:p1 HALL_SOCKET_PATH=/fake/hall.sock HALL_WORKSPACE_ID=w1 HALL_TAB_ID=w1:t1 \
    HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=/fake/hall.sock HERDR_WORKSPACE_ID=w1 \
    REEVE_SESSION=name-test "$ROOT/bin/reeve-name" >/dev/null 2>&1
eq  "5 reeve-name in a hall pane, no REEVE_BACKEND: no herdr call" "$(cat "$HERDR_LOG")" ''
has "5 it labels through hall instead"                        "$(cat "$HALL_LOG")" "workspace"

echo "--- 6. cleanup can never widen ---"
# An rm on a variable path refuses an empty variable rather than deleting from /.
eq  "6 every rm -rf here on a variable uses :?"               "$(grep -n 'rm -rf "\$' "${BASH_SOURCE[0]}" | grep -v ':?}' | grep -v 'grep -n')" ''

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
