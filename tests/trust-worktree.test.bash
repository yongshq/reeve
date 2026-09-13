#!/usr/bin/env bash
# reeve-trust resolves a target to the repository it must check trust against.
# A linked worktree's own --show-toplevel names the worktree, not the
# repository: claude keys the trust dialog to the main working tree, whose
# .git is a real directory, so a worktree checked the old way came back NOT
# TRUSTED while claude itself started fine in it. This pins the fix: a
# worktree of a trusted repository must report trusted, and a worktree of one
# that was never granted trust must still refuse. CLAUDE_CONFIG points every
# check at a scratch file instead of the liege's real ~/.claude.json, so
# nothing here grants or reads real trust.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ck() { # ck <name> <want-rc> <got-rc>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want rc: %s\n      got rc:  %s\n' "$1" "$2" "$3"; fi
}

SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

mkrepo() { # mkrepo <path>
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" -c user.email=reeve@example.invalid -c user.name=reeve \
      -c commit.gpgsign=false commit -q --allow-empty -m init
}

TRUSTED_REPO="$SCRATCH/trusted-holding"
mkrepo "$TRUSTED_REPO"
git -C "$TRUSTED_REPO" worktree add -q "$SCRATCH/trusted-holding.worktree" -b scratch main

UNTRUSTED_REPO="$SCRATCH/untrusted-holding"
mkrepo "$UNTRUSTED_REPO"
git -C "$UNTRUSTED_REPO" worktree add -q "$SCRATCH/untrusted-holding.worktree" -b scratch main

# A scratch config, standing in for ~/.claude.json, that records trust for the
# repository path only, the way claude itself writes it: never for a worktree.
CFG="$SCRATCH/claude.json"
cat > "$CFG" <<JSON
{"projects": {"$TRUSTED_REPO": {"hasTrustDialogAccepted": true}}}
JSON

TRUST="$ROOT/bin/reeve-trust"

CLAUDE_CONFIG="$CFG" "$TRUST" --check "$TRUSTED_REPO" >/dev/null 2>&1
ck "a trusted repository checks trusted" 0 "$?"

CLAUDE_CONFIG="$CFG" "$TRUST" --check "$SCRATCH/trusted-holding.worktree" >/dev/null 2>&1
ck "a worktree of a trusted repository checks trusted too" 0 "$?"

CLAUDE_CONFIG="$CFG" "$TRUST" --check "$UNTRUSTED_REPO" >/dev/null 2>&1
ck "a repository never granted trust still refuses" 1 "$?"

CLAUDE_CONFIG="$CFG" "$TRUST" --check "$SCRATCH/untrusted-holding.worktree" >/dev/null 2>&1
ck "a worktree of an ungranted repository still refuses" 1 "$?"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
