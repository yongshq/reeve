#!/usr/bin/env bash
# The ticket a group of errands shares.
#
# One errand is one holding, one copy, one branch, so a tracker item that spans
# three repositories is three errands. Until now the only thing that said they
# were one piece of work was the naming convention on their ids, which nothing
# in the household reads. `--ticket` records it and reeve-status groups by it,
# so the two properties pinned hardest here are the two the convention could
# never give: a group crosses holdings, and it survives the liege typing the key
# in a different case the second time.
#
# The other half is the record. An absent flag must write NO key, not a key with
# an empty value: reeve-status reads an absent key as unknown and a present
# empty one as a value, and this repository has already had that bug twice (see
# tests/status-labels.test.bash). So every absence below asserts the key is
# missing from the meta file, never that it reads empty.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
eq() { # eq <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}

# --- scratch everything ------------------------------------------------------
# Same refusal as the other brief-writing suites: a run that landed in a real
# reeve home would scribble over live errand records. -P because reeve-brief
# resolves the holding through `git rev-parse --show-toplevel`, which reports the
# real path, and macOS puts the temp directory behind a symlink.
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
mkdir -p "$REEVE_HOME/state"
export REEVE_ROOT="$ROOT"

B="$ROOT/bin/reeve-brief"

# reeve-status calls its siblings by their own directory rather than by PATH, so
# a backend stub has to sit beside a copy of the script. Nothing here is
# dispatched, so no target is ever asked about, but the copy keeps that true by
# construction rather than by hope.
STUB_BIN="$SCRATCH/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/reeve-backend" <<'X'
#!/usr/bin/env bash
case ${2:-} in
  agent_state)     printf 'alive\n' ;;
  attention_state) printf 'working\n' ;;
esac
X
chmod +x "$STUB_BIN/reeve-backend"
cp "$ROOT/bin/reeve-status" "$ROOT/bin/reeve-lib.sh" "$ROOT/bin/reeve-harness" "$STUB_BIN/"
status() { bash "$STUB_BIN/reeve-status" "$@" 2>&1; }

# A holding is a git repository or reeve-brief refuses, so every fixture is one.
# No commit is needed: the toplevel is all reeve-brief reads.
mkrepo() { # mkrepo <name> -> prints its path
  local p="$SCRATCH/$1"
  mkdir -p "$p"
  git init -q "$p"
  printf '%s\n' "$p"
}

meta_line() { # meta_line <id> <key> -> the whole line, or nothing
  grep "^$2=" "$REEVE_HOME/state/$1.meta" 2>/dev/null
}
field() { # field <label> <output> -> the detail view's value for that label
  printf '%s\n' "$2" | sed -n "s/^$1  *//p" | head -1
}

printf '\n--- the record reeve-brief writes ---\n'

api=$(mkrepo api)
"$B" plat-1412-api "$api" --office artificer \
  --ticket PLAT-1412 --ticket-title 'Rate limit the ingest API' \
  --ticket-url 'https://example.invalid/browse/PLAT-1412' >/dev/null 2>&1
eq "the key is stored in the case the liege typed" \
  "ticket=PLAT-1412" "$(meta_line plat-1412-api ticket)"
eq "the title is stored whole, spaces and all" \
  "ticket_title=Rate limit the ingest API" "$(meta_line plat-1412-api ticket_title)"
eq "the url is stored" \
  "ticket_url=https://example.invalid/browse/PLAT-1412" "$(meta_line plat-1412-api ticket_url)"

# The bug class this suite exists to avoid: absent must be absent, so these
# count lines rather than compare values. A `ticket=` present and empty would
# satisfy an emptiness check and put the errand in a group named by nothing.
"$B" loose-one "$api" --office artificer >/dev/null 2>&1
for key in ticket ticket_title ticket_url; do
  eq "no --ticket writes no $key key at all" \
    "0" "$(grep -c "^$key=" "$REEVE_HOME/state/loose-one.meta" | tr -d ' ')"
done

# A title on its own labels nothing, and the reeve who typed only that meant to
# group the errand. Refused, so they find out now rather than at the table.
"$B" orphan-title "$api" --office artificer --ticket-title 'No key' >/dev/null 2>&1
eq "--ticket-title without --ticket is a usage error" "1" "$?"
eq "...and no brief is left behind" \
  "no" "$([ -e "$REEVE_HOME/errands/orphan-title/brief.md" ] && echo yes || echo no)"

"$B" orphan-url "$api" --office artificer --ticket-url 'https://example.invalid/x' >/dev/null 2>&1
eq "--ticket-url without --ticket is a usage error" "1" "$?"

# The key lands in a file whose grammar is one key=value per line, so a value
# that spans lines reads back as a second record.
"$B" spacey "$api" --office artificer --ticket 'PLAT 1412' >/dev/null 2>&1
eq "a key with a space is rejected" "1" "$?"
"$B" tabby "$api" --office artificer --ticket "$(printf 'PLAT\t1412')" >/dev/null 2>&1
eq "a key with a tab is rejected" "1" "$?"
"$B" newliney "$api" --office artificer --ticket "PLAT-1412
office=scout" >/dev/null 2>&1
eq "a key with a newline is rejected" "1" "$?"
eq "...and nothing was written for it" \
  "no" "$([ -e "$REEVE_HOME/state/newliney.meta" ] && echo yes || echo no)"

# Not an id of ours: a foreign tracker's key keeps whatever shape it has.
"$B" odd-key "$api" --office artificer --ticket 'ABC_123/4.5' >/dev/null 2>&1
eq "a key that is not a reeve id is still accepted" \
  "ticket=ABC_123/4.5" "$(meta_line odd-key ticket)"

printf '\n--- the detail view ---\n'

out=$(status plat-1412-api)
eq "key, then title in parens, then url" \
  "PLAT-1412 (Rate limit the ingest API) https://example.invalid/browse/PLAT-1412" \
  "$(field ticket "$out")"
eq "the ticket line sits directly after holding" \
  "1" "$(printf '%s\n' "$out" | grep -A1 '^holding ' | grep -c '^ticket ' | tr -d ' ')"

"$B" key-only "$api" --office artificer --ticket OPS-7 >/dev/null 2>&1
eq "a bare key prints alone, no empty parens" "OPS-7" "$(field ticket "$(status key-only)")"

# An errand briefed before this existed has no ticket key at all, which is every
# record already on disk. It must render exactly as it did.
out=$(status loose-one)
eq "no ticket, no line" "" "$(field ticket "$out")"
eq "...and the rest of the view is untouched" \
  "$api" "$(field holding "$out")"

printf '\n--- the table groups across holdings ---\n'

# The point of the errand: one ticket, three repositories. Different holdings,
# and the third spelling of the key is the liege's second one, in lower case.
web=$(mkrepo web)
lib=$(mkrepo lib)
"$B" plat-1412-web "$web" --office artificer --ticket PLAT-1412 >/dev/null 2>&1
"$B" plat-1412-lib "$lib" --office scribe --ticket plat-1412 >/dev/null 2>&1

out=$(status --all)
eq "one header for the ticket, not one per spelling" \
  "1" "$(printf '%s\n' "$out" | grep -ci '^ticket plat-1412' | tr -d ' ')"
eq "the header names the key and its title" \
  "ticket PLAT-1412: Rate limit the ingest API" \
  "$(printf '%s\n' "$out" | grep '^ticket PLAT' )"

# Grouped means adjacent and in id order, under that one header. Holdings differ
# on every row of it, which is what nothing in the household recorded before.
at=$(printf '%s\n' "$out" | grep -n '^ticket PLAT' | cut -d: -f1)
eq "the ticket's rows follow it, by errand id, whatever repository they are in" \
  "plat-1412-api plat-1412-lib plat-1412-web" \
  "$(printf '%s\n' "$out" | sed -n "$((at+1)),$((at+3))p" | awk '{ printf "%s%s", sep, $1; sep=" " } END { print "" }')"
eq "three different holdings in that one group" "3" \
  "$(for i in plat-1412-api plat-1412-lib plat-1412-web; do
       field holding "$(status $i)"; done | sort -u | grep -c . | tr -d ' ')"

# Tickets in key order, lowercased, so a group's position does not depend on
# how the liege capitalised it. Ungrouped rows after every group.
eq "tickets print key ascending" \
  "ticket ABC_123/4.5 ticket OPS-7 ticket PLAT-1412: Rate limit the ingest API" \
  "$(printf '%s\n' "$out" | grep '^ticket ' | tr '\n' ' ' | sed 's/ *$//')"
first_loose=$(printf '%s\n' "$out" | grep -n '^loose-one ' | cut -d: -f1)
last_group=$(printf '%s\n' "$out" | grep -n '^ticket ' | tail -1 | cut -d: -f1)
eq "an errand with no ticket prints after the groups" \
  "yes" "$([ "${first_loose:-0}" -gt "${last_group:-0}" ] && echo yes || echo no)"
eq "every errand is still in the table" "6" \
  "$(printf '%s\n' "$out" | tail -n +2 | grep -v '^ticket ' | grep -c . | tr -d ' ')"

# The rows themselves are not restyled: a grouped row starts its columns exactly
# where the header's are, same as an ungrouped one always did.
head=$(printf '%s\n' "$out" | head -1)
for col in OFFICE REPORTED PROCESS OPEN; do
  want=$(awk -v c="$col" '{ print index($0, c) }' <<<"$head")
  bad=$(printf '%s\n' "$out" | tail -n +2 | grep -v '^ticket ' | grep . | awk -v at="$want" \
    '{ if (substr($0, at - 1, 1) != " ") print NR }' | head -1)
  eq "$col column aligned in every row, grouped or not" "" "$bad"
done

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
