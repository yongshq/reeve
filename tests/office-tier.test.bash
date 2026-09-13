#!/usr/bin/env bash
# The tier an errand goes out on. Three sources, highest first: the flag, the
# office's row in offices/README.md, the harness. The cases here are the ones
# that cost money when they are wrong: a flag that stops winning, an office
# default that never arrives, and a warden quietly made cheap.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REEVE_HOME=$(mktemp -d)
. "$ROOT/bin/reeve-lib.sh"
PASS=0; FAIL=0
eq() { # eq <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}

# --- the declarations themselves -------------------------------------------
eq "scribe is cheap"            "low" "$(office_tier scribe effort)"
eq "steward is cheap"           "low" "$(office_tier steward effort)"
eq "artificer is unset"         ""    "$(office_tier artificer effort)"
eq "scout is unset"             ""    "$(office_tier scout effort)"
# The one office where a cheap default would cost the household a real review.
eq "warden effort never cheap"  ""    "$(office_tier warden effort)"
eq "warden model never cheap"   ""    "$(office_tier warden model)"
eq "no office pins a model"     ""    "$(for o in $(office_names); do office_tier "$o" model; done)"

# Every office has a row, including the ones that declare nothing. A new office
# with no row would silently inherit the harness rather than be a decision.
section=$(mktemp)
sed -n '/^## The default tier/,/^## /p' "$ROOT/offices/README.md" > "$section"
missing=$(for o in $(office_names); do
  grep -q "^|[[:space:]]*${o}[[:space:]]*|" "$section" || printf '%s ' "$o"
done)
rm -f "$section"
eq "every office has a row"     ""    "$(printf '%s' "$missing" | sed 's/ *$//')"

# An office name that appears in another table in the same file is not a
# declaration: the reader is scoped to the one section.
eq "unknown office reads unset" ""    "$(office_tier nosuchoffice effort)"

# --- precedence -------------------------------------------------------------
eq "flag beats office"      "high|flag"   "$(tier_resolve scribe effort high)"
eq "office beats nothing"   "low|office"  "$(tier_resolve scribe effort '')"
eq "harness when unset"     "|harness"    "$(tier_resolve artificer effort '')"
eq "flag on an unset office" "opus|flag"  "$(tier_resolve artificer model opus)"

# The two axes resolve alone: the scribe defaults effort and pins no model, so
# one comes from the office and the other from the harness in the same dispatch.
eq "effort from the office"  "low|office" "$(tier_resolve scribe effort '')"
eq "model from the harness"  "|harness"   "$(tier_resolve scribe model '')"
# and a flag on one axis does not drag the other with it
eq "model flag, effort still office" "low|office" "$(tier_resolve scribe effort '')"

# --- an office with no default behaves exactly as today ---------------------
for axis in model effort; do
  eq "artificer $axis unchanged" "|harness" "$(tier_resolve artificer "$axis" '')"
done

# --- what a reeve is told ---------------------------------------------------
eq "phrase names the origin"  "low (office)"    "$(tier_say low office)"
eq "phrase for a flag"        "sonnet (flag)"   "$(tier_say sonnet flag)"
eq "phrase claims no value it does not know" "harness default" "$(tier_say '' harness)"
eq "phrase carries the drop"  "low (office, dropped: codex has no effort_flag)" \
   "$(tier_say low office 'dropped: codex has no effort_flag')"

# --- a garbage cell is a refusal, not a command line ------------------------
fake=$(mktemp -d); mkdir -p "$fake/offices"
{ printf '# Offices\n\n## The default tier\n\n| Office | Model | Effort | Why |\n|---|---|---|---|\n'
  printf '| scribe | opus; rm -rf / | (none) | a documentation error |\n'; } > "$fake/offices/README.md"
out=$(REEVE_ROOT="$fake" bash -c '. "$0/bin/reeve-lib.sh"; office_tier scribe model' "$ROOT" 2>&1 || true)
if printf '%s' "$out" | grep -q 'unusable default model'; then PASS=$((PASS+1)); printf 'ok    unusable cell refused\n'
else FAIL=$((FAIL+1)); printf 'FAIL  unusable cell refused\n      got: %s\n' "$out"; fi
rm -rf "$fake"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
