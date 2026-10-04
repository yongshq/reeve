#!/usr/bin/env bash
# The tmux backend was removed and herdr is the only one shipped. A flag, the
# environment, a config file or an old errand record that still names tmux is
# refused by name, never crashes, and the errand still lists.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }

SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/home"
export REEVE_NO_CARETAKER=1
unset REEVE_BACKEND REEVE_ROOT HERDR_ENV
mkdir -p "$REEVE_HOME/state" "$REEVE_HOME/config"
B="$ROOT/bin/reeve-backend"

eq  "1 with nothing set, herdr"                  "$("$B" resolve 2>&1)" herdr
WHY='backend tmux was removed. herdr is the only backend'
out=$("$B" resolve --backend tmux 2>&1); rc=$?
eq  "1 a flag naming it is refused"              "$rc" 1
has "1 by name"                                  "$out" "$WHY"
out=$(REEVE_BACKEND=tmux "$B" resolve 2>&1); rc=$?
eq  "1 so is the environment"                    "$rc" 1
has "1 by name too"                              "$out" "$WHY"
printf 'tmux\n' > "$REEVE_HOME/config/backend"
out=$("$B" resolve 2>&1); rc=$?
eq  "1 and the config file"                      "$rc" 1
has "1 saying how to fix it"                     "$out" "set backend=herdr or unset it"
rm -f "$REEVE_HOME/config/backend"
out=$("$B" call agent_state 'x|%3' --backend tmux 2>&1); rc=$?
eq  "1 a call for an old record refuses"         "$rc" 1
has "1 the same way"                             "$out" "$WHY"
out=$("$B" resolve --backend nonesuch 2>&1)
has "1 an unknown name is still only unknown"    "$out" "unknown backend 'nonesuch'"

# An errand dispatched before the removal still lists: its process reads as
# unreadable, since nothing can ask a removed backend.
mkdir -p "$REEVE_HOME/errands/old"
printf 'working: on it\n' > "$REEVE_HOME/errands/old/status"
printf 'target=work|@4\nbackend=tmux\noffice=scout\nrepo=\nworktree=\nbranch=\nbase=main\nwrites=no\ndispatched=2026-09-28T20:25:26\n' \
  > "$REEVE_HOME/state/old.meta"
out=$("$ROOT/bin/reeve-status" --all --no-wake 2>&1); rc=$?
eq  "2 the listing does not fail"                "$rc" 0
has "2 and still shows the errand"               "$out" "old"
out=$("$ROOT/bin/reeve-status" old 2>&1); rc=$?
eq  "2 nor does its own status"                  "$rc" 0
has "2 its process reads unreadable"             "$out" "unreadable"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
