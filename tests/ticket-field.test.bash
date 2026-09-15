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
# The separator moved to the front of each group so the table would stop ending
# on a blank line. This is the half of its job that must survive that: the
# ungrouped block is still not read as more rows of the last ticket.
eq "a blank line still separates the last group from the ungrouped rows" \
  "" "$(printf '%s\n' "$out" | sed -n "$((first_loose-1))p")"
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

printf '\n--- a key the table used to lose ---\n'

# The key reached awk through `awk -v k=$key`, which expands escape sequences in
# the assignment: a key holding a backslash and a `t` became a real tab inside
# awk, `$1 == k` matched nothing, and every errand under that key disappeared
# from the table with no error at all. A foreign tracker's key shape is not ours
# to constrain, so this is reachable input, and the suite above already accepts
# `ABC_123/4.5`. Both the escape awk reads as a character and the one it reads
# as an octal code are pinned.
"$B" bsl-one "$api" --office artificer --ticket 'A\tB' --ticket-title 'Backslash tab' >/dev/null 2>&1
"$B" bsl-two "$web" --office scribe --ticket 'a\tb' >/dev/null 2>&1
"$B" bsl-oct "$api" --office artificer --ticket 'ABC\123' >/dev/null 2>&1

out=$(status --all)
at=$(printf '%s\n' "$out" | grep -n -F 'ticket A\tB' | cut -d: -f1)
eq "two errands sharing a backslash key group together, under its header" \
  "bsl-one bsl-two" \
  "$(printf '%s\n' "$out" | sed -n "$((at+1)),$((at+2))p" | awk '{ printf "%s%s", sep, $1; sep=" " } END { print "" }')"
# Second symptom of the same line: with no ids reaching ticket_label there was no
# spelling to show, so the header fell back to the lowercased key.
eq "the header shows the spelling the liege typed, not the lowercased fallback" \
  "ticket A\tB: Backslash tab" "$(printf '%s\n' "$out" | grep -F 'ticket A\tB')"
at=$(printf '%s\n' "$out" | grep -n -F 'ticket ABC\123' | cut -d: -f1)
eq "a backslash followed by digits groups too" \
  "bsl-oct" "$(printf '%s\n' "$out" | sed -n "$((at+1))p" | awk '{ print $1 }')"

printf '\n--- a carriage return in a label ---\n'

# The newline guard did not cover it. The record survives whole, but a terminal
# draws the tail of the value over the start of the line, so what is displayed
# is not what is stored.
"$B" cr-title "$api" --office artificer --ticket CR-1 \
  --ticket-title "$(printf 'real\rFORGED')" >/dev/null 2>&1
eq "a carriage return in the title is a usage error" "1" "$?"
"$B" cr-url "$api" --office artificer --ticket CR-2 \
  --ticket-url "$(printf 'https://example.invalid/x\rFORGED')" >/dev/null 2>&1
eq "a carriage return in the url is a usage error" "1" "$?"
for i in cr-title cr-url; do
  eq "...and nothing was written for $i" \
    "no" "$([ -e "$REEVE_HOME/state/$i.meta" ] && echo yes || echo no)"
done

printf '\n--- a label of nothing but whitespace ---\n'

# It passed [ -n ] and was stored, which printed the empty parens the "a bare key
# prints alone" assertion above exists to prevent; that one only covers the flag
# being absent. Blank is read as what empty already means for a label: absent.
"$B" ws-1 "$api" --office artificer --ticket WS-1 --ticket-title ' ' --ticket-url '   ' >/dev/null 2>&1
eq "a whitespace-only title leaves the detail line bare, no empty parens" \
  "WS-1" "$(field ticket "$(status ws-1)")"
for key in ticket_title ticket_url; do
  eq "a whitespace-only label writes no $key key at all" \
    "0" "$(grep -c "^$key=" "$REEVE_HOME/state/ws-1.meta" | tr -d ' ')"
done
eq "and the group header is bare too, with no trailing space" \
  "ticket WS-1" "$(status --all | grep '^ticket WS-1')"

printf '\n--- a --ticket that came out blank ---\n'

# The record was right, no key written, but the reeve got no signal that the
# errand is ungrouped. An explicitly empty key is almost always a variable that
# expanded to nothing, which is the same case the title-without-key refusal
# exists for. Fails closed now.
"$B" empty-ticket "$api" --office artificer --ticket '' >/dev/null 2>&1
eq "--ticket '' is a usage error" "1" "$?"
"$B" blank-ticket "$api" --office artificer --ticket '   ' >/dev/null 2>&1
eq "--ticket '   ' is a usage error" "1" "$?"
for i in empty-ticket blank-ticket; do
  eq "...and nothing was written for $i" \
    "no" "$([ -e "$REEVE_HOME/state/$i.meta" ] && echo yes || echo no)"
done
# The flag being absent is untouched by that: it is how every ungrouped errand
# is briefed, and loose-one above was written exactly that way.
eq "no --ticket at all is still fine" \
  "0" "$(grep -c '^ticket=' "$REEVE_HOME/state/loose-one.meta" | tr -d ' ')"

printf '\n--- where the blank line between groups goes ---\n'

# A blank after every group left one at the end of the whole table when nothing
# followed the last one, where main's table ended on a row. It takes its own
# home, because it is the ABSENCE of ungrouped errands that shows it.
ONLY="$SCRATCH/only-tickets"
mkdir -p "$ONLY/state"
REEVE_HOME="$ONLY" "$B" only-a "$api" --office artificer --ticket AAA-1 >/dev/null 2>&1
REEVE_HOME="$ONLY" "$B" only-b "$api" --office artificer --ticket BBB-2 >/dev/null 2>&1
# To a file, not a variable: command substitution strips the exact trailing
# newlines this has to count.
REEVE_HOME="$ONLY" bash "$STUB_BIN/reeve-status" --all >"$SCRATCH/only.out" 2>&1
eq "with nothing ungrouped, the table does not end on a blank line" \
  "no" "$([ -z "$(tail -1 "$SCRATCH/only.out")" ] && echo yes || echo no)"
eq "...and the two groups are still separated by one" \
  "1" "$(grep -c '^$' "$SCRATCH/only.out" | tr -d ' ')"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
