#!/usr/bin/env bash
# A root the liege trusted, in config/trusted-roots, lets dispatch grant claude
# folder trust itself for a repository under it, instead of refusing NOT
# TRUSTED and waiting for the liege to run reeve-trust --grant. Outside every
# root nothing changes: the refusal is the same text, and no file means no
# roots. "Under" is a whole path component on the real path, so a sibling that
# merely shares a prefix, or a symlink inside the root pointing out of it, is
# not under it. A dry run grants nothing.
#
# CLAUDE_CONFIG points every check and grant at a scratch file, and REEVE_HOME
# at a scratch home, so nothing here reads or writes the liege's real trust.
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
unset CLAUDE_CODE_SESSION_ID REEVE_SESSION REEVE_NAME REEVE_HAND REEVE_BACKEND REEVE_ROOT \
      HALL_ENV HALL_PANE_ID HALL_SOCKET_PATH HALL_TAB_ID HALL_WORKSPACE_ID HERDR_ENV HERDR_PANE_ID
mkdir -p "$REEVE_HOME/config"
ROOTS="$REEVE_HOME/config/trusted-roots"
printf '{"projects": {}}\n' > "$CLAUDE_CONFIG"

mkrepo() { # mkrepo <path>
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" -c user.email=reeve@example.invalid -c user.name=reeve \
      -c commit.gpgsign=false commit -q --allow-empty -m init
}
trusted() { # trusted <repo> -> the config's hasTrustDialogAccepted for it
  python3 - "$CLAUDE_CONFIG" "$1" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get('projects',{}).get(sys.argv[2],{}).get('hasTrustDialogAccepted'))
PY
}

TRUST="$ROOT/bin/reeve-trust"
mkrepo "$SCRATCH/yong/a"
mkrepo "$SCRATCH/yong/deep/b"
mkrepo "$SCRATCH/yong2/c"
mkrepo "$SCRATCH/outside/d"
ln -s "$SCRATCH/outside/d" "$SCRATCH/yong/link"
git -C "$SCRATCH/yong/a" worktree add -q "$SCRATCH/elsewhere/a.wt" -b side main

echo "--- 1. reeve-trust --root-for ---"
"$TRUST" --root-for "$SCRATCH/yong/a" >/dev/null 2>&1
eq  "1 no file, no roots"                                   "$?" 1
eq  "1 and --roots lists nothing"                           "$("$TRUST" --roots)" ""

cat > "$ROOTS" <<EOF
# the liege's own code

   $SCRATCH/yong/../yong
relative/path
/no/such/root
EOF
roots_out=$("$TRUST" --roots)
has "1 comments, blanks and dot-dot lines resolve to the real root"  "$roots_out" "$SCRATCH/yong"
has "1 a relative line is named as skipped, with its reason"          "$roots_out" "skipped relative/path (not an absolute path)"
has "1 a missing path is named as skipped, with its reason"           "$roots_out" "skipped /no/such/root (not a directory)"
eq  "1 a repository directly under the root"                "$("$TRUST" --root-for "$SCRATCH/yong/a")" "$SCRATCH/yong"
eq  "1 one further down"                                    "$("$TRUST" --root-for "$SCRATCH/yong/deep/b")" "$SCRATCH/yong"
eq  "1 a worktree elsewhere resolves to its repository"     "$("$TRUST" --root-for "$SCRATCH/elsewhere/a.wt")" "$SCRATCH/yong"
"$TRUST" --root-for "$SCRATCH/yong2/c" >/dev/null 2>&1
eq  "1 a sibling sharing the prefix is not under it"        "$?" 1
"$TRUST" --root-for "$SCRATCH/yong/link" >/dev/null 2>&1
eq  "1 a symlink inside the root pointing out is not under it" "$?" 1
"$TRUST" --root-for "$SCRATCH/outside/d" >/dev/null 2>&1
eq  "1 a repository outside every root"                     "$?" 1
ln -s "$SCRATCH/yong" "$SCRATCH/alias"
printf '%s\n' "$SCRATCH/alias" > "$ROOTS"
eq  "1 a root named through a symlink resolves to its real path" "$("$TRUST" --root-for "$SCRATCH/yong/a")" "$SCRATCH/yong"
printf '%s # mine\n' "$SCRATCH/yong" > "$ROOTS"
has "1 an inline comment is named as skipped"                 "$("$TRUST" --roots)" "(inline comment"
"$TRUST" --root-for "$SCRATCH/yong/a" >/dev/null 2>&1
eq  "1 and grants nothing"                                    "$?" 1
mkdir -p "$SCRATCH/Case/Sub"; mkrepo "$SCRATCH/Case/Sub/r"
lower=$(printf '%s' "$SCRATCH/Case" | tr '[:upper:]' '[:lower:]')
if [ -d "$lower" ] && [ "$(cd -P "$lower" && pwd -P)" != "" ] && [ -e "$lower/Sub" ] && [ "$lower" != "$SCRATCH/Case" ]; then
  printf '%s\n' "$lower" > "$ROOTS"
  eq  "1 a root typed in the wrong case matches on a case-insensitive disk" "$("$TRUST" --root-for "$SCRATCH/Case/Sub/r")" "$SCRATCH/Case"
else
  ok  "1 (case-sensitive disk: wrong-case root test not applicable)"
fi
printf '/\n' > "$ROOTS"
has "1 a root of / is named as too broad"                     "$("$TRUST" --roots)" "skipped / (too broad"
"$TRUST" --root-for "$SCRATCH/yong/a" >/dev/null 2>&1
eq  "1 and never matches"                                     "$?" 1
printf '%s\n%s\n' "$SCRATCH/yong" "$SCRATCH" > "$ROOTS"
eq  "1 the home directory and its parent are both too broad"  "$(HOME="$SCRATCH/yong" "$TRUST" --roots | grep -c 'too broad')" 2
HOME="$SCRATCH/yong" "$TRUST" --root-for "$SCRATCH/yong/a" >/dev/null 2>&1
eq  "1 and never match"                                       "$?" 1
printf '%s\n' "$SCRATCH/alias" > "$ROOTS"
eq  "1 --check is unchanged: still not trusted"             "$("$TRUST" --check "$SCRATCH/yong/a" >/dev/null 2>&1; echo $?)" 1

# --- dispatch, with a stub backend and a claude harness that runs nothing ----
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_launch()          { return 0; }
ADAPTER
cat > "$STUB/harnesses/claude.toml" <<'HARNESS'
name = "claude"
bin = "true"
verified = true
launch = "{bin} {settings} {prompt}"
settings_flag = "--settings {settings}"
prompt_mode = "argv"
HARNESS

n=0
go() { # go <repo> [args...] -> OUT/ERR/RC, a fresh errand each time
  local repo=$1; shift; n=$((n+1))
  "$ROOT/bin/reeve-brief" "e$n" "$repo" --office mason >/dev/null 2>&1 || { OUT=''; ERR='brief refused'; RC=99; return; }
  local b="$REEVE_HOME/errands/e$n/brief.md"
  sed -e 's/{INTENT}/the liege said so/' -e 's/{SPEC}/build it/' "$b" > "$b.f" && mv "$b.f" "$b"
  OUT=$(REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" "e$n" --backend stub --harness claude "$@" 2>"$SCRATCH/err"); RC=$?
  ERR=$(cat "$SCRATCH/err")
}
backups() { find "$SCRATCH" -maxdepth 1 -name 'claude.json.reeve-backup.*' | wc -l | tr -d ' '; }

echo "--- 2. no roots file: the refusal is unchanged ---"
rm -f "$ROOTS"
go "$SCRATCH/yong/a"
eq  "2 dispatch refuses"                                    "$RC" 1
has "2 with the same refusal"                               "$ERR" "refusing to dispatch into $SCRATCH/yong/a"
has "2 naming NOT TRUSTED"                                  "$ERR" "NOT TRUSTED: $SCRATCH/yong/a"
nas "2 and no grant"                                        "$ERR$OUT" "trust granted"
eq  "2 the config is untouched"                             "$(trusted "$SCRATCH/yong/a")" None

echo "--- 3. a dry run under a root grants nothing ---"
printf '# roots\n\n%s\n' "$SCRATCH/yong" > "$ROOTS"
cfg_before=$(cksum < "$CLAUDE_CONFIG")
go "$SCRATCH/yong/a" --dry-run
eq  "3 the dry run succeeds"                                "$RC" 0
has "3 it says it would grant trust"                        "$OUT" "would grant trust: $SCRATCH/yong/a, under trusted root $SCRATCH/yong"
eq  "3 the config is byte for byte the same"                "$(cksum < "$CLAUDE_CONFIG")" "$cfg_before"
eq  "3 and no backup was made"                              "$(backups)" 0

echo "--- 4. under a root, dispatch grants and goes on ---"
go "$SCRATCH/yong/a"
eq  "4 dispatch succeeds"                                   "$RC" 0
has "4 saying trust was granted under which root"           "$OUT" "trust granted: $SCRATCH/yong/a, under trusted root $SCRATCH/yong"
eq  "4 in one line"                                         "$(printf '%s\n' "$OUT" "$ERR" | grep -c 'trust granted')" 1
eq  "4 the repository is now trusted"                       "$(trusted "$SCRATCH/yong/a")" True
eq  "4 after a backup, as reeve-trust --grant always makes"  "$(backups)" 1
has "4 which the line names"                                "$OUT" "backup $SCRATCH/claude.json.reeve-backup."
go "$SCRATCH/yong/a"
eq  "4 a second dispatch finds it trusted"                  "$RC" 0
nas "4 and grants nothing again"                            "$OUT" "trust granted"

echo "--- 5. a sibling sharing the prefix is not granted ---"
go "$SCRATCH/yong2/c"
eq  "5 dispatch refuses"                                    "$RC" 1
has "5 with the unchanged refusal"                          "$ERR" "NOT TRUSTED: $SCRATCH/yong2/c"
eq  "5 the config is untouched for it"                      "$(trusted "$SCRATCH/yong2/c")" None

echo "--- 6. comments only: no roots ---"
printf '# %s\n\n' "$SCRATCH/yong" > "$ROOTS"
go "$SCRATCH/yong/deep/b"
eq  "6 a commented root grants nothing"                     "$RC" 1
eq  "6 the config is untouched for it"                      "$(trusted "$SCRATCH/yong/deep/b")" None

echo "--- 7. a grant that fails is not reported as one ---"
printf '%s\n' "$SCRATCH/yong" > "$ROOTS"
good_cfg=$(cat "$CLAUDE_CONFIG")
printf '{"projects": {' > "$CLAUDE_CONFIG"
cfg_before=$(cksum < "$CLAUDE_CONFIG")
go "$SCRATCH/yong/deep/b"
eq  "7 dispatch refuses"                                    "$RC" 1
nas "7 and never says trust was granted"                    "$ERR$OUT" "trust granted"
has "7 naming the failed grant"                             "$ERR" "granting trust under $SCRATCH/yong failed"
eq  "7 the config is left as it was"                        "$(cksum < "$CLAUDE_CONFIG")" "$cfg_before"
"$TRUST" --grant "$SCRATCH/yong/deep/b" >/dev/null 2>&1
eq  "7 reeve-trust --grant itself exits non-zero"           "$?" 1
out=$("$TRUST" --grant "$SCRATCH/yong/deep/b" 2>&1)
has "7 saying where the backup is"                          "$out" "grant failed;"
nas "7 and not claiming it granted"                         "$out" "granted."
printf '%s\n' "$good_cfg" > "$CLAUDE_CONFIG"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
