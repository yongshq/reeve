#!/usr/bin/env bash
# The mason was called the artificer. Errands sent out before the rename record
# office=artificer, and a reeve may still type the old name, so the old name is
# read as the mason everywhere and never written again. Records already on disk
# are never rewritten.
#
# Pinned here:
#   1. office_canon maps the old name to the mason and leaves every other name,
#      printed and into a variable
#   2. `reeve-brief --office artificer` briefs a mason, with one stderr line
#      naming the old name: the record, the brief and the copy all say mason
#   3. reeve-listing and reeve-status show mason for an office=artificer record
#   4. a mason's harness still reads config/harness-artificer when no
#      config/harness-mason is set, and config/harness-mason wins over it
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1" "did not mention [$3] in: $2" ;; esac; }
nas() { case $2 in *"$3"*) bad "$1" "should not have mentioned [$3]" ;; *) ok "$1" ;; esac; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
case $SCRATCH in "$real_home"|"$real_home"/*) printf 'FAIL  refusing: scratch is inside the real home\n'; exit 1 ;; esac
trap 'rm -rf "$SCRATCH"' EXIT
unset CLAUDE_CODE_SESSION_ID REEVE_SESSION REEVE_NAME REEVE_HAND REEVE_BACKEND REEVE_ROOT \
      HERDR_ENV HERDR_PANE_ID HALL_ENV HALL_PANE_ID HALL_SOCKET_PATH HALL_TAB_ID HALL_WORKSPACE_ID \
      HALL_BIN_PATH HALL_SESSION HALL_CLIENT_SOCKET_PATH REEVE_HALL_BIN REEVE_HALL_SOCKET REEVE_HALL_SESSION
export REEVE_HOME="$SCRATCH/home"
mkdir -p "$REEVE_HOME"

REPO="$SCRATCH/holding"
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" -c user.email=reeve@example.invalid -c user.name=reeve \
    -c commit.gpgsign=false commit -q --allow-empty -m init

echo "--- 1. the helper ---"
. "$ROOT/bin/reeve-lib.sh"
eq "1 the old name reads as the mason"   "$(office_canon artificer)" mason
eq "1 the mason stays the mason"         "$(office_canon mason)" mason
eq "1 any other office is left alone"    "$(office_canon scout)|$(office_canon '')" "scout|"
v=''; office_canon artificer v
eq "1 into a variable, with no subshell" "$v" mason

echo "--- 2. --office artificer briefs a mason ---"
err=$("$ROOT/bin/reeve-brief" old-name "$REPO" --office artificer 2>&1 >/dev/null); rc=$?
eq  "2 the brief is written"             "$rc" 0
eq  "2 one stderr line"                  "$(printf '%s\n' "$err" | grep -c .)" 1
has "2 naming the old name"              "$err" "office 'artificer' is the old name of the mason"
eq  "2 the record says mason"            "$(sed -n 's/^office=//p' "$REEVE_HOME/state/old-name.meta")" mason
eq  "2 on a mason's branch"              "$(sed -n 's/^branch=//p' "$REEVE_HOME/state/old-name.meta")" feat/old-name
eq  "2 in a mason's copy"                "$(sed -n 's/^worktree=//p' "$REEVE_HOME/state/old-name.meta")" \
                                         "$SCRATCH/holding.worktrees/mason-old-name"
b=$(cat "$REEVE_HOME/errands/old-name/brief.md")
has "2 the brief names the mason"        "$b" '| office | `mason` |'
has "2 and carries the mason's office"   "$b" '## Office: mason'
err=$("$ROOT/bin/reeve-brief" new-name "$REPO" --office mason 2>&1 >/dev/null)
eq  "2 the new name says nothing"        "$err" ''

echo "--- 3. readers show an old record as a mason ---"
printf '%s\n' office=artificer session=s-old 'target=s|s:p1' dispatched=2026-10-01T10:00:00 \
  > "$REEVE_HOME/state/old-rec.meta"
mkdir -p "$REEVE_HOME/errands/old-rec"
printf 'working: 2026-10-01T10:00:00Z building\n' > "$REEVE_HOME/errands/old-rec/status"
out=$("$ROOT/bin/reeve-listing")
has "3 the listing shows mason"          "$out" '"id":"old-rec","office":"mason"'
nas "3 and never the old name"           "$out" 'artificer'
out=$("$ROOT/bin/reeve-status" --all --no-wake 2>/dev/null)
eq  "3 the status table shows mason"     "$(printf '%s\n' "$out" | awk '$1 == "old-rec" { print $2 }')" mason
out=$("$ROOT/bin/reeve-status" old-rec --no-wake 2>/dev/null)
has "3 and so does one errand's status"  "$out" 'office    mason on'
eq  "3 the record is left as it was"     "$(sed -n 's/^office=//p' "$REEVE_HOME/state/old-rec.meta")" artificer

echo "--- 4. the old config name still picks a mason's harness ---"
unset REEVE_HARNESS
mkdir -p "$REEVE_HOME/config"
printf 'codex\n' > "$REEVE_HOME/config/harness-artificer"
eq  "4 harness-artificer alone picks it" "$("$ROOT/bin/reeve-harness" resolve --office mason)" codex
eq  "4 and for an old-name record too"   "$("$ROOT/bin/reeve-harness" resolve --office artificer)" codex
eq  "4 never for another office"         "$("$ROOT/bin/reeve-harness" resolve --office scout)" claude
printf 'pi\n' > "$REEVE_HOME/config/harness-mason"
eq  "4 harness-mason wins over it"       "$("$ROOT/bin/reeve-harness" resolve --office mason)" pi
rm -f "$REEVE_HOME/config/harness-artificer" "$REEVE_HOME/config/harness-mason"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
