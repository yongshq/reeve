#!/usr/bin/env bash
# Install reeve for the current user.
#
# Usage: ./install.sh [--home PATH] [--no-skills]
#
# Creates the operational home, initialises it as its own git repository so the
# household's learned memory has history, and generates the skill adapters.
# Skills are scoped to this repo, never installed globally.
#
# Idempotent. Never overwrites memory. Never touches a project repository.

set -uo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/bin/reeve-lib.sh"

home=$REEVE_HOME_D
skills=yes
while [ $# -gt 0 ]; do
  case $1 in
    --home) home=${2:-}; shift 2 ;;
    --no-skills) skills=no; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done
export REEVE_HOME=$home
REEVE_HOME_D=$home

printf 'reeve\n'
printf '  code root %s\n' "$ROOT"
printf '  home      %s\n' "$home"

# --- dependencies ----------------------------------------------------------
missing=''
for t in git; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
[ -n "$missing" ] && die "required tool(s) missing:$missing"
command -v jq >/dev/null 2>&1 || printf '\n  note: jq is not installed. The herdr backend needs it; the tmux backend does not.\n'

# --- the home --------------------------------------------------------------
home_ensure >/dev/null
[ -f "$home/liege.md" ] || cat > "$home/liege.md" <<'EOF'
# The liege

What the household has learned about how the liege works. One fact per line, each with a trailing
tier marker. Written by the steward under the rules in the `memory` skill: nothing lands here
without evidence from the session that produced it.

Deliberately empty to begin with. An absent fact is honest; an invented one is not.
EOF

[ -f "$home/manors.md" ] || cat > "$home/manors.md" <<'EOF'
# Manors

Projects the household knows. One block per manor, one line per repository.

Proposed by `reeve-survey` from evidence, confirmed by the liege, recorded here. A repository that
is not listed is one no hand may be dispatched into.
EOF

for d in errands state config; do mkdir -p "$home/$d"; done
[ -f "$home/config/memory-budget" ] || printf '6000\n' > "$home/config/memory-budget"
[ -f "$home/.gitignore" ] || cat > "$home/.gitignore" <<'EOF'
# Runtime state is machine local and worthless in history: endpoint ids, pane
# targets, sentry cursors. Memory and errand records are the valuable part and
# are tracked.
state/
EOF

if [ ! -d "$home/.git" ]; then
  git -C "$home" init -q -b main
  git -C "$home" add -A
  git -C "$home" -c user.email="$(git config user.email 2>/dev/null || echo reeve@localhost)" \
                 -c user.name="$(git config user.name 2>/dev/null || echo reeve)" \
                 commit -qm "the household begins" 2>/dev/null || :
  printf '  home is now its own git repository, so learned memory has history\n'
fi

# --- adapters --------------------------------------------------------------
"$ROOT/bin/reeve-adapters" >/dev/null && printf '  skill adapters generated\n'

# --- skills are PROJECT scoped, never global -------------------------------
# /court, /errand, /inscribe and the rest mean nothing outside a reeve session.
# They live in this repo's own .claude/skills, so a session started here sees
# them and no other session on the machine does. Installing them globally would
# put reeve vocabulary into every unrelated project you open.
if [ "$skills" = yes ]; then
  n=$(ls "$ROOT/.claude/skills" 2>/dev/null | wc -l | tr -d ' ')
  printf '  %s skill(s) scoped to this repo at .claude/skills\n' "$n"

  # Clean up after older versions of this installer, which did link globally.
  # Only links pointing back into this repo are touched; anything else in
  # ~/.claude/skills belongs to the liege and is left exactly as it is.
  stale=0
  for t in "$HOME/.claude/skills"/*; do
    [ -L "$t" ] || continue
    case "$(readlink "$t")" in
      "$ROOT"/*) rm "$t"; stale=$((stale+1)) ;;
    esac
  done
  [ "$stale" -gt 0 ] && printf '  removed %s reeve skill(s) that an earlier install leaked into ~/.claude/skills\n' "$stale"

  for h in codex opencode cursor grok gemini pi; do
    command -v "$h" >/dev/null 2>&1 && printf '  %s is installed but has no skill adapter yet, see harnesses/README.md\n' "$h"
  done
fi

# --- PATH ------------------------------------------------------------------
case ":$PATH:" in
  *":$ROOT/bin:"*) printf '  bin is on PATH\n' ;;
  *) printf '\n  add this to your shell config so the reeve can reach its own tools:\n'
     printf '    export PATH="%s/bin:$PATH"\n' "$ROOT" ;;
esac

printf '\nnext\n'
printf '  1. %s/bin/reeve-doctor\n' "$ROOT"
printf '  2. reeve-survey <a repo> to introduce a project, then --register the answer\n'
printf '  3. start a reeve session:  cd %s && claude\n' "$ROOT"
