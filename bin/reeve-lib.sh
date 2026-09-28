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


# --- process markers --------------------------------------------------------
# Two files in state/, one shape, one line: `<pid> <epoch seconds> <poll>`.
#
#   .sentry.lock      a caretaker saying it is the cleaner for this home
#   .sentry.watch-*   a foreground watch saying a reeve is watching this home
#
# Both exist to answer the same question from the other side, "is the process
# that wrote this still there", so both answer it the same way. A pid alone
# cannot: a process killed with -9 leaves its pid behind, pids are reused, and
# an unrelated process of the same user inheriting that number reads as alive
# under `kill -0` forever.
#
# So the writer refreshes its own timestamp every poll and a reader believes a
# marker only while BOTH hold: the pid is alive, AND it was refreshed recently
# enough that the process really is still polling. The poll interval travels
# inside the marker because the reader has no other way to know the writer's.
# The allowance is three intervals and five seconds: one iteration costs about
# one interval, whether it spends it in the backend's native wait or in the
# sleep that replaces it, so three is slack for a loaded machine rather than a
# guess.
#
# These live here rather than in bin/reeve-sentry because the sentry is no
# longer the only reader. bin/reeve-dispatch asks the same question to find out
# whether anything at all will report the hand it just sent out, and a dispatch
# that answered it with its own second copy of the staleness rule would drift
# from the one the sentry enforces.
lock_marker()  { printf '%s/state/.sentry.lock\n' "$REEVE_HOME_D"; }
watch_marker() { printf '%s/state/.sentry.watch-%s\n' "$REEVE_HOME_D" "$1"; }

marker_stamp() { # marker_stamp <file> <poll>   write or refresh, whole, atomic
  local f=$1 p=${2:-15} tmp="$1.new.$$"
  printf '%s %s %s\n' "$$" "$(date +%s)" "$p" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# The path is an argument, never `< "$f" 2>/dev/null`: redirections are applied
# left to right, so the shell reports a missing file itself, on its own stderr,
# before the redirection that was meant to hide it is in effect. A caretaker
# that has to be silent cannot afford to say that, and it did.
marker_read() { cat "$1" 2>/dev/null; }

marker_mine() { case $(marker_read "$1") in "$$ "*) return 0 ;; esac; return 1; }

marker_alive() { # marker_alive <marker contents>
  local fields=${1:-} pid ts p now
  set -- $fields
  pid=${1:-}; ts=${2:-}; p=${3:-}
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  case $ts  in ''|*[!0-9]*) return 1 ;; esac
  case $p   in ''|*[!0-9]*) p=15 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  now=$(date +%s)
  [ $(( now - ts )) -le $(( p * 3 + 5 )) ]
}

# Is a caretaker holding this home right now.
caretaker_live() { marker_alive "$(marker_read "$(lock_marker)")"; }

# Is ANY session watching this home right now. Used for one question by the
# sentry: an errand with no recorded owner cannot be judged by its owner's
# liveness, so the blanket answer is the only safe one for those.
watch_live() {
  local f
  for f in "$REEVE_HOME_D/state"/.sentry.watch-*; do
    [ -f "$f" ] || continue
    marker_alive "$(marker_read "$f")" && return 0
  done
  return 1
}

# --- pending wakes ----------------------------------------------------------
# A reeve is woken by bin/reeve-sentry and by nothing else, so a reeve that
# dispatches and then sits idle has nothing watching on its behalf at all. What
# a dispatch leaves running is a caretaker, and a caretaker is silent by
# contract: it cleans up after a finished hand and tells nobody, because it has
# no reeve to tell. That is the whole of the missed wake. The one `done:` line
# the household exists to deliver was seen only by the process that then freed
# the hand's session and blanked its target, which put the errand out of reach
# of every watch that might have started afterwards.
#
# So a caretaker hands the line over instead of consuming it. One file per
# OWNING session, because the home is shared and a wake belongs to the reeve
# that briefed the errand. Appended to by whoever cleans up, drained a line at a
# time by the owner, and durable, because the whole point is a reeve that is not
# looking yet.
#
# A reeve that resets does not need these: a new session has a new id, and the
# contract already has it rebuild the entire fleet from the status files at
# startup, which is the stronger recovery path and the reason nothing here has
# to survive a change of owner.
#
# A SPOOL, one file per wake, not one file per session holding a line each.
# The file-per-session shape this replaces was read with head, rewritten with
# tail and moved into place, and every one of those three steps is a window:
# measured on the shape it replaces, 200 appends against one draining reader
# lost 54, and two readers over 60 queued lines delivered one line each, twice,
# and destroyed the other 59. A reader that never rewrites a file a writer may
# be appending to has no such window, and two readers cannot collide over a
# file that only one of them can rename.
#
# The whole channel therefore holds to two rules, and the second is the one
# that was missing:
#
#   a writer only ever CREATES a file, under a name nobody else can take
#   a reader only ever REMOVES one, and only after its line reached stdout
#
# Delivery that has not happened yet is a file still on disk, so a reader that
# dies mid-delivery, at a closed pipe or under a kill, costs one poll of latency
# rather than the line.
#
# Inside the owning session's directory rather than beside it, so the one rule
# that collects a session's records (sessions_prune, which never touches a
# session that still owns a live errand) covers the spool with no second rule to
# keep in step with the first.
wake_dir() { # wake_dir <session>
  printf '%s/state/sessions/%s/wake\n' "$REEVE_HOME_D" "$1"
}

# One spool entry: three key=value lines, `say` last and never more than one
# line, because the reeve reads exactly one line per wake.
#
#   errand=<id>     which errand this is about, so delivery can mark it reported
#   lines=<count>   how much of that errand's log the line accounts for
#   say=<the line>  the wake itself, verbatim
#
# Names are `<epoch seconds>.<pid>.<sequence>`, zero padded so a plain glob
# sorts them, and the sequence is found by trying the next one until `ln`
# succeeds. `ln` is the atomic primitive for the same reason the caretaker's
# lock uses it: it fails if the name is taken, so two writers can never agree on
# one name, and macOS ships no flock. Within one second two writers are ordered
# by pid rather than by arrival, which is a known and harmless imprecision:
# order is a courtesy here, delivery is not.
wake_leave() { # wake_leave <session> <line> [<errand>] [<log lines>]
  local d tmp n name
  [ -n "${1:-}" ] || return 1
  d=$(wake_dir "$1")
  mkdir -p "$d" 2>/dev/null || return 1
  tmp="$d/.new.$$.${RANDOM:-0}"
  { printf 'errand=%s\n' "${3:-}"
    printf 'lines=%s\n'  "${4:-}"
    printf 'say=%s\n'    "$2"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  # WAKE_SEQ carries the last name this process took, so a caretaker leaving
  # several lines in one second walks forward instead of rescanning from zero
  # each time. Only ever a hint: the loop is what guarantees the name.
  n=${WAKE_SEQ:-0}
  while :; do
    name=$(printf '%s.%s.%05d' "$(date +%s)" "$$" "$n")
    ln "$tmp" "$d/$name" 2>/dev/null && break
    n=$((n + 1))
    [ "$n" -lt 100000 ] || { rm -f "$tmp"; return 1; }
  done
  WAKE_SEQ=$((n + 1))
  rm -f "$tmp"
  return 0
}

# Everything in this session's spool that is free to be delivered, oldest first.
#
# A reader claims an entry by renaming it to `<name>.claimed.<its pid>`, which
# is what stops two readers delivering one line twice: the rename succeeds for
# exactly one of them. A claim is not a lock, though, and must never outlive the
# process holding it, so a claim whose pid is gone is free again. That is the
# same judgement the markers above make about a stale process, made the same
# way, and it is what makes an interrupted delivery cost latency rather than the
# line.
wake_pending() { # wake_pending [<session>]
  local s d f b pid
  s=${1:-$(reeve_session)}; [ -n "$s" ] || return 1
  d=$(wake_dir "$s"); [ -d "$d" ] || return 1
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    b=${f##*/}
    case $b in
      *.claimed.*)
        pid=${b##*.claimed.}
        case $pid in ''|*[!0-9]*) continue ;; esac
        # Somebody is delivering it right now. Leave it to them.
        kill -0 "$pid" 2>/dev/null && continue
        ;;
    esac
    printf '%s\n' "$f"
  done
}

wake_field() { # wake_field <spool file> <key>
  local line key=$2
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    case $line in "$key="*) printf '%s\n' "${line#"$key="}"; return 0 ;; esac
  done < "$1"
  return 1
}

wake_claim() { # wake_claim <spool file>   prints the claimed path
  local f=$1 c
  c="${f%%.claimed.*}.claimed.$$"
  if [ "$f" != "$c" ]; then mv "$f" "$c" 2>/dev/null || return 1; fi
  printf '%s\n' "$c"
}

wake_release() { # wake_release <claimed path>   hand it back undelivered
  local c=$1 f
  f=${c%%.claimed.*}
  [ "$c" = "$f" ] && return 0
  mv "$c" "$f" 2>/dev/null || return 1
}

# Deliver the oldest pending wake for this session: one line, on stdout, then
# the file goes.
#
# In that order, and the order is the fix. The shape this replaces cleared the
# line and then handed it back, so `reeve-status --all | head -1` printed one
# signal, destroyed the next on the write that failed, and left the third:
# measured, three in, one delivered, one gone. Writing first means a write that
# fails leaves the entry exactly where it was, and a reader killed mid-line
# leaves a claim its own death frees.
#
# Delivering also advances the errand's cursor, so the wake IS the report rather
# than a second copy of one. Without it the reeve wakes twice for one finished
# hand: once for the line the caretaker left and again on the next watch, off
# the errand still standing in live_errands with no cursor against it. Never
# backwards, because a cursor already further along was written by a watch that
# read more of the log than this line accounts for.
wake_deliver() { # wake_deliver [<session>]
  local s f c say id n cur
  s=${1:-$(reeve_session)}; [ -n "$s" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    c=$(wake_claim "$f") || continue
    say=$(wake_field "$c" say)
    printf '%s\n' "$say" || { wake_release "$c"; return 1; }
    id=$(wake_field "$c" errand); n=$(wake_field "$c" lines)
    case $id in ''|*[!a-z0-9-]*) id='' ;; esac
    case $n  in ''|*[!0-9]*)     n=''  ;; esac
    if [ -n "$id" ] && [ -n "$n" ]; then
      cur=$(cat "$(cursor_file "$id")" 2>/dev/null | tr -d '[:space:]')
      case $cur in ''|*[!0-9]*) cur=0 ;; esac
      if [ "$n" -gt "$cur" ]; then printf '%s\n' "$n" > "$(cursor_file "$id")" 2>/dev/null || :; fi
    fi
    rm -f "$c"
    return 0
  done <<WAKE_DELIVER_EOF
$(wake_pending "$s")
WAKE_DELIVER_EOF
  return 1
}

# The pending lines without taking any of them, for a caller that is answering
# some other question. Anything that reads the fleet programmatically goes
# through this or through `reeve-status --no-wake`: a wake consumed by a command
# run to ask something else is a wake nobody ever sees.
wake_peek() { # wake_peek [<session>]
  local s f
  s=${1:-$(reeve_session)}; [ -n "$s" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    wake_field "$f" say
  done <<WAKE_PEEK_EOF
$(wake_pending "$s")
WAKE_PEEK_EOF
}

# Carry one errand's pending wakes to a new owner, and print how many moved.
#
# Adoption rewrites `session=` and the wake is addressed to a session, so
# without this the line stays in a mailbox belonging to a reeve that is, by the
# rule adoption is allowed under, provably gone. Copy first and remove second,
# deliberately: interrupted between the two the line is delivered twice, and a
# duplicate is noise where a loss is the whole defect.
wake_move() { # wake_move <from session> <to session> <errand>
  local from=${1:-} to=${2:-} id=${3:-} f moved=0
  [ -n "$from" ] && [ -n "$to" ] && [ -n "$id" ] || { printf '0\n'; return 1; }
  [ "$from" = "$to" ] && { printf '0\n'; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$(wake_field "$f" errand)" = "$id" ] || continue
    wake_leave "$to" "$(wake_field "$f" say)" "$id" "$(wake_field "$f" lines)" || continue
    rm -f "$f"
    moved=$((moved + 1))
  done <<WAKE_MOVE_EOF
$(wake_pending "$from")
WAKE_MOVE_EOF
  printf '%s\n' "$moved"
}

# What the household has already reported about an errand, as a count of status
# log lines. Here rather than in bin/reeve-sentry because the sentry is no
# longer the only writer: delivering a wake marks the errand reported too, and
# two copies of one path would drift the way the marker rules would have.
cursor_file() { printf '%s/state/.cursor-%s\n' "$REEVE_HOME_D" "$1"; }

# --- session identity -------------------------------------------------------
# One home is shared by every reeve on this machine, so an errand id alone
# cannot say who is watching it. A session owns the errands it briefed, and a
# sentry reports and reaps only its own. Without this, one reeve absorbs
# another's wake and tears down a scout that was never its business: a scout
# commits nothing, so the landed-work guard has nothing to refuse over and the
# copy goes.
#
# The id costs nothing to obtain. Claude Code exports CLAUDE_CODE_SESSION_ID
# into every tool call, so a script invoked by a reeve inherits it already.
# REEVE_SESSION overrides it, for another harness and for the tests.
#
# An unresolved session is EMPTY, never a fallback value. Two sessions that
# both guessed the same name would own each other's errands, which is the exact
# failure this exists to prevent. Callers fail closed on empty: read and
# dispatch are fine, reaping is not.
reeve_session() {
  local s=${REEVE_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}
  # A session id becomes a directory name, so it is validated the way an errand
  # id is, with negated classes under LC_COLLATE=C. Anything else is unusable
  # rather than sanitised: a silently rewritten id is a wrong owner.
  case $s in
    '') printf '' ;;
    *[!A-Za-z0-9._-]*) printf '' ;;
    .|..) printf '' ;;
    *) printf '%s' "$s" ;;
  esac
}

session_dir() { printf '%s/state/sessions/%s\n' "$REEVE_HOME_D" "$1"; }

# The heartbeat. A session that dies leaves errands nobody watches, and the
# caretaker must not act against an owner that is still there, so something has
# to say "still here" without a daemon and without a pid: a pid is reused, and a
# reused pid would hand one session's errands to a stranger.
#
# Called from the commands that mean a reeve is actually working (brief, status,
# adopt, doctor) and from the sentry's poll loop, plus the statusline gauge,
# which is the one writer that keeps saying so while a session sits idle.
# NOT called on sourcing this file: reeve-dispatch promises a --dry-run changes
# nothing, and a heartbeat written by merely loading the library would break
# that promise from underneath it.
session_touch() {
  local s d; s=$(reeve_session); [ -n "$s" ] || return 0
  # Only ever inside a home that already exists. Creating one here would make
  # `reeve-doctor` stop saying "run install.sh" on a machine that never has.
  [ -d "$REEVE_HOME_D/state" ] || return 0
  d=$(session_dir "$s"); mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\n' "$(date +%s)" > "$d/seen.$$" 2>/dev/null || return 0
  mv -f "$d/seen.$$" "$d/seen" 2>/dev/null || rm -f "$d/seen.$$"
  # Saying "still here" is also the moment to clear out those who are not.
  sessions_prune_maybe
}

# Three answers, not two, and the third is the one that matters.
#
#   alive    refreshed inside the window, so its reeve is still there
#   dead     it heartbeat once and stopped, so its reeve is provably gone
#   unknown  it never heartbeat at all
#
# `dead` is a proof and `unknown` is an absence, and only a proof may authorise
# tearing somebody's errand down. Collapsing the two would make every session
# that has not yet watched anything look gone, and its live errands would be
# reaped out from under it. So an unknown session fails closed: never reaped,
# reported instead, which is the same rule reeve-context follows for a figure
# it cannot measure.
#
# Deliberately not a pid check. A pid is reused, and an unrelated process of
# this user inheriting that number would read as alive forever.
# Every claude session on this machine writes a record here, not only reeve
# ones, because the statusline gauge that feeds it renders for all of them. Left
# alone that grows without bound: one directory per session, forever.
#
# Two rules decide what may go, and the first is the one that matters.
#
# **Never prune a session that still owns a live errand.** `reeve-status
# --orphans` finds abandoned work by asking whether its OWNER is gone, and only
# a `dead` answer counts. A session with no record left answers `unknown`, which
# --orphans excludes on purpose, so pruning one would not tidy its errands away:
# it would make them invisible, still in flight, with nothing left to say who
# was supposed to be watching them.
#
# **Keep the recent past.** A record is evidence about a session that has just
# gone, and reeve-adopt refuses without it. The retention window is far longer
# than the staleness one for that reason: stale means "not watching now", while
# prunable means "long enough ago that nobody is going to ask".
#
# Set session-retain to 0 to keep every record forever.
sessions_prune() {
  local retain d sid owners keep now seen pruned=0
  retain=$(config_get session-retain 604800)
  case $retain in ''|*[!0-9]*) return 0 ;; esac
  [ "$retain" -gt 0 ] || return 0
  [ -d "$REEVE_HOME_D/state/sessions" ] || return 0
  now=${REEVE_NOW:-$(date +%s)}

  # Owners of every errand still in flight, read once rather than per session.
  owners=$(ls "$REEVE_HOME_D/state"/*.meta 2>/dev/null | while read -r f; do
    i=$(basename "$f" .meta)
    [ -z "$(meta_get "$i" tornDown '')" ] || continue
    meta_get "$i" session ''
  done)

  keep=$(reeve_session)
  for d in "$REEVE_HOME_D"/state/sessions/*; do
    [ -d "$d" ] || continue
    sid=$(basename "$d")
    # Never this session, whatever its record looks like.
    [ "$sid" = "$keep" ] && continue
    lines_has "$sid" "$owners" && continue
    # An unreadable or absent mark falls back to the directory's own age, so a
    # record that was created and never written is not immortal.
    seen=''
    [ -f "$d/seen" ] && seen=$(tr -dc '0-9' < "$d/seen" 2>/dev/null)
    [ -n "$seen" ] || seen=$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo "$now")
    [ $(( now - seen )) -gt "$retain" ] || continue
    rm -rf "$d" 2>/dev/null && pruned=$((pruned + 1))
  done
  printf '%s\n' "$pruned"
}

# Pruning is bookkeeping, so it happens on its own rather than being something
# to remember. Rate limited hard: the scan is cheap but it runs behind every
# reeve-* call, and once an hour is plenty for a directory that grows by one
# entry per session.
sessions_prune_maybe() {
  local mark age now
  mark="$REEVE_HOME_D/state/sessions/.pruned"
  [ -d "$REEVE_HOME_D/state/sessions" ] || return 0
  now=${REEVE_NOW:-$(date +%s)}
  if [ -f "$mark" ]; then
    age=$(tr -dc '0-9' < "$mark" 2>/dev/null)
    case $age in ''|*[!0-9]*) age=0 ;; esac
    [ $(( now - age )) -ge "${REEVE_PRUNE_EVERY:-3600}" ] || return 0
  fi
  printf '%s\n' "$now" > "$mark" 2>/dev/null || return 0
  sessions_prune >/dev/null
}

session_state() { # session_state <sid> -> alive | dead | unknown
  local s=$1 f now seen
  [ -n "$s" ] || { printf 'unknown\n'; return; }
  f=$(session_dir "$s")/seen
  [ -f "$f" ] || { printf 'unknown\n'; return; }
  seen=$(tr -dc '0-9' < "$f" 2>/dev/null)
  [ -n "$seen" ] || { printf 'unknown\n'; return; }
  now=${REEVE_NOW:-$(date +%s)}
  if [ $(( now - seen )) -le "$(config_get session-stale 900)" ]
    then printf 'alive\n'
    else printf 'dead\n'
  fi
}
# --- output -----------------------------------------------------------------
# Everything a script prints is read by the reeve, so keep it one fact per line.

die()  { printf 'reeve: %s\n' "$*" >&2; exit 1; }
warn() { printf 'reeve: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

# print_help <script-path>   the script's own header comment, whole.
#
# A tool's usage IS its header comment, so this reads to wherever that comment
# actually ends rather than a fixed line range someone has to remember to
# update. The block is the shebang, then every line starting with '#' right
# after it; the first line that is not one ends the block.
print_help() {
  awk 'NR == 1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
}

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
  #
  # Read without a pipe, for the reason the header of this file gives about
  # `grep -q`: `grep -m1` exits on its first match and closes the pipe under it,
  # and status_reconcile is still writing its `decision=` lines when it does. The
  # value was always right, because the match had already come back, but the
  # writer got EPIPE and bash printed "printf: write error: Broken pipe" on
  # stderr for it. Only when the errand had an open decision, and only when the
  # reader won the race, so it read as noise from nowhere. A caretaker has to be
  # silent to be useful, and that includes not saying this.
  #
  # Same values, and that part was measured: byte identical over 306 cases,
  # including a missing field, an empty one, values carrying tabs, globs and
  # backslashes, an errand with sixty open decisions and an errand that does not
  # exist. Not the same exit status, which an earlier note here claimed and this
  # one corrects: the piped form returned 1 when the field was absent, because
  # `grep -m1` missed and pipefail carried it out, and 141 when it lost the race
  # above. This form returns 0 always. Nothing reads it, today: all ten call
  # sites capture with $(...) and no script in bin/ runs under `set -e`. Anything
  # that comes to depend on an absent field being distinguishable from an empty
  # one has to reintroduce that distinction deliberately, and say so here, rather
  # than find it by accident in an exit status.
  local line key=$2
  while IFS= read -r line; do
    case $line in "$key="*) printf '%s\n' "${line#"$key="}"; return 0 ;; esac
  done <<STATUS_FIELD_EOF
$(status_reconcile "$1")
STATUS_FIELD_EOF
  return 0
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

# Every holding registered under one manor. A manor is one project that may span
# several repositories, and the registry has carried a manor: field per holding
# from the start, so this reads a grouping that is already recorded rather than
# inventing one.
#
# What it is for: a hand can reach its own worktree and one granted directory,
# and nothing else. A scout sent to find out why the web app mishandles a
# response from the API cannot open the API repository at all, and because it
# stalls inside a tool call it never reports `blocked:` either. Its last line
# stays `working:` and the watch reads it as healthy.
manor_holdings() { # manor_holdings <manor>
  local f m=$1; f=$(manors_file); [ -f "$f" ] || return 0
  [ -n "$m" ] || return 0
  # Field order in a holding line is fixed, so the manor is matched as a whole
  # field between its delimiters. Matching it loosely would make manor `web`
  # collect every holding of manor `web-admin`.
  #
  # The name is escaped first. It comes straight from `--manor` on
  # reeve-survey --register, so it is liege-supplied text and not a pattern: an
  # unescaped `/` closes the s/// command and sed fails, silently here because
  # the caller drops stderr, so the hand simply gets no siblings at all.
  local esc; esc=$(printf '%s' "$m" | sed 's/[][\\.*^$/&]/\\&/g')
  sed -n "s/^[[:space:]]*-[[:space:]]*holding:[[:space:]]*\([^ |]*\)[[:space:]]*|[[:space:]]*manor:[[:space:]]*$esc[[:space:]]*|.*/\1/p" "$f"
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
  mkdir -p "$h/errands" "$h/state" "$h/state/sessions" "$h/config" "$h/manors"
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
