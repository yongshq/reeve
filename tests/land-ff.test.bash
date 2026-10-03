#!/usr/bin/env bash
# The fast-forward a standing landing rule allows onto a primary checkout that
# sits on `main` (AGENTS.md, hard rule 2). No script runs it, the reeve does, so
# what is pinned here is the command the contract names and what git does with
# it: the promise is "no incoming file lands on a file you have there", and it
# is git's refusal that keeps it, not a reading of `git status`.
#
# Two cases a status check misses and git must still refuse: an ignored file at
# an incoming path under `status.showUntrackedFiles no`, where status prints
# nothing at all, and an ignored directory replaced by an incoming file of the
# same name, where the status entry and the incoming path differ by a slash.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
eq() { # eq <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}

SCRATCH=$(mktemp -d) || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

# A user's own git config must not decide the outcome either way.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

FORM='git -C <holding> merge --ff-only --no-overwrite-ignore <branch>'
if grep -qF -- "$FORM" "$ROOT/AGENTS.md"; then got=named; else got=missing; fi
eq "AGENTS.md names the land form this suite exercises" named "$got"

# A holding on `main` whose branch `feat` adds what the first argument says.
fixture() { # fixture <name> <command run on feat before its commit> -> prints the repo
  local r="$SCRATCH/$1"
  git init -q -b main "$r"
  printf 'a\n' > "$r/README"
  printf 'local.env\nbuild/\n' > "$r/.gitignore"
  git -C "$r" add . && git -C "$r" commit -qm init
  git -C "$r" checkout -qb feat
  (cd "$r" && eval "$2")
  git -C "$r" commit -qm feat
  git -C "$r" checkout -q main
  printf '%s\n' "$r"
}
land() { git -C "$1" merge -q --ff-only --no-overwrite-ignore feat >/dev/null 2>&1; echo $?; }

# --- clean apart from an untracked file elsewhere: lands ---------------------
r=$(fixture clean 'mkdir src && echo c > src/b.c && git add src')
echo mine > "$r/notes.txt"
eq "clean tree with an unrelated untracked file lands" 0 "$(land "$r")"
eq "  and brings the incoming file" c "$(cat "$r/src/b.c" 2>/dev/null)"
eq "  and keeps the untracked one" mine "$(cat "$r/notes.txt")"

# --- ignored file at an incoming path, status silenced: refuses --------------
r=$(fixture silenced 'echo INCOMING > local.env && git add -f local.env')
echo SECRET > "$r/local.env"
git -C "$r" config status.showUntrackedFiles no
eq "silenced status really prints nothing" "" "$(git -C "$r" status --porcelain)"
before=$(git -C "$r" rev-parse main)
eq "ignored file at an incoming path refuses" 1 "$(land "$r")"
eq "  and the ignored file is intact" SECRET "$(cat "$r/local.env")"
eq "  and main did not move" "$before" "$(git -C "$r" rev-parse main)"

# --- ignored directory where an incoming file goes: refuses ------------------
r=$(fixture dir 'echo F > build && git add -f build')
mkdir -p "$r/build" && echo X > "$r/build/out.bin"
eq "ignored directory replaced by an incoming file refuses" 1 "$(land "$r")"
eq "  and its contents are intact" X "$(cat "$r/build/out.bin" 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
