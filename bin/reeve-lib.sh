#!/usr/bin/env bash
# Shared library for every reeve script. Sourced, never executed.
#
# Single owner of: path resolution, errand id validation, errand metadata,
# status-file reconciliation, and locking. Nothing else may reimplement these.
#
# Deliberately bash 3.2 compatible: macOS ships bash 3.2 and a fresh machine may
# have no newer bash on PATH. No associative arrays, no ${var,,}, no mapfile.

set -uo pipefail

# Pin collation for pattern matching. Under many UTF-8 locales (en_PH.UTF-8 is
# one) a glob `[a-z]` also matches UPPERCASE letters, because the collation order
# interleaves case. Without this, an id like "Bad_ID" passes validation and
# becomes a real branch name and a real directory. LC_COLLATE only, not LC_ALL,
# so UTF-8 output is unaffected.
LC_COLLATE=C
export LC_COLLATE

# --- paths ------------------------------------------------------------------
# REEVE_ROOT is this repo (code). REEVE_HOME is the operational home (state).
# Separating them is what lets one checkout serve several homes.

reeve_root() {
  if [ -n "${REEVE_ROOT:-}" ]; then printf '%s\n' "$REEVE_ROOT"; return; fi
  # resolve from this file's location, following symlinks
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "$src" ]; do
    dir=$(cd -P "$(dirname "$src")" && pwd)
    src=$(readlink "$src")
    case $src in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd -P "$(dirname "$src")/.." && pwd
}

reeve_home() { printf '%s\n' "${REEVE_HOME:-$HOME/.reeve}"; }

REEVE_ROOT_D=$(reeve_root)
REEVE_HOME_D=$(reeve_home)

errand_dir()  { printf '%s/errands/%s\n' "$REEVE_HOME_D" "$1"; }
brief_file()  { printf '%s/errands/%s/brief.md\n' "$REEVE_HOME_D" "$1"; }
report_file() { printf '%s/errands/%s/report.md\n' "$REEVE_HOME_D" "$1"; }
# The status file lives in the errand directory, NOT in state/, and that is a
# deliberate security boundary rather than tidiness. A hand runs with tool
# access to its working copy plus exactly one extra directory. Keeping the
# brief it reads, the status it appends to, and the report it writes all inside
# that one directory means the grant is a single path, and the reeve's own
# records in state/ stay outside everything a hand can reach.
status_file() { printf '%s/errands/%s/status\n' "$REEVE_HOME_D" "$1"; }
meta_file()   { printf '%s/state/%s.meta\n' "$REEVE_HOME_D" "$1"; }
config_file() { printf '%s/config/%s\n' "$REEVE_HOME_D" "$1"; }

# --- output -----------------------------------------------------------------
# Everything a script prints is read by the reeve, so keep it one fact per line.

die()  { printf 'reeve: %s\n' "$*" >&2; exit 1; }
warn() { printf 'reeve: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

# --- list matching ---------------------------------------------------------
# Never use `... | grep -q` under `set -o pipefail`. grep -q exits on the first
# match and closes the pipe, the upstream writer gets EPIPE, and pipefail then
# reports the whole pipeline as failed. The practical symptom is that matching
# the FIRST item of a list fails while the LAST one succeeds. Use these instead.

lines_has() {
  # lines_has <needle> <newline-separated-haystack>
  local needle=$1 hay=${2:-} line
  [ -n "$hay" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done <<LINES_HAS_EOF
$hay
LINES_HAS_EOF
  return 1
}

words_has() {
  # words_has <needle> <space-separated-haystack>
  local needle=$1 w
  for w in ${2:-}; do [ "$w" = "$needle" ] && return 0; done
  return 1
}

# --- errand ids -------------------------------------------------------------
# An errand id is also a branch suffix, a directory name and a backend label,
# so it must survive all three. Kebab case, no leading digit, bounded length.

valid_id() {
  # Negated classes rather than a positive pattern: `[a-z][a-z0-9-]*` needs two
  # characters to match at all, so it wrongly rejected a one character id.
  case $1 in
    ''|*[!a-z0-9-]*) return 1 ;;   # only lowercase, digits, hyphen
    [!a-z]*)         return 1 ;;   # must start with a letter
    *--*|*-)         return 1 ;;   # no doubled and no trailing hyphen
  esac
  [ ${#1} -le 48 ] || return 1
  return 0
}

require_id() {
  [ -n "${1:-}" ] || die "no errand id given"
  valid_id "$1" || die "bad errand id '$1': lowercase letters, digits and single hyphens, must start with a letter, max 48 chars"
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//' -e 's/--*/-/g' \
    | cut -c1-48 | sed -e 's/-*$//'
}

today() { date +%Y-%m-%d; }

# --- errand metadata --------------------------------------------------------
# key=value lines, one per line, no quoting. Absent key means absent, which is
# not the same as empty: meta_get returns the fallback only when the key is
# missing entirely.

meta_get() {
  local id=$1 key=$2 fallback=${3:-} f
  f=$(meta_file "$id")
  [ -f "$f" ] || { printf '%s\n' "$fallback"; return; }
  local line
  line=$(grep -m1 "^${key}=" "$f" 2>/dev/null) || { printf '%s\n' "$fallback"; return; }
  printf '%s\n' "${line#*=}"
}

meta_set() {
  local id=$1 key=$2 val=$3 f tmp
  f=$(meta_file "$id")
  mkdir -p "$(dirname "$f")"
  tmp="$f.$$"
  if [ -f "$f" ]; then grep -v "^${key}=" "$f" > "$tmp" 2>/dev/null || : ; else : > "$tmp"; fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$f"
}

meta_write() {
  # meta_write <id> <key=val> ...  Atomic whole-file write for initial creation.
  local id=$1; shift
  local f tmp
  f=$(meta_file "$id"); mkdir -p "$(dirname "$f")"; tmp="$f.$$"
  : > "$tmp"
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >> "$tmp"; done
  mv "$tmp" "$f"
}

# --- status reconciliation --------------------------------------------------
# The status file is append-only and every append is a WAKE EVENT, not the
# current state. This function is the single owner of turning the log into a
# verdict. Nothing else may read the last line and call it the state.
#
# Grammar, one per line:   <state>[ [key=<slug>]]: <note>
# States: working needs-decision blocked done failed resolved
#
# A needs-decision stays open until a resolved with the SAME key lands. A later
# done: never closes it, because a hand finishing is not the liege answering.
#
# Prints, in order:
#   state=<verdict>
#   open=<count of open decisions>
#   divergence=<yes|no>     terminal state reached with decisions still open
#   last=<last note>
#   decision=<key>\t<question>    one line per open decision, in order asked

status_reconcile() {
  local id=$1 f
  f=$(status_file "$id")
  if [ ! -f "$f" ]; then
    printf 'state=absent\nopen=0\ndivergence=no\nlast=\n'
    return 0
  fi

  local terminal='' progress='' last='' opened='' resolved=''
  local line state key note
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|'#'*) continue ;; esac
    # split off the note at the first colon that ends the state token
    state=${line%%:*}
    note=${line#*:}
    note=${note# }
    key=''
    case $state in
      *'[key='*']')
        key=${state#*'[key='}; key=${key%%']'*}
        state=${state%%'['*}
        ;;
    esac
    state=$(printf '%s' "$state" | tr -d '[:space:]')
    case $state in
      working)        progress=$state; last=$note ;;
      blocked|failed) terminal=''; progress=$state; last=$note ;;
      done)           terminal=$state; last=$note ;;
      needs-decision) [ -n "$key" ] || key="unkeyed-$(printf '%s' "$note" | cksum | cut -d' ' -f1)"
                      opened="$opened$key	$note
"; last=$note ;;
      resolved)       [ -n "$key" ] && resolved="$resolved$key
" ;;
      *)              : ;;  # unknown verb: ignore, never guess
    esac
  done < "$f"

  # open = opened minus resolved, preserving ask order, deduped by key
  local open_lines='' okey seen=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    okey=${line%%	*}
    lines_has "$okey" "$resolved" && continue
    lines_has "$okey" "$seen"     && continue
    seen="$seen$okey
"
    open_lines="$open_lines$line
"
  done <<EOS
$opened
EOS

  local open_n=0
  if [ -n "$open_lines" ]; then
    open_n=$(printf '%s' "$open_lines" | grep -c . 2>/dev/null) || open_n=0
    open_n=$(printf '%s' "$open_n" | tr -d '[:space:]')
    [ -n "$open_n" ] || open_n=0
  fi

  local verdict divergence=no
  if [ "$open_n" -gt 0 ]; then
    verdict=needs-decision
    # a hand that reported done while a decision is open is a divergence: the
    # work cannot be complete if a question it depends on was never answered
    case $terminal in done) divergence=yes ;; esac
    case $progress in blocked|failed) divergence=yes ;; esac
  elif [ -n "$terminal" ]; then
    verdict=$terminal
  elif [ -n "$progress" ]; then
    verdict=$progress
  else
    verdict=unknown
  fi

  printf 'state=%s\n' "$verdict"
  printf 'open=%s\n' "$open_n"
  printf 'divergence=%s\n' "$divergence"
  printf 'last=%s\n' "$last"
  printf '%s' "$open_lines" | while IFS= read -r line; do
    [ -n "$line" ] && printf 'decision=%s\n' "$line"
  done
  return 0
}

status_field() {
  # status_field <id> <field>
  status_reconcile "$1" | grep -m1 "^$2=" | sed "s/^$2=//"
}

# --- offices ---------------------------------------------------------------
# Single owner of "what offices exist". The directory also holds a README and a
# settings.json per office, so a bare `ls` lists things that are not offices.

office_names() {
  ls "$REEVE_ROOT_D/offices"/*.md 2>/dev/null | while read -r f; do
    n=$(basename "$f" .md)
    [ "$n" = README ] && continue
    printf '%s\n' "$n"
  done
}

# --- the office default tier ------------------------------------------------
# What an office spends when the dispatch names nothing. Declared as one table
# row per office under "## The default tier" in offices/README.md, and read from
# there rather than described there.
#
# Why that file, and not either of the two an office already owns:
#   offices/<office>.settings.json is a claude permissions document, copied
#     verbatim into the errand directory for the harness to enforce. A harness
#     agnostic tier in a harness specific file would be shipped to every hand
#     and read by nothing.
#   offices/<office>.md is inlined verbatim into every brief, so anything
#     declared there becomes text the hand reads as instruction. The tier is the
#     reeve's spending decision about a hand, not part of the hand's role.
# offices/README.md is already where an office is described, so the table a
# human reads and the table dispatch parses are one table. Same reasoning as
# manors.md above: two representations of one registry drift, and then neither
# is true.
#
# An empty cell is written `(none)`, which means unset: today's behaviour, the
# harness deciding. Never a guess at what the harness would have chosen.

office_tier() {
  # office_tier <office> <model|effort>   prints the value, or nothing
  local office=$1 axis=$2 f val
  case $axis in model|effort) ;; *) die "office_tier: unknown axis '$axis'" ;; esac
  f="$REEVE_ROOT_D/offices/README.md"
  [ -f "$f" ] || return 0
  # One awk, no pipeline: `sed | grep -m1` would close the pipe on the first
  # match, and under pipefail that reads as a failed lookup rather than a found
  # row. The section guard is what keeps an office name in the first column of
  # some other table in this file from becoming a declaration by accident.
  val=$(awk -F'|' -v office="$office" -v a="$axis" '
    /^## / { insec = ($0 ~ /^## The default tier/) }
    insec && !found && $0 ~ "^\\|[ \t]*" office "[ \t]*\\|" {
      v = (a == "model") ? $3 : $4
      gsub(/`/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v; found = 1
    }' "$f")
  case $val in ''|'(none)'|'-') return 0 ;; esac
  # The value is substituted into a harness flag and lands unquoted on a command
  # line, so a cell that is not one plain token is a documentation error worth
  # refusing over, not something to pass through and find out about at launch.
  case $val in *[!a-zA-Z0-9._-]*) die "office '$office' declares an unusable default $axis '$val' in $f" ;; esac
  printf '%s\n' "$val"
}

tier_say() {
  # tier_say <value> <origin> [note]   one phrase, for anything that prints a
  # tier. Single owner of the wording so dispatch and status never disagree
  # about what "harness" means: no value, because the household never learns
  # what the harness picked.
  local val=${1:-} from=${2:-harness} note=${3:-}
  if [ -z "$val" ]; then printf 'harness default\n'
  elif [ -n "$note" ]; then printf '%s (%s, %s)\n' "$val" "$from" "$note"
  else printf '%s (%s)\n' "$val" "$from"; fi
}

tier_resolve() {
  # tier_resolve <office> <model|effort> [flag-value]   prints <value>|<origin>
  #
  # Precedence, highest first: the flag the reeve passed, the office default,
  # then the harness. Each axis resolves alone, so an office may default effort
  # without pinning a model. Origin travels with the value because "this errand
  # ran cheap" and "who decided that" are two different questions, and the
  # second one is the one a reeve asks later.
  local office=$1 axis=$2 flag=${3:-} val
  if [ -n "$flag" ]; then printf '%s|flag\n' "$flag"; return 0; fi
  val=$(office_tier "$office" "$axis") || return 1
  if [ -n "$val" ]; then printf '%s|office\n' "$val"; else printf '|harness\n'; fi
}

# --- holdings registry -----------------------------------------------------
# manors.md is one file that both a human and a script can read. Each holding is
# one line in a fixed field order so `holding_field` can pull a value out
# without a parser, while the prose around it stays readable to the reeve.
#
#   - holding: portfolio | manor: portfolio | path: /abs/path | instructions: AGENT.md | base: main | setup: pnpm install | test: pnpm test
#
# `setup` is optional and runs once in a fresh worktree before the hand starts.
# `test` is passed through to the brief so a hand knows how to validate itself.
#
# One file, not a markdown copy plus a machine index, because two
# representations of the same registry drift and then nobody knows which is true.

manors_file() { printf '%s/manors.md\n' "$REEVE_HOME_D"; }

holding_line() {
  local name=$1 f
  f=$(manors_file)
  [ -f "$f" ] || return 1
  grep -m1 "^[[:space:]]*-[[:space:]]*holding:[[:space:]]*${name}[[:space:]]*|" "$f" 2>/dev/null
}

holding_field() {
  # holding_field <holding> <field> [fallback]
  local line field=$2 val
  line=$(holding_line "$1") || { printf '%s\n' "${3:-}"; return 1; }
  val=$(printf '%s' "$line" | tr '|' '\n' \
        | sed -n "s/^[[:space:]]*${field}:[[:space:]]*//p" | head -1 \
        | sed -e 's/[[:space:]]*$//')
  if [ -n "$val" ]; then printf '%s\n' "$val"; else printf '%s\n' "${3:-}"; fi
}

holding_names() {
  local f; f=$(manors_file); [ -f "$f" ] || return 0
  sed -n 's/^[[:space:]]*-[[:space:]]*holding:[[:space:]]*\([^ |]*\).*/\1/p' "$f"
}

resolve_holding_path() {
  # Accept a registered holding name, an absolute path, or a path relative to
  # the current directory. Always returns a real git toplevel, or fails loudly:
  # guessing a repo path is how a hand ends up editing the wrong project.
  local want=$1 p
  p=$(holding_field "$want" path '') || p=''
  if [ -z "$p" ]; then
    case $want in
      /*) p=$want ;;
      *)  if [ -d "$want" ]; then p=$(cd "$want" && pwd); fi ;;
    esac
  fi
  [ -n "$p" ] || return 1
  [ -d "$p" ] || return 1
  git -C "$p" rev-parse --show-toplevel 2>/dev/null
}

# --- locking ----------------------------------------------------------------
# mkdir is atomic on every filesystem we care about. A stale lock names the pid
# that holds it so a human can judge it; we never break one automatically.

lock_acquire() {
  local name=$1 timeout=${2:-30} d elapsed=0
  d="$REEVE_HOME_D/state/.lock-$name"
  mkdir -p "$REEVE_HOME_D/state"
  while ! mkdir "$d" 2>/dev/null; do
    if [ -f "$d/pid" ] && ! kill -0 "$(cat "$d/pid" 2>/dev/null)" 2>/dev/null; then
      warn "stale lock $name held by dead pid $(cat "$d/pid" 2>/dev/null), not breaking it automatically"
      warn "remove it by hand if you are sure: rm -rf $d"
    fi
    elapsed=$((elapsed + 1))
    [ "$elapsed" -lt "$timeout" ] || die "could not acquire lock '$name' after ${timeout}s"
    sleep 1
  done
  printf '%s\n' "$$" > "$d/pid"
  printf '%s\n' "$d"
}

lock_release() { [ -n "${1:-}" ] && rm -rf "$1"; }

# --- home -------------------------------------------------------------------

home_ensure() {
  local h=$REEVE_HOME_D
  mkdir -p "$h/errands" "$h/state" "$h/config" "$h/manors"
  [ -f "$h/archive.md" ] || printf '%s\n\n%s\n' "# Archive" \
    "Retired knowledge. Append only, never loaded into context, never deleted." > "$h/archive.md"
  printf '%s\n' "$h"
}

config_get() {
  local key=$1 fallback=${2:-} f
  f=$(config_file "$key")
  if [ -f "$f" ]; then
    tr -d '[:space:]' < "$f"
    printf '\n'
  else
    printf '%s\n' "$fallback"
  fi
}
