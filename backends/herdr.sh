#!/usr/bin/env bash
# herdr backend. Primary. Verified against herdr 0.9.0, which is what is
# installed; the notes below about 0.7.5 behaviour are kept where they still
# describe why a constraint exists. `agent explain`, which attention_state rests
# on, did not exist in 0.7.5 at all.
#
# Every constraint in here is deliberate and load bearing. See the notes at each
# one before simplifying it away.

_h_session() {
  # HERDR_SESSION is NOT injected by 0.7.5 (checked: only HERDR_ENV, PANE_ID,
  # SOCKET_PATH, TAB_ID, WORKSPACE_ID are). So resolve the default session from
  # the server rather than trusting an env var that may not exist.
  if [ -n "${REEVE_HERDR_SESSION:-}" ]; then printf '%s\n' "$REEVE_HERDR_SESSION"; return; fi
  herdr session list --json 2>/dev/null \
    | jq -r '.sessions[] | select(.default == true) | .name' 2>/dev/null | head -1
}

_h() {
  # Every call carries an explicit --session. Env-only session selection is
  # unreliable the moment a second herdr server is running, and picking the
  # wrong server means mutating panes that belong to someone else's work.
  local ses
  ses=$(_h_session)
  [ -n "$ses" ] || { echo "herdr: no running session" >&2; return 1; }
  local sub=$1; shift
  herdr "$sub" "$@" --session "$ses" 2>/dev/null
}

# A target is "<workspace_id>|<pane_id>" for a hand in a workspace of its own,
# or "<workspace_id>|<pane_id>|<tab_id>" for one opened as a tab inside its
# reeve's workspace. Pane and tab ids themselves contain a colon (w4:p1, w4:t2),
# so a colon separator would be ambiguous. Pipe never appears in any of them.
# Both forms parse here, so targets recorded before nesting keep working.
#
# Either form may end `#c<n>l<m>`, its identity: what the endpoint was when it
# was made. Ids are counters, and after a server restart a closed workspace's
# id is handed out again, so a kept id can name someone else's tab. Its
# terminal_id would tell them apart but does not survive a restart (measured on
# 0.9.0: every pane came back with a new one). A restored endpoint keeps its id
# and its label, and usually its working directory: <n> is a checksum of that
# directory, which for a hand is its errand's own copy, <m> of the label it was
# given. Either one matching is the same endpoint, since a stranger reusing the
# id shows neither, and two are kept because neither always survives: a
# restored shell's startup files were measured leaving it in another directory,
# and the liege may rename a tab. A target without one, from before, is trusted
# as it always was.
#
# Only a trailing suffix of that exact shape is one, so a `#` anywhere else, in
# an id a later herdr hands out, stays part of the id.
_h_base() { if [[ $1 =~ ^(.*)#c[0-9]*l[0-9]*$ ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; else printf '%s\n' "$1"; fi; }
_h_want() { [[ $1 =~ \#(c[0-9]*l[0-9]*)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"; }
_h_ws()   { local b; b=$(_h_base "$1"); printf '%s\n' "${b%%|*}"; }
_h_pane() { local b r; b=$(_h_base "$1"); r=${b#*|}; printf '%s\n' "${r%%|*}"; }
_h_tab()  { local b r; b=$(_h_base "$1"); r=${b#*|}; case $r in *'|'*) printf '%s\n' "${r#*|}" ;; esac; }

_h_sum() { [ -n "$1" ] && printf '%s' "$1" | cksum | cut -d' ' -f1; } # nothing for nothing

# _h_label_of <target>   the label its tab, else its workspace, shows now
_h_label_of() {
  local tab ws
  tab=$(_h_tab "$1")
  if [ -n "$tab" ]; then _h tab get "$tab" | jq -r '.result.tab.label // empty' 2>/dev/null; return 0; fi
  ws=$(_h_ws "$1"); [ -n "$ws" ] || return 0
  _h workspace get "$ws" | jq -r '.result.workspace.label // empty' 2>/dev/null
  return 0
}

# _h_verified <target> [<pane get document>]   0 when the target carries no
# identity or its pane still shows it. 1 is a different pane under the same id:
# the caller treats it as missing and never acts on it. 2 is a pane that could
# not be read, which proves nothing either way.
#
# A mismatch is read again before it counts. A shell that is starting, which a
# pane restored by a server restart is, reports the directories its startup
# files pass through (measured: a zsh plugin directory, for a moment), and one
# such reading would call the hand's own pane someone else's.
#
# A label is not one hand's alone: two hands of one office from one reeve both
# read `Scout of Aldric`. So a label match does not count from a pane that
# sits in another git checkout: that is another hand, in its own copy, under
# the shared label. A restored shell that wandered off lands somewhere else.
_h_verified() {
  local want wc wl='' doc d c l n=0
  want=$(_h_want "$1") || return 0
  wc=${want#c}; wc=${wc%%l*}
  case $want in *l*) wl=${want##*l} ;; esac
  doc=${2:-}
  while :; do
    [ -n "$doc" ] || doc=$(_h pane get "$(_h_pane "$1")") || return 2
    d=$(printf '%s' "$doc" | jq -r '.result.pane.cwd // empty' 2>/dev/null)
    c=$(_h_sum "$d")
    [ -n "$c" ] && [ "$c" = "$wc" ] && return 0
    l=''
    [ -n "$wl" ] && l=$(_h_sum "$(_h_label_of "$1")")
    [ -n "$l" ] && [ "$l" = "$wl" ] && ! _h_other_checkout "$d" "$wc" && return 0
    [ -n "$c$l" ] || return 2
    n=$((n + 1)); [ "$n" -lt "${REEVE_IDENT_TRIES:-3}" ] || return 1
    sleep 1; doc=''
  done
}

# _h_other_checkout <dir> <sum>   0 when <dir> is inside a git work tree whose
# top level is not the directory <sum> is the checksum of.
_h_other_checkout() {
  local top
  [ -n "$1" ] && [ -d "$1" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd -P "$top" 2>/dev/null && pwd -P) || return 1
  [ "$(_h_sum "$top")" != "$2" ]
}

reeve_backend_herdr_available() {
  command -v herdr >/dev/null 2>&1 || { echo "herdr not on PATH" >&2; return 1; }
  command -v jq    >/dev/null 2>&1 || { echo "jq not on PATH, required to parse herdr output" >&2; return 1; }
  herdr status server --json >/dev/null 2>&1 || { echo "herdr server not running, start it with: herdr" >&2; return 1; }
  [ -n "$(_h_session)" ] || { echo "herdr running but no default session found" >&2; return 1; }
  return 0
}

reeve_backend_herdr_describe() {
  printf 'herdr %s (session %s)\n' "$(herdr --version 2>/dev/null | awk '{print $NF}')" "$(_h_session)"
}

# _h_sock   the socket of the server _h talks to, or nothing. Workspace ids are
# short counters per server (w5 on one, w5 on another), so HERDR_WORKSPACE_ID
# only names a workspace on this server when HERDR_SOCKET_PATH is this socket.
_h_sock() {
  local ses
  ses=$(_h_session); [ -n "$ses" ] || return 0
  herdr session list --json 2>/dev/null \
    | jq -r --arg n "$ses" '.sessions[]? | select(.name == $n) | .socket_path // empty' 2>/dev/null | head -1
}

# A group id is `<workspace id>@<socket>`, for the same reason: a bare w5 kept
# by one session names some other workspace on another server, perhaps the
# liege's. A bare one, kept before the socket was, is on an unknown server.
_h_gid() { printf '%s\n' "${1%%@*}"; }

# _h_held <ws> <sock> <held...>   0 when another live reeve holds <ws> on <sock>.
# A held id with no socket holds that workspace on every server: the safe way.
_h_held() {
  local w=$1 s=$2 h; shift 2
  for h in "$@"; do
    case $h in
      *@*) [ "$h" = "$w@$s" ] && return 0 ;;
      *)   [ "$h" = "$w" ] && return 0 ;;
    esac
  done
  return 1
}

_h_name_was() { # _h_name_was <label> <name...>   0 when <label> is one of them
  local l=$1 n; shift
  for n in "$@"; do [ "$n" = "$l" ] && return 0; done
  return 1
}

reeve_backend_herdr_ensure_group() {
  # Optional. The workspace a reeve's hands open in as tabs. Its own workspace
  # first, when it runs inside herdr on this same server: that is where the
  # liege is already looking, and it is relabelled with the reeve's name so the
  # sidebar says whose it is. Then the one a previous call made, if it is still
  # there. Then a fresh one under the name. Identity is always an id herdr
  # returned, never a label: herdr does not enforce label uniqueness.
  #
  # Every id after the known one is held by another live reeve, and one reeve
  # per workspace: a held one is never renamed, nested into or reused. And a
  # hand (REEVE_HAND, set by dispatch) never takes the workspace it sits in,
  # which is its reeve's.
  #
  # Ids go in and come out as `<workspace id>@<socket>`. A known one is reused
  # only on the server it was made on; a bare one, from before the socket was
  # kept, names an unknown server and is not reused at all.
  #
  # Except under REEVE_GROUP_KEEP, which says the known group still holds hands
  # of this reeve's: a reeve that moved to another workspace keeps sending its
  # hands to the one they are in, until none are left there.
  local label=$1 known=${2:-} ws out sock cur
  shift; [ $# -gt 0 ] && shift
  sock=$(_h_sock)
  [ -n "$sock" ] || echo "herdr: session $(_h_session) lists no socket path, so no workspace can be reused and $label gets a new one" >&2
  if [ -n "${REEVE_GROUP_KEEP:-}" ] && out=$(_h_known_group "$label" "$known" "$sock" "$@" 2>/dev/null); then
    printf '%s\n' "$out"; return 0
  fi
  ws=${HERDR_WORKSPACE_ID:-}
  if [ -n "$ws" ] && [ -z "${REEVE_HAND:-}" ] && [ -n "$sock" ] && [ "$sock" = "${HERDR_SOCKET_PATH:-}" ] \
     && _h workspace get "$ws" >/dev/null; then
    if _h_held "$ws" "$sock" "$@"; then
      echo "herdr: workspace $ws belongs to another live reeve, so $label gets a workspace of its own" >&2
    else
      _h workspace rename "$ws" "$label" >/dev/null || :
      printf '%s@%s\n' "$ws" "$sock"; return 0
    fi
  fi
  _h_known_group "$label" "$known" "$sock" "$@" && return 0
  out=$(_h workspace create --cwd "${HOME:-$PWD}" --label "$label" --no-focus) || return 1
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // .result.workspace_id // empty' 2>/dev/null)
  [ -n "$ws" ] || { echo "herdr: workspace create returned no id" >&2; return 1; }
  printf '%s%s\n' "$ws" "${sock:+@$sock}"
}

# _h_known_group <label> <known> <sock> <held...>   print the known group and
# rc 0 when it may be reused: on this server, held by nobody, still there.
_h_known_group() {
  local label=$1 known=$2 sock=$3 ws='' cur
  shift 3
  case $known in *@*) [ -n "$sock" ] && [ "${known#*@}" = "$sock" ] && ws=$(_h_gid "$known") ;; esac
  [ -n "$ws" ] && ! _h_held "$ws" "$sock" "$@" && cur=$(_h workspace get "$ws") || return 1
  # The label follows the name. `reeve-name set` outside herdr had no
  # workspace to relabel, so the rename lands here, on a group this name owns.
  # Only while it still shows this name or one this reeve's records held
  # ($REEVE_GROUP_NAMES): ids are counters, and after a server restart on
  # the same socket the id may be someone else's workspace now. Any other
  # label and it is neither renamed nor reused.
  cur=$(printf '%s' "$cur" | jq -r '.result.workspace.label // empty' 2>/dev/null)
  if [ "$cur" = "$label" ]; then
    printf '%s@%s\n' "$ws" "$sock"; return 0
  fi
  if [ -n "$cur" ] && _h_name_was "$cur" ${REEVE_GROUP_NAMES:-}; then
    _h workspace rename "$ws" "$label" >/dev/null || :
    printf '%s@%s\n' "$ws" "$sock"; return 0
  fi
  echo "herdr: workspace $ws now shows '$cur', not a name of this reeve, so $label gets a new one" >&2
  return 1
}

reeve_backend_herdr_create_endpoint() {
  local cwd=$1 label=$2 group out ws pane tab
  group=$(_h_gid "${3:-}")   # the workspace, without the socket ensure_group checked
  [ -d "$cwd" ] || { echo "cwd does not exist: $cwd" >&2; return 1; }

  # With a group, the hand is a tab in its reeve's workspace. tab create returns
  # the tab and its root pane together, measured on 0.9.0. Anything missing and
  # the hand gets a workspace of its own instead, as it did before nesting.
  if [ -n "$group" ]; then
    out=$(_h tab create --workspace "$group" --cwd "$cwd" --label "$label" --no-focus) || out=''
    tab=$(printf '%s' "$out"  | jq -r '.result.tab.tab_id // .result.root_pane.tab_id // empty' 2>/dev/null)
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    if [ -z "$pane" ] && [ -n "$tab" ]; then
      pane=$(_h pane list --workspace "$group" \
        | jq -r --arg t "$tab" '[.result.panes[]? | select(.tab_id == $t)][0].pane_id // empty' 2>/dev/null)
    fi
    if [ -n "$tab" ] && [ -n "$pane" ]; then
      printf '%s|%s|%s%s\n' "$group" "$pane" "$tab" "$(_h_ident "$cwd" "$label")"; return 0
    fi
    # A tab with no pane to address is no use to anyone, so it does not linger.
    [ -n "$tab" ] && _h tab close "$tab" >/dev/null 2>&1
    echo "herdr: could not open a tab in workspace $group, opening a workspace of its own" >&2
    pane=''
  fi

  # worktree open does in one call what tab create plus a split would do in two,
  # and it groups the checkout under its parent repo in the sidebar. It returns
  # workspace, tab and root_pane together, so there is no id to guess.
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    out=$(_h worktree open --path "$cwd" --label "$label" --no-focus) || out=''
    ws=$(printf '%s' "$out"   | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty'      2>/dev/null)
  fi

  # Fall back to a plain workspace when the directory is not a git checkout, or
  # when worktree open declined (it refuses a path git does not know about).
  if [ -z "${pane:-}" ]; then
    out=$(_h workspace create --cwd "$cwd" --label "$label" --no-focus) || return 1
    ws=$(printf '%s' "$out"   | jq -r '.result.workspace.workspace_id // .result.workspace_id // empty' 2>/dev/null)
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    if [ -z "$pane" ] && [ -n "$ws" ]; then
      pane=$(_h pane list --workspace "$ws" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null)
    fi
  fi

  [ -n "${pane:-}" ] || { echo "herdr: could not obtain a pane for $cwd" >&2; return 1; }
  printf '%s|%s%s\n' "${ws:-}" "$pane" "$(_h_ident "$cwd" "$label")"
}

# _h_ident <dir> <label>   `#c<n>l<m>` for a target made to work in <dir> under
# <label>. From the directory asked for, resolved the way the server reports
# it, never read back from the new pane: its shell is starting, and reads
# wherever that takes it.
_h_ident() {
  local d
  d=$(cd -P "$1" 2>/dev/null && pwd -P) || return 0
  printf '#c%sl%s' "$(_h_sum "$d")" "$(_h_sum "$2")"
}

# _h_refuse <target>   the one message for a target that cannot be shown to be
# the pane it was. rc 1, so the caller acts on nothing.
_h_refuse() {
  echo "herdr: $(_h_base "$1") is not the pane this target was made for, or cannot be read, so nothing was done to it" >&2
  return 1
}

_h_expected_bin() {
  # The harness binary, derived from the rendered command line by skipping the
  # env prefix, its options and any VAR=value assignments. Used as the
  # submission proof. Every hand's line opens `env -u HERDR_WORKSPACE_ID ...`,
  # so an option, and the variable name -u or --unset takes, is never the
  # binary: taking `-u` once made every herdr launch fail its own proof. A
  # stdin-mode line pipes its prompt in, so only what follows the last ` | ` is
  # read. Into an array, never `for tok in $1`, so a glob is not expanded.
  # A value quoted with a space in it spans tokens: an odd count of unescaped
  # single quotes opens it and the next odd one closes it.
  local tok inenv='' skip='' inq='' q toks
  read -r -a toks <<< "${1##* | }"
  for tok in ${toks[@]+"${toks[@]}"}; do
    q=${tok//\\\'/}; q=${q//[!\']/}
    if [ -n "$inq" ]; then [ $(( ${#q} % 2 )) -eq 1 ] && inq=''; continue; fi
    if [ -n "$skip" ]; then skip=''; continue; fi
    case $tok in
      env) inenv=1; continue ;;
      *=*) [ $(( ${#q} % 2 )) -eq 1 ] && inq=1; continue ;;
    esac
    if [ -n "$inenv" ]; then
      case $tok in
        -u|--unset|-C|--chdir) skip=1; continue ;;
        -*) continue ;;
      esac
    fi
    basename -- "$tok"; return 0
  done
  return 1
}

_h_foreground_has() {
  local pane=$1 want=$2
  _h pane process-info --pane "$pane" \
    | jq -r '.result.process_info.foreground_processes[]?.name // empty' 2>/dev/null \
    | grep -qx -- "$want"
}

reeve_backend_herdr_launch() {
  local target=$1 cmdline=$2 pane want i
  pane=$(_h_pane "$target")

  # `pane run` is text plus Enter, atomically. Using it rather than `agent start`
  # keeps the command line entirely in the harness layer's hands: the backend
  # supplies a place to run, not a policy about what runs.
  #
  # But submission is NOT reliable on its own. Enter does not always take, and
  # the failure is silent and intermittent: the command sits unsubmitted at the
  # prompt while every call reports success. Compare herdr #2422, which is the
  # same defect in `agent prompt --wait`. So submission has to be PROVEN, and
  # the proof is the harness process appearing in the pane's foreground.
  #
  # On a retry we press Enter again and never retype: retyping would duplicate
  # the command line if the first submission actually did land.
  _h pane run "$pane" "$cmdline" >/dev/null || return 1

  want=$(_h_expected_bin "$cmdline") || return 0   # cannot prove it, do not block on it
  [ -n "$want" ] || return 0
  i=0
  while [ "$i" -lt 20 ]; do
    _h_foreground_has "$pane" "$want" && return 0
    i=$((i + 1))
    # a shell still running its startup files swallows early input, so give the
    # first few cycles time before nudging
    [ "$i" -eq 4 ] || [ "$i" -eq 10 ] || [ "$i" -eq 16 ] && _h pane send-keys "$pane" enter >/dev/null 2>&1
    sleep 1
  done
  echo "herdr: launched into $pane but '$want' never reached the foreground; the command may be sitting unsubmitted" >&2
  return 1
}

reeve_backend_herdr_capture() {
  local target=$1 lines=${2:-200}
  # Two things here, both learned the hard way:
  #  - `pane read` prints PLAIN TEXT, not the JSON-RPC envelope the list and get
  #    commands print. Piping it through jq silently yields nothing.
  #  - it returns empty when lines is below the viewport height, so never ask
  #    for fewer than 200 and trim locally instead.
  [ "$lines" -ge 200 ] 2>/dev/null || lines=200
  _h_verified "$target" || return 1
  _h pane read "$(_h_pane "$target")" --source recent-unwrapped --lines "$lines" --format text
}

reeve_backend_herdr_send_text_submit() {
  local target=$1 text=$2 pane
  pane=$(_h_pane "$target")
  _h_verified "$target" || { _h_refuse "$target"; return 1; }
  # `agent prompt --wait` is deliberately not used: it can return success while
  # the text still sits unsubmitted in the composer (herdr #2422). pane run at
  # least submits atomically. For an agent already running there is no process
  # transition to watch, so confirmation here is best effort by design, and the
  # caller must treat the durable record as the delivery rather than this call.
  _h pane run "$pane" "$text" >/dev/null || return 1
}

reeve_backend_herdr_target_exists() {
  local doc
  doc=$(_h pane get "$(_h_pane "$1")") || return 1
  printf '%s' "$doc" | jq -e '.result.pane.pane_id // .result.pane_id' >/dev/null 2>&1 || return 1
  _h_verified "$1" "$doc"
}

reeve_backend_herdr_pane_gone() {
  # Optional. <pane id> <socket>: 0 only when the server on that socket answers
  # that the pane is not there. Asked of the session listening on THAT socket,
  # never the one _h talks to, since pane ids are per server. A socket no
  # listed session has, or any other error, is not proof, so it is a no.
  local pane=$1 sock=${2:-} ses out
  [ -n "$pane" ] && [ -n "$sock" ] || return 1
  ses=$(herdr session list --json 2>/dev/null \
    | jq -r --arg s "$sock" '.sessions[]? | select(.socket_path == $s) | .name // empty' 2>/dev/null | head -1)
  [ -n "$ses" ] || return 1
  # herdr writes its error envelope to stderr, not stdout (0.9.0), so that is
  # the stream read once the call has failed.
  out=$(herdr pane get "$pane" --session "$ses" 2>&1 >/dev/null) && return 1
  [ "$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)" = pane_not_found ]
}

# The harness names agent_state believes, one place for both callers below.
# A native claude install runs a binary named for its version, `2.1.3`, which is
# the name the process table shows: a harness too.
_h_harness_re='^(claude|codex|opencode|cursor-agent|grok|gemini|pi|node|bun|[0-9]+(\.[0-9]+)+)$'

reeve_backend_herdr_pane_vacant() {
  # Optional. <pane id> <socket>: 0 only when the server on that socket answers
  # that the pane is gone, or that it runs no harness: a reeve that crashed
  # leaves its shell behind. A pane whose processes cannot be read is not
  # proof, so it is a no, like any error.
  local pane=$1 sock=${2:-} ses procs
  reeve_backend_herdr_pane_gone "$pane" "$sock" && return 0
  [ -n "$pane" ] && [ -n "$sock" ] || return 1
  ses=$(herdr session list --json 2>/dev/null \
    | jq -r --arg s "$sock" '.sessions[]? | select(.socket_path == $s) | .name // empty' 2>/dev/null | head -1)
  [ -n "$ses" ] || return 1
  procs=$(herdr pane process-info --pane "$pane" --session "$ses" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[]?.name // empty' 2>/dev/null)
  [ -n "$procs" ] || return 1
  ! printf '%s\n' "$procs" | grep -qiE "$_h_harness_re"
}

reeve_backend_herdr_group_gone() {
  # Optional. <target>: 0 only when the target opened inside a group, its
  # reeve's workspace, and the server answers that workspace is gone. Closing a
  # reeve's workspace closes every hand tab in it, and this is how the sentry
  # says so instead of only that each one vanished.
  local tab ws out
  tab=$(_h_tab "$1"); [ -n "$tab" ] || return 1
  ws=$(_h_ws "$1"); [ -n "$ws" ] || return 1
  out=$(herdr workspace get "$ws" --session "$(_h_session)" 2>&1 >/dev/null) && return 1
  [ "$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)" = workspace_not_found ]
}

reeve_backend_herdr_agent_state() {
  local target=$1 pane native procs doc
  pane=$(_h_pane "$target")

  if ! doc=$(_h pane get "$pane"); then
    # Distinguish "definitely gone" from "could not read". A transient read
    # failure must never be reported as dead: a false dead is what launches a
    # second hand onto a live worktree.
    if herdr status server --json >/dev/null 2>&1; then echo missing; else echo unreadable; fi
    return 0
  fi
  # A pane under the same id that is provably not the one made for this target
  # is someone else's: this one is gone. One whose identity cannot be read is
  # judged as before.
  _h_verified "$target" "$doc"; [ $? -eq 1 ] && { echo missing; return 0; }

  native=$(_h agent get "$pane" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  procs=$(_h pane process-info --pane "$pane" \
            | jq -r '.result.process_info.foreground_processes[]?.name // empty' 2>/dev/null)

  # Two independent name sources, and either one naming a harness is enough for
  # alive. herdr keeps a stale agent registration after the process exits to a
  # shell, so a registration alone is not believed; but the process table alone
  # is not required either, because it can be unreadable.
  if printf '%s\n' "$procs" | grep -qiE "$_h_harness_re"; then
    echo alive; return 0
  fi
  if [ -n "$native" ] && [ -n "$procs" ]; then
    # registered, but nothing harness shaped in the foreground: it fell back to a shell
    echo dead; return 0
  fi
  if [ -n "$native" ]; then echo alive; return 0; fi
  if [ -z "$procs" ]; then echo unreadable; return 0; fi
  echo dead
}

_h_attn_from_explain() {
  # One `agent explain` document in, one word out. Separate from the call that
  # fetches it so the mapping can be tested against a captured document.
  local e=$1 st box
  [ -n "$e" ] || { echo unknown; return 0; }
  st=$(printf '%s' "$e"  | jq -r '.state // empty' 2>/dev/null)
  box=$(printf '%s' "$e" | jq -r '[.evaluated_rules[]? | select(.id == "live_prompt_box") | .matched] | first // false' 2>/dev/null)

  # There is no single native field that separates the three conditions, because
  # a dialog claude paints as a full screen overlay leaves the agent looking
  # exactly like one that finished its turn: state idle, and no blocked rule
  # matched at all. The pair does separate them. live_prompt_box matching means
  # the composer is on screen with nothing over it, so an idle agent there is
  # simply finished; idle with no composer means something is covering it,
  # whatever that something is. Mapping both a visible blocker and a covered
  # composer to one word is deliberate: the household polices the invariant that
  # a hand reporting `working` has a session that is working, and does not need
  # to know which dialog it was to say so.
  case $st in
    working)   echo working ;;
    blocked)   echo waiting ;;
    idle|done) if [ "$box" = true ]; then echo settled; else echo waiting; fi ;;
    *)         echo unknown ;;
  esac
}

reeve_backend_herdr_attention_state() {
  local target=$1 pane e
  pane=$(_h_pane "$target")
  _h_verified "$target" || { echo unknown; return 0; }

  # Read `agent explain`, never `agent get`. agent_status is a LATCH: it was
  # measured reading `done` while the pane was visibly suspended at a consent
  # dialog, because nothing had transitioned since the last turn ended. explain
  # recomputes from the live screen, and costs one call.
  e=$(_h agent explain "$pane" --json) || { echo unknown; return 0; }
  _h_attn_from_explain "$e"
}

reeve_backend_herdr_wait_change() {
  local target=$1 timeout=${2:-15000} pane
  pane=$(_h_pane "$target")
  # Bounded native wait. Never waits on "idle": herdr reports idle and done
  # mid-turn (#3530), so idle is not evidence a hand stopped. Only blocked and
  # done are worth a wake, and even those are cross-checked by the caller
  # against the status file, which is the actual contract.
  #
  # Both of those states are LATCHED, so once a pane is in one this returns 0
  # instantly and goes on doing so. That is correct here and a trap for the
  # caller: a caller that treats every 0 as "time has passed" spins. The sentry
  # owns that, by sleeping whenever the wait did not actually spend time.
  if _h agent wait "$pane" --until blocked --until done --timeout "$timeout" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

reeve_backend_herdr_kill() {
  local target=$1 ws tab
  tab=$(_h_tab "$target")
  # Never close what a reused id now names: a target that cannot be shown to be
  # its own pane is left alone. The pane it was made for is gone anyway.
  _h_verified "$target" || { _h_refuse "$target"; return 1; }
  # A nested hand's target names its reeve's group as the workspace, and that is
  # usually the very workspace the reeve itself runs in. Closing it would kill
  # the reeve and every other hand beside it. So a three field target closes its
  # own tab, else its own pane, and NEVER the workspace. Load bearing.
  if [ -n "$tab" ]; then
    _h tab close "$tab" >/dev/null 2>&1 && return 0
    _h pane close "$(_h_pane "$target")" >/dev/null 2>&1
    return
  fi
  ws=$(_h_ws "$target")
  # Close the whole workspace when we own one, since create_endpoint made it.
  # Never close by label: herdr does not enforce label uniqueness and a label
  # match could be a pane of the liege's own.
  if [ -n "$ws" ]; then
    _h workspace close "$ws" >/dev/null 2>&1 && return 0
  fi
  _h pane close "$(_h_pane "$target")" >/dev/null 2>&1
}

reeve_backend_herdr_label_own() {
  # Optional. The tab this reeve itself runs in shows <label>, its name, so the
  # sidebar's first row says whose it is. Only $HERDR_TAB_ID, the tab herdr put
  # this process in, and only when that id is on the server _h talks to: tab
  # ids are counters per server, so on another one it names a stranger's tab.
  # Never from a hand (REEVE_HAND): the tab a hand sits in is its own, labelled
  # for its office. Never any other tab.
  local tab=${HERDR_TAB_ID:-} sock
  [ -z "${REEVE_HAND:-}" ] || { echo "herdr: a hand never labels its tab with a reeve's name" >&2; return 1; }
  [ -n "$tab" ] || { echo "herdr: no HERDR_TAB_ID, so no tab of this reeve's to label" >&2; return 1; }
  sock=$(_h_sock)
  if [ -z "$sock" ] || [ "$sock" != "${HERDR_SOCKET_PATH:-}" ]; then
    echo "herdr: tab $tab is not on the server this backend talks to, so it was not labelled" >&2; return 1
  fi
  _h tab get "$tab" >/dev/null || { echo "herdr: tab $tab cannot be read, so it was not labelled" >&2; return 1; }
  _h tab rename "$tab" "$1" >/dev/null
}

reeve_backend_herdr_relabel() {
  # Optional. Renames the tab or workspace create_endpoint made, found by the id
  # in the target and never by its old label. A nested hand renames its tab
  # only: the workspace is its reeve's, named for the reeve. The label is one
  # argument whatever it holds; herdr answers with JSON nobody here reads.
  #
  # The label is half the target's identity, so a target that carries one is
  # printed again with the new label in it, for the caller to keep.
  local ws tab; tab=$(_h_tab "$1")
  _h_verified "$1" || { _h_refuse "$1"; return 1; }
  if [ -n "$tab" ]; then _h tab rename "$tab" "$2" >/dev/null || return 1
  else
    ws=$(_h_ws "$1")
    [ -n "$ws" ] || return 1
    _h workspace rename "$ws" "$2" >/dev/null || return 1
  fi
  _h_want "$1" >/dev/null && printf '%sl%s\n' "${1%l*}" "$(_h_sum "$2")"
  return 0
}
