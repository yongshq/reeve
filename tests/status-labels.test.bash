#!/usr/bin/env bash
# Two display defects in reeve-status, both about the difference between a key
# that is absent and one that is present and empty.
#
# PROCESS read `never-dispatched` for any errand with an empty `target=`, which
# is every errand whose session has been freed: 46 of the 49 on the day this was
# written, so the column said the fleet had never gone out.
#
# The office line read `artificer on  via ?` because reeve-brief writes
# `harness=` present and empty before dispatch fills it, and meta_get's fallback
# only covers an absent key. meta_get itself is left alone: other callers need
# that distinction, so the guard belongs at the point of printing.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/bin/reeve-status"
PASS=0; FAIL=0
ck() { # ck <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}

SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/reeve-home-test"
mkdir -p "$REEVE_HOME/state"

# A backend stub, so a live target answers without a terminal anywhere near it.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/reeve-backend" <<'X'
#!/usr/bin/env bash
case ${2:-} in
  agent_state)     printf 'alive\n' ;;
  attention_state) printf 'working\n' ;;
esac
X
chmod +x "$SCRATCH/bin/reeve-backend"

seed() { # seed <id> [key=value ...]
  local id=$1; shift
  mkdir -p "$REEVE_HOME/errands/$id"
  printf 'working: started\n' > "$REEVE_HOME/errands/$id/status"
  : > "$REEVE_HOME/state/$id.meta"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$REEVE_HOME/state/$id.meta"; done
}

# reeve-status calls its siblings by their own directory rather than by PATH, so
# the stub has to sit beside a copy of the script. REEVE_ROOT keeps the copy
# reading the real harness declarations.
STUB_BIN="$SCRATCH/bin"
cp "$BIN" "$ROOT/bin/reeve-lib.sh" "$ROOT/bin/reeve-harness" "$STUB_BIN/"
export REEVE_ROOT="$ROOT"
run() { bash "$STUB_BIN/reeve-status" "$@" 2>&1; }

field() { # field <label> <output>
  printf '%s\n' "$2" | sed -n "s/^$1  *//p" | head -1
}

printf '\n--- PROCESS, one case per state ---\n'

seed never office=artificer repo=/nowhere
ck "no dispatched key stays never-dispatched" \
  "never-dispatched" "$(field process "$(run never)")"

seed gone office=artificer repo=/nowhere \
  dispatched=2026-09-13T03:24:37 target=
ck "dispatched with an emptied target is session-gone" \
  "session-gone" "$(field process "$(run gone)")"

seed cleared office=artificer repo=/nowhere \
  dispatched=2026-09-13T03:24:37 tornDown=2026-09-14T18:31:10 target=
ck "a torn down errand says so, not never-dispatched" \
  "torn-down" "$(field process "$(run cleared)")"

seed live office=artificer repo=/nowhere backend=herdr harness=claude \
  dispatched=2026-09-14T09:00:00 target=%7
ck "a live target is still asked of the backend" \
  "alive/working" "$(field process "$(run live)")"

# tornDown without a dispatch is a record that cannot happen, but the reading is
# ordered so the dispatch question is answered first and it cannot mislead.
seed odd office=artificer repo=/nowhere tornDown=2026-09-14T18:31:10
ck "tornDown alone does not imply a dispatch" \
  "never-dispatched" "$(field process "$(run odd)")"

printf '\n--- the tool name cell ---\n'

seed blank office=scribe repo=/nowhere harness=
out=$(run blank)
ck "harness present and empty prints the unknown mark" \
  "scribe on ? via ?" "$(field office "$out")"

seed absent office=scribe repo=/nowhere
ck "harness absent prints the same mark" \
  "scribe on ? via ?" "$(field office "$(run absent)")"

seed filled office=scribe repo=/nowhere harness=claude backend=herdr
ck "a real harness is untouched" \
  "scribe on claude via herdr" "$(field office "$(run filled)")"

seed empties office= repo= harness= backend=
out=$(run empties)
ck "an empty office and holding print marks too" \
  "? on ? via ?" "$(field office "$out")"
ck "holding falls back the same way" "?" "$(field holding "$out")"

printf '\n--- the table still lines up ---\n'

out=$(run --all)
head=$(printf '%s\n' "$out" | head -1)
# Every row's columns start where the header's do. A label longer than its
# column would push PROCESS and OPEN right on that row alone.
for col in OFFICE REPORTED PROCESS OPEN; do
  want=$(awk -v c="$col" '{ print index($0, c) }' <<<"$head")
  bad=$(printf '%s\n' "$out" | tail -n +2 | awk -v at="$want" \
    '{ if (substr($0, at - 1, 1) != " ") print NR }' | head -1)
  ck "$col column aligned in every row" "" "$bad"
done
rows=$(printf '%s\n' "$out" | tail -n +2 | grep -c . | tr -d ' ')
ck "every seeded errand is in the table" "9" "$rows"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
