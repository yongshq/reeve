#!/usr/bin/env bash
# The fresh-clone run a brief asks for. Hard rule 2 in AGENTS.md makes it part
# of "branch ready" for the household's own repository and for any holding whose
# manor line says `fresh-clone: yes`, so reeve-brief has to write it into every
# such brief, and hard rule 1 of every brief with a copy has to leave room for
# the throwaway clone it needs. A brief that demands the run and forbids the
# clone is a hand that can only break one rule or the other.
#
# Pinned here: which briefs carry the section, that the registry flag reaches
# manors.md and from there the brief, and which hard rule 1 has the carve-out.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
has()  { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1"; fi; }
lacks() { if grep -qF -- "$3" "$2"; then bad "$1"; else ok "$1"; fi; }

# --- scratch everything ------------------------------------------------------
# Same refusal as the other brief-writing suites: a run that landed in a real
# reeve home would scribble over live errand records.
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

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

inherited=${REEVE_HOME:-}
home_p=$(cd -P "${HOME:-/nonexistent}" 2>/dev/null && pwd) \
  || { printf 'FAIL  refusing to run: HOME is unset or unreadable\n'; exit 1; }
REEVE_HOME="$SCRATCH/home"
refuse_if_inside "$inherited"
refuse_if_inside "$home_p/.reeve"
export REEVE_HOME
mkdir -p "$REEVE_HOME"

B="$ROOT/bin/reeve-brief"
SECTION='## Fresh-clone run'
CARVE='save a throwaway clone under a temporary directory when this brief'

mkrepo() { # mkrepo <name> -> prints its path
  local p="$SCRATCH/$1"
  mkdir -p "$p"
  git init -q "$p"
  printf '%s\n' "$p"
}

brief_for() { # brief_for <id> <holding> <office> -> prints the brief's path
  "$B" "$1" "$2" --office "$3" >/dev/null 2>&1 \
    || { bad "reeve-brief refused for $1"; return 1; }
  printf '%s\n' "$REEVE_HOME/errands/$1/brief.md"
}

# --- an ordinary holding: no run, but room for one ---------------------------
r=$(mkrepo plain)
f=$(brief_for e-plain "$r" artificer)
lacks "ordinary holding: no fresh-clone section" "$f" "$SECTION"
has   "ordinary holding: hard rule 1 still leaves room for a spec that asks" "$f" "$CARVE"

f=$(brief_for e-plain-scout "$r" scout)
has   "reader office: carve-out too, a warden's spec may ask for the run" "$f" "$CARVE"
lacks "reader office: no section, it has no branch to clone" "$f" "$SECTION"

f=$(brief_for e-plain-steward "$r" steward)
lacks "steward: no copy, so no carve-out" "$f" "$CARVE"

# --- opted in through the registry ---------------------------------------------
r=$(mkrepo harbor)
"$ROOT/bin/reeve-survey" --register harbor --manor scratch --path "$r" \
  --test 'make check' --fresh-clone >/dev/null 2>&1 \
  || bad "reeve-survey --register --fresh-clone refused"
has "--fresh-clone lands on the manor line" "$REEVE_HOME/manors.md" \
  "| test: make check | fresh-clone: yes"
f=$(brief_for e-harbor harbor artificer)
has "opted-in holding: section present" "$f" "$SECTION"
has "opted-in holding: the run uses the holding's test command" "$f" \
  'REEVE_HOME="$tmp/home" make check'
has "opted-in holding: the run clones this errand's branch" "$f" \
  "git clone -q --branch feat/e-harbor"
has "opted-in holding: hard rule 1 permits the clone" "$f" "$CARVE"

r=$(mkrepo lantern)
"$ROOT/bin/reeve-survey" --register lantern --manor scratch --path "$r" >/dev/null 2>&1 \
  || bad "reeve-survey --register refused"
if grep 'holding: lantern ' "$REEVE_HOME/manors.md" | grep -qF 'fresh-clone'; then
  bad "no flag, no field on the manor line"
else ok "no flag, no field on the manor line"; fi
f=$(brief_for e-lantern lantern artificer)
lacks "registered without the flag: no section" "$f" "$SECTION"

# --- the household's own repository: always, no flag -------------------------
# Known by its plugin manifest's name, not by sharing an object store with the
# code root, so a plugin install running from a separate clone or a cache still
# recognises it.
f=$(brief_for e-own "$ROOT" scribe)
has "own repository: section present with no registry entry" "$f" "$SECTION"
has "own repository: scribe gets it too, not only the artificer" "$f" \
  "git clone -q --branch docs/e-own"
has "own repository: no test command known, the spec names it" "$f" \
  '<the test command your spec names>'

# A separate clone of the household's repository, nothing shared with the code
# root but the manifest.
r=$(mkrepo own-clone)
mkdir -p "$r/.claude-plugin"
cp "$ROOT/.claude-plugin/plugin.json" "$r/.claude-plugin/plugin.json"
f=$(brief_for e-own-clone "$r" artificer)
has "separate clone of the own repository: section present" "$f" "$SECTION"

# A repository with some other plugin's manifest is not the household's.
r=$(mkrepo other-plugin)
mkdir -p "$r/.claude-plugin"
printf '{\n  "name": "not-reeve",\n  "author": { "name": "reeve" }\n}\n' \
  > "$r/.claude-plugin/plugin.json"
f=$(brief_for e-other "$r" artificer)
lacks "unrelated plugin repository: no section" "$f" "$SECTION"

# --- the office's own write rule, reconciled once ----------------------------
# "What you may write" is fixed office text: "Nothing outside it" for the
# artificer, "Exactly one file" for a reader. A brief that asks for the run
# says, right after it, that the throwaway clone is allowed; one that does not
# ask leaves the office text alone.
PLUS='Plus a throwaway clone under a temporary directory when this brief asks for a'
for o in artificer scribe scout warden; do
  f=$(brief_for "e-plus-$o" "$ROOT" "$o")
  has "own repository, $o: write rule names the clone" "$f" "$PLUS"
  if awk -v p="$PLUS" '/^### What you may write/ { w = 1; next }
       w && /^### / { exit }  w && index($0, p) { found = 1 }
       END { exit !found }' "$f"; then
    ok "own repository, $o: the clone sentence sits inside What you may write"
  else bad "own repository, $o: the clone sentence sits inside What you may write"; fi
done
f=$(brief_for e-plus-steward "$ROOT" steward)
lacks "own repository, steward: no copy, no clone sentence" "$f" "$PLUS"

r=$(mkrepo unchanged)
f=$(brief_for e-unchanged "$r" artificer)
lacks "ordinary holding: office write rule unchanged" "$f" "$PLUS"
want=$(sed 's/^#/##/' "$ROOT/offices/artificer.md")
got=$(sed -n '/^### What you may write/,/^### Your rules/p' "$f")
exp=$(printf '%s\n' "$want" | sed -n '/^### What you may write/,/^### Your rules/p')
if [ "$got" = "$exp" ]; then ok "ordinary holding: What you may write is the office text verbatim"
else bad "ordinary holding: What you may write is the office text verbatim"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
