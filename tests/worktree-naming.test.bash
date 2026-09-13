#!/usr/bin/env bash
# A hand gets two names, and both say which office it is. The local copy is
# composed once, in reeve-brief, and then trusted: dispatch creates that
# directory and teardown removes it, both reading the recorded value back rather
# than recomposing it. The session label is composed once, in reeve-dispatch, and
# handed to a backend, which is the list the liege actually reads to see who is
# working on what. So each name has exactly one place it can go wrong, and both
# are worth pinning.
#
# Two properties matter beyond the names themselves. Both stay FLAT, because an
# <office>/<id> segment would quietly create a directory per role and is not a
# session name a backend accepts. And the steward keeps having no copy at all,
# because dispatch runs it in the reeve's home and a recorded path it never
# creates is a lie in the record.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
eq() { # eq <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}
nk() { # nk <name> <expect-ABSENT-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    FAIL=$((FAIL+1)); printf 'FAIL  %s\n      should NOT contain: %s\n' "$1" "$2"
  else PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; fi
}

# --- scratch everything ------------------------------------------------------
# This suite writes briefs and errand metadata. mktemp should already put it
# nowhere near the liege's own home, but it refuses rather than trusts: a run
# that landed in the real home would scribble over live errand records.
# -P: reeve-brief resolves the holding through `git rev-parse --show-toplevel`,
# which reports the real path. On macOS the temp directory is behind a symlink,
# so an unresolved path here would compare /var against /private/var and fail
# for a reason that has nothing to do with the naming.
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

# What it refuses on is a real reeve home, not the whole of $HOME. GNU mktemp
# honours TMPDIR, so a box with TMPDIR=$HOME/tmp, ordinary on Linux and in CI,
# hands back a scratch path under $HOME that is perfectly safe, and a guard
# spanning all of $HOME would fail the suite for nothing. Two homes can hold
# live records: the one an inherited REEVE_HOME names, and the default
# $HOME/.reeve, which a pre-exported REEVE_HOME does not make safe to scribble
# over. The trap above is already installed, so a refusal here leaves nothing
# behind.
refuse_if_inside() { # refuse_if_inside <home that may hold live records>
  local h=$1 p
  [ -n "$h" ] || return 0
  p=$(cd -P "$h" 2>/dev/null && pwd) && h=$p
  case $REEVE_HOME in
    "$h"|"$h"/*)
      printf 'FAIL  refusing to run: REEVE_HOME %s is inside the real reeve home %s\n' \
        "$REEVE_HOME" "$h"
      exit 1 ;;
  esac
}

# Fail closed: an unresolvable HOME means the default home cannot be ruled out,
# so refuse rather than compare against a path that is not the one at risk.
inherited=${REEVE_HOME:-}
home_p=$(cd -P "${HOME:-/nonexistent}" 2>/dev/null && pwd) \
  || { printf 'FAIL  refusing to run: HOME is unset or unreadable\n'; exit 1; }
REEVE_HOME="$SCRATCH/home"
refuse_if_inside "$inherited"
refuse_if_inside "$home_p/.reeve"
export REEVE_HOME
mkdir -p "$REEVE_HOME"

REPO="$SCRATCH/holding"
mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" -c user.email=reeve@example.invalid -c user.name=reeve \
    -c commit.gpgsign=false commit -q --allow-empty -m init

B="$ROOT/bin/reeve-brief"
PARENT="$SCRATCH/holding.worktrees"
recorded() { grep -m1 '^worktree=' "$REEVE_HOME/state/$1.meta" | sed 's/^worktree=//'; }

for office in artificer warden steward; do
  "$B" "e-$office" "$REPO" --office "$office" >/dev/null \
    || { printf 'FAIL  reeve-brief refused for office %s\n' "$office"; FAIL=$((FAIL+1)); }
done

# --- the name is the office, then the errand ---------------------------------
eq "artificer records artificer-<id>" "$PARENT/artificer-e-artificer" "$(recorded e-artificer)"
eq "warden records warden-<id>"       "$PARENT/warden-e-warden"       "$(recorded e-warden)"

# The brief a hand actually reads must name the same directory, not just the
# record the reeve keeps.
eq "the artificer's brief names its copy" \
   "$PARENT/artificer-e-artificer" \
   "$(sed -n 's/^| your copy | `\(.*\)` |$/\1/p' "$REEVE_HOME/errands/e-artificer/brief.md")"

# --- flat: exactly one directory below .worktrees ----------------------------
for id in e-artificer e-warden; do
  leaf=$(recorded "$id"); leaf=${leaf#*.worktrees/}
  case $leaf in
    */*) FAIL=$((FAIL+1)); printf 'FAIL  %s nests below .worktrees: %s\n' "$id" "$leaf" ;;
    '')  FAIL=$((FAIL+1)); printf 'FAIL  %s records nothing below .worktrees\n' "$id" ;;
    *)   PASS=$((PASS+1)); printf 'ok    %s is flat below .worktrees (%s)\n' "$id" "$leaf" ;;
  esac
done

# --- the steward stays the exception -----------------------------------------
eq "steward records no worktree path" "" "$(recorded e-steward)"
nk "steward's brief mentions no .worktrees directory" ".worktrees" \
   "$(cat "$REEVE_HOME/errands/e-steward/brief.md")"

# --- the session label names the office too -----------------------------------
# `reeve-dispatch --dry-run` prints every command it would run and changes
# nothing, so the line it would hand to create_endpoint carries the label
# verbatim and no session is ever opened here.
#
# Backend and harness are stubbed through a scratch REEVE_ROOT rather than taken
# from the machine running the suite. claude is the one verified harness and a
# claude dispatch preflights folder trust, so a real pair would pass or refuse
# depending on whose box this is. Only backends/ and harnesses/ are stubbed:
# offices/ is the real directory, because dispatch copies an office's settings
# out of it.
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
ln -s "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
ADAPTER
cat > "$STUB/harnesses/stub.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {prompt}"
prompt_mode = "argv"
HARNESS

# Dispatch refuses a brief still holding a seam, rightly, so fill both first.
fill_seams() { # fill_seams <id>
  local b="$REEVE_HOME/errands/$1/brief.md"
  sed -e 's/{INTENT}/the liege said so/' -e 's/{SPEC}/build the thing/' "$b" > "$b.filled" \
    && mv "$b.filled" "$b"
}

dry_label() { # dry_label <id>
  fill_seams "$1"
  REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" "$1" \
      --backend stub --harness stub --dry-run 2>/dev/null \
    | sed -n 's/^ *would run: reeve-backend call create_endpoint [^ ]* \([^ ]*\) --backend .*/\1/p'
}

# The steward is included on purpose: it has no copy, so its label is the only
# name it ever shows up under.
for office in artificer warden steward; do
  label=$(dry_label "e-$office")
  eq "$office opens a session named $office-<id>" "$office-e-$office" "$label"
  case $label in
    */*) FAIL=$((FAIL+1)); printf 'FAIL  %s label is not a flat token: %s\n' "$office" "$label" ;;
    '')  FAIL=$((FAIL+1)); printf 'FAIL  %s dry run printed no label at all\n' "$office" ;;
    *)   PASS=$((PASS+1)); printf 'ok    %s label is a flat token (%s)\n' "$office" "$label" ;;
  esac
done

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
