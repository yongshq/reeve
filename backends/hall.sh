#!/usr/bin/env bash
# hall backend. hall is a multiplexer forked from herdr, kept apart from it so
# a change in one never reaches the other, and its CLI keeps herdr's commands
# and JSON. So this is a copy of herdr.sh that speaks only to hall: every
# constraint herdr.sh explains at its site holds here for the same reason, and
# the notes are kept where they still apply.
#
# What differs is how the server is found, and that is load bearing:
#
#  - The binary is hall's own: $HALL_BIN_PATH, which hall sets into its panes,
#    else $REEVE_HALL_BIN, else config/hall-bin, else `hall` on PATH. Never
#    `herdr` and never the herdr binary variable herdr sets: a call that reached
#    herdr's server would act on panes that are not hall's.
#  - Every call names its server by socket, $HALL_SOCKET_PATH, never by
#    --session. A session flag beats the socket, and a hall run with a config
#    folder of its own resolves session names from that folder, so a name can
#    reach another server where a socket cannot.
#  - Nothing here reads HERDR_*. hall sets those into its panes too, beside its
#    own; which backend a reeve uses is REEVE_BACKEND's question, not theirs.

# _hb   the hall binary, or nothing and rc 1
_hb() {
  local b=${HALL_BIN_PATH:-${REEVE_HALL_BIN:-}}
  if [ -z "$b" ] && command -v config_get >/dev/null 2>&1; then b=$(config_get hall-bin ''); fi
  [ -n "$b" ] || b=$(command -v hall 2>/dev/null) || b=''
  [ -n "$b" ] || return 1
  printf '%s\n' "$b"
}

# _h_at <socket> <args...>   one hall call, addressed to the server on <socket>.
# The session variables a hall pane carries are taken away, so nothing but the
# socket picks the server.
_h_at() {
  local sock=$1 b; shift
  b=$(_hb) || { echo "hall: binary not found, set REEVE_HALL_BIN or config/hall-bin" >&2; return 1; }
  env -u HALL_SESSION -u HALL_CLIENT_SOCKET_PATH HALL_SOCKET_PATH="$sock" "$b" "$@"
}

# _h_sessions   hall's session list, one JSON array, or nothing
_h_sessions() {
  local b; b=$(_hb) || return 0
  env -u HALL_SESSION -u HALL_CLIENT_SOCKET_PATH -u HALL_SOCKET_PATH "$b" session list --json 2>/dev/null \
    | jq -c 'if type == "array" then . else (.sessions // []) end' 2>/dev/null
}

# _h_sock   the socket of the server _h talks to, or nothing. $REEVE_HALL_SOCKET,
# else $HALL_SOCKET_PATH, which hall sets into its own panes, else the default
# session hall lists.
_h_sock() {
  if [ -n "${REEVE_HALL_SOCKET:-}" ]; then printf '%s\n' "$REEVE_HALL_SOCKET"; return; fi
  if [ -n "${HALL_SOCKET_PATH:-}" ]; then printf '%s\n' "$HALL_SOCKET_PATH"; return; fi
  _h_sessions | jq -r '.[]? | select(.default == true) | .socket_path // empty' 2>/dev/null | head -1
}

# _h_place   the name of the session _h talks to, for the listing. A socket
# from the environment is in $HALL_SESSION's session, which hall leaves unset
# for its default one. Else the default session hall lists.
_h_place() {
  if [ -n "${REEVE_HALL_SESSION:-}" ]; then printf '%s\n' "$REEVE_HALL_SESSION"; return; fi
  if [ -n "${REEVE_HALL_SOCKET:-}${HALL_SOCKET_PATH:-}" ]; then printf '%s\n' "${HALL_SESSION:-default}"; return; fi
  _h_sessions | jq -r '.[]? | select(.default == true) | .name // empty' 2>/dev/null | head -1
}

_h() {
  # Every call names its server, as herdr.sh's does, by socket here: picking
  # the wrong server means mutating panes that belong to someone else's work.
  local sock
  sock=$(_h_sock)
  [ -n "$sock" ] || { echo "hall: no running server found" >&2; return 1; }
  _h_at "$sock" "$@" 2>/dev/null
}

# A target is "<workspace_id>|<pane_id>" for a hand in a workspace of its own,
# or "<workspace_id>|<pane_id>|<tab_id>" for one opened as a tab inside its
# reeve's workspace, the grammar herdr.sh uses, with its identity suffix
# `#c<n>l<m>`: herdr.sh says why each part is there.
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

# _h_verified <target> [<pane get document>]   herdr.sh's identity check: 0 when
# the target carries no identity or its pane still shows it, 1 a different
# pane under the same id, 2 a pane that could not be read.
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

reeve_backend_hall_available() {
  local b sock
  b=$(_hb) || { echo "hall binary not found: set REEVE_HALL_BIN or config/hall-bin" >&2; return 1; }
  command -v "$b" >/dev/null 2>&1 || { echo "hall binary not found at $b: set REEVE_HALL_BIN or config/hall-bin" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "jq not on PATH, required to parse hall output" >&2; return 1; }
  sock=$(_h_sock)
  [ -n "$sock" ] || { echo "hall server not running: no socket set and no default session listed" >&2; return 1; }
  _h status server --json >/dev/null 2>&1 || { echo "hall server not running at $sock" >&2; return 1; }
  return 0
}

reeve_backend_hall_describe() {
  local b; b=$(_hb) || b=''
  printf 'hall %s (session %s)\n' "$([ -n "$b" ] && "$b" --version 2>/dev/null | awk '{print $NF}')" "$(_h_place)"
}

# Optional. The name of the session this backend talks to, for the listing,
# which shows only hall's own and must not take another server's pane ids for
# its own.
reeve_backend_hall_place() {
  local n; n=$(_h_place)
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# A group id is `<workspace id>@<socket>`, as herdr.sh's: ids are counters per
# server, so a bare w5 names some other workspace on another one.
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

reeve_backend_hall_ensure_group() {
  # Optional. herdr.sh's rules, whole: the reeve's own workspace first, when it
  # runs inside hall on this same server; then the known one; then a fresh one.
  # A held id is never renamed, nested into or reused, a hand never takes the
  # workspace it sits in, and REEVE_GROUP_KEEP prefers the known group.
  local label=$1 known=${2:-} ws out sock cur
  shift; [ $# -gt 0 ] && shift
  sock=$(_h_sock)
  [ -n "$sock" ] || echo "hall: no server socket found, so no workspace can be reused and $label gets a new one" >&2
  if [ -n "${REEVE_GROUP_KEEP:-}" ] && out=$(_h_known_group "$label" "$known" "$sock" "$@" 2>/dev/null); then
    printf '%s\n' "$out"; return 0
  fi
  ws=${HALL_WORKSPACE_ID:-}
  if [ -n "$ws" ] && [ -z "${REEVE_HAND:-}" ] && [ -n "$sock" ] && [ "$sock" = "${HALL_SOCKET_PATH:-}" ] \
     && _h workspace get "$ws" >/dev/null; then
    if _h_held "$ws" "$sock" "$@"; then
      echo "hall: workspace $ws belongs to another live reeve, so $label gets a workspace of its own" >&2
    else
      _h workspace rename "$ws" "$label" >/dev/null || :
      printf '%s@%s\n' "$ws" "$sock"; return 0
    fi
  fi
  _h_known_group "$label" "$known" "$sock" "$@" && return 0
  out=$(_h workspace create --cwd "${HOME:-$PWD}" --label "$label" --no-focus) || return 1
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // .result.workspace_id // empty' 2>/dev/null)
  [ -n "$ws" ] || { echo "hall: workspace create returned no id" >&2; return 1; }
  printf '%s%s\n' "$ws" "${sock:+@$sock}"
}

# _h_known_group <label> <known> <sock> <held...>   print the known group and
# rc 0 when it may be reused: on this server, held by nobody, still there, and
# still showing this name or one this reeve's records held.
_h_known_group() {
  local label=$1 known=$2 sock=$3 ws='' cur
  shift 3
  case $known in *@*) [ -n "$sock" ] && [ "${known#*@}" = "$sock" ] && ws=$(_h_gid "$known") ;; esac
  [ -n "$ws" ] && ! _h_held "$ws" "$sock" "$@" && cur=$(_h workspace get "$ws") || return 1
  cur=$(printf '%s' "$cur" | jq -r '.result.workspace.label // empty' 2>/dev/null)
  if [ "$cur" = "$label" ]; then
    printf '%s@%s\n' "$ws" "$sock"; return 0
  fi
  if [ -n "$cur" ] && _h_name_was "$cur" ${REEVE_GROUP_NAMES:-}; then
    _h workspace rename "$ws" "$label" >/dev/null || :
    printf '%s@%s\n' "$ws" "$sock"; return 0
  fi
  echo "hall: workspace $ws now shows '$cur', not a name of this reeve, so $label gets a new one" >&2
  return 1
}

reeve_backend_hall_create_endpoint() {
  local cwd=$1 label=$2 group out ws pane tab
  group=$(_h_gid "${3:-}")   # the workspace, without the socket ensure_group checked
  [ -d "$cwd" ] || { echo "cwd does not exist: $cwd" >&2; return 1; }

  # Every pane made here is marked --no-agent-resume: a hall restart drops it,
  # and a tab or workspace it leaves empty, rather than starting a bare
  # `claude --resume` in it with none of the hand's environment or flags. The
  # hand's target then no longer resolves, so agent_state reads it missing, the
  # watch says stale and the reeve sends it out again from its brief. The
  # reeve's own pane is never made here, so it resumes as before.
  #
  # With a group, the hand is a tab in its reeve's workspace. Anything missing
  # and the hand gets a workspace of its own instead.
  if [ -n "$group" ]; then
    out=$(_h tab create --workspace "$group" --cwd "$cwd" --label "$label" --no-focus --no-agent-resume) || out=''
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
    echo "hall: could not open a tab in workspace $group, opening a workspace of its own" >&2
    pane=''
  fi

  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    out=$(_h worktree open --path "$cwd" --label "$label" --no-focus --no-agent-resume) || out=''
    ws=$(printf '%s' "$out"   | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty'      2>/dev/null)
  fi

  if [ -z "${pane:-}" ]; then
    out=$(_h workspace create --cwd "$cwd" --label "$label" --no-focus --no-agent-resume) || return 1
    ws=$(printf '%s' "$out"   | jq -r '.result.workspace.workspace_id // .result.workspace_id // empty' 2>/dev/null)
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    if [ -z "$pane" ] && [ -n "$ws" ]; then
      pane=$(_h pane list --workspace "$ws" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null)
    fi
  fi

  [ -n "${pane:-}" ] || { echo "hall: could not obtain a pane for $cwd" >&2; return 1; }
  printf '%s|%s%s\n' "${ws:-}" "$pane" "$(_h_ident "$cwd" "$label")"
}

# _h_ident <dir> <label>   `#c<n>l<m>` for a target made to work in <dir> under
# <label>, from the directory asked for, never read back from the new pane.
_h_ident() {
  local d
  d=$(cd -P "$1" 2>/dev/null && pwd -P) || return 0
  printf '#c%sl%s' "$(_h_sum "$d")" "$(_h_sum "$2")"
}

# _h_refuse <target>   the one message for a target that cannot be shown to be
# the pane it was. rc 1, so the caller acts on nothing.
_h_refuse() {
  echo "hall: $(_h_base "$1") is not the pane this target was made for, or cannot be read, so nothing was done to it" >&2
  return 1
}

# The harness binary behind a rendered command line, herdr.sh's submission
# proof: the env prefix, its options, the variable each -u takes and any
# VAR=value assignments are skipped, and a stdin-mode line is read after its
# last ` | `.
_h_expected_bin() {
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

reeve_backend_hall_launch() {
  local target=$1 cmdline=$2 pane want i
  pane=$(_h_pane "$target")
  # `pane run`, then proof: the harness process in the pane's foreground. Enter
  # does not always take, silently, so submission is proven, and a retry only
  # presses Enter again, never retypes. herdr.sh has the history.
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
  echo "hall: launched into $pane but '$want' never reached the foreground; the command may be sitting unsubmitted" >&2
  return 1
}

reeve_backend_hall_capture() {
  local target=$1 lines=${2:-200}
  # `pane read` prints plain text, not JSON, and returns empty below the
  # viewport height, so never fewer than 200 lines.
  [ "$lines" -ge 200 ] 2>/dev/null || lines=200
  _h_verified "$target" || return 1
  _h pane read "$(_h_pane "$target")" --source recent-unwrapped --lines "$lines" --format text
}

reeve_backend_hall_send_text_submit() {
  local target=$1 text=$2 pane
  pane=$(_h_pane "$target")
  _h_verified "$target" || { _h_refuse "$target"; return 1; }
  # pane run submits atomically; the durable record is the delivery, not this.
  _h pane run "$pane" "$text" >/dev/null || return 1
}

reeve_backend_hall_dismiss_dialog() {
  # Optional. Escape, never Enter, never a typed answer: either could be Allow.
  # The screen is read once more just before the key, and the key goes only if
  # it still reads waiting: rc 3, nothing sent, if not. The server is resolved
  # once, up front, so from that read to the key is one hall spawn.
  local pane a sock
  sock=$(_h_sock)
  local REEVE_HALL_SOCKET=$sock
  pane=$(_h_pane "$1")
  _h_verified "$1" || { _h_refuse "$1"; return 1; }
  a=$(_h_attn_from_explain "$(_h agent explain "$pane" --json)")
  if [ "$a" != waiting ]; then
    echo "hall: $(_h_base "$1") reads $a, not waiting, just before the key, so nothing was sent" >&2
    return 3
  fi
  _h pane send-keys "$pane" esc >/dev/null
}

reeve_backend_hall_target_exists() {
  local doc
  doc=$(_h pane get "$(_h_pane "$1")") || return 1
  printf '%s' "$doc" | jq -e '.result.pane.pane_id // .result.pane_id' >/dev/null 2>&1 || return 1
  _h_verified "$1" "$doc"
}

reeve_backend_hall_pane_gone() {
  # Optional. <pane id> <socket>: 0 only when the server on that socket answers
  # that the pane is not there. Asked of that socket directly, never the server
  # _h talks to, since pane ids are per server. Any other answer, a socket
  # nothing listens on among them, is not proof, so it is a no.
  local pane=$1 sock=${2:-} out
  [ -n "$pane" ] && [ -n "$sock" ] || return 1
  # The error envelope is on stderr, so that is the stream read once the call
  # has failed.
  out=$(_h_at "$sock" pane get "$pane" 2>&1 >/dev/null) && return 1
  [ "$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)" = pane_not_found ]
}

# The harness names agent_state believes, herdr.sh's list.
_h_harness_re='^(claude|codex|opencode|cursor-agent|grok|gemini|pi|node|bun|[0-9]+(\.[0-9]+)+)$'

reeve_backend_hall_pane_vacant() {
  # Optional. <pane id> <socket>: 0 only when the server on that socket answers
  # that the pane is gone, or that it runs no harness. A pane whose processes
  # cannot be read is not proof, so it is a no, like any error.
  local pane=$1 sock=${2:-} procs
  reeve_backend_hall_pane_gone "$pane" "$sock" && return 0
  [ -n "$pane" ] && [ -n "$sock" ] || return 1
  procs=$(_h_at "$sock" pane process-info --pane "$pane" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[]?.name // empty' 2>/dev/null)
  [ -n "$procs" ] || return 1
  ! printf '%s\n' "$procs" | grep -qiE "$_h_harness_re"
}

reeve_backend_hall_group_gone() {
  # Optional. <target>: 0 only when the target opened inside a group and the
  # server answers that workspace is gone.
  local tab ws sock out
  tab=$(_h_tab "$1"); [ -n "$tab" ] || return 1
  ws=$(_h_ws "$1"); [ -n "$ws" ] || return 1
  sock=$(_h_sock); [ -n "$sock" ] || return 1
  out=$(_h_at "$sock" workspace get "$ws" 2>&1 >/dev/null) && return 1
  [ "$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)" = workspace_not_found ]
}

reeve_backend_hall_agent_state() {
  local target=$1 pane native procs doc
  pane=$(_h_pane "$target")

  if ! doc=$(_h pane get "$pane"); then
    # A transient read failure must never be reported as dead: a false dead is
    # what launches a second hand onto a live worktree.
    if _h status server --json >/dev/null 2>&1; then echo missing; else echo unreadable; fi
    return 0
  fi
  _h_verified "$target" "$doc"; [ $? -eq 1 ] && { echo missing; return 0; }

  native=$(_h agent get "$pane" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  procs=$(_h pane process-info --pane "$pane" \
            | jq -r '.result.process_info.foreground_processes[]?.name // empty' 2>/dev/null)

  # Either name source naming a harness is enough for alive; a registration
  # alone with a shell in the foreground is dead. herdr.sh says why.
  if printf '%s\n' "$procs" | grep -qiE "$_h_harness_re"; then
    echo alive; return 0
  fi
  if [ -n "$native" ] && [ -n "$procs" ]; then
    echo dead; return 0
  fi
  if [ -n "$native" ]; then echo alive; return 0; fi
  if [ -z "$procs" ]; then echo unreadable; return 0; fi
  echo dead
}

_h_attn_from_explain() {
  # One `agent explain` document in, one word out, herdr.sh's mapping: idle
  # with no composer on screen means something is covering it.
  local e=$1 st box
  [ -n "$e" ] || { echo unknown; return 0; }
  st=$(printf '%s' "$e"  | jq -r '.state // empty' 2>/dev/null)
  box=$(printf '%s' "$e" | jq -r '[.evaluated_rules[]? | select(.id == "live_prompt_box") | .matched] | first // false' 2>/dev/null)
  case $st in
    working)   echo working ;;
    blocked)   echo waiting ;;
    idle|done) if [ "$box" = true ]; then echo settled; else echo waiting; fi ;;
    *)         echo unknown ;;
  esac
}

reeve_backend_hall_attention_state() {
  local target=$1 pane e
  pane=$(_h_pane "$target")
  _h_verified "$target" || { echo unknown; return 0; }
  # `agent explain`, never `agent get`: agent_status is a latch.
  e=$(_h agent explain "$pane" --json) || { echo unknown; return 0; }
  _h_attn_from_explain "$e"
}

reeve_backend_hall_wait_change() {
  local target=$1 timeout=${2:-15000} pane
  pane=$(_h_pane "$target")
  # Bounded native wait on blocked and done only, both latched: the caller
  # owns not spinning on them.
  if _h agent wait "$pane" --until blocked --until done --timeout "$timeout" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

reeve_backend_hall_kill() {
  local target=$1 ws tab
  tab=$(_h_tab "$target")
  _h_verified "$target" || { _h_refuse "$target"; return 1; }
  # A three field target closes its own tab, else its own pane, and NEVER the
  # workspace, which is its reeve's. Load bearing.
  if [ -n "$tab" ]; then
    _h tab close "$tab" >/dev/null 2>&1 && return 0
    _h pane close "$(_h_pane "$target")" >/dev/null 2>&1
    return
  fi
  ws=$(_h_ws "$target")
  # A workspace create_endpoint made is closed whole. Never by label.
  if [ -n "$ws" ]; then
    _h workspace close "$ws" >/dev/null 2>&1 && return 0
  fi
  _h pane close "$(_h_pane "$target")" >/dev/null 2>&1
}

reeve_backend_hall_label_own() {
  # Optional. Only $HALL_TAB_ID, the tab hall put this process in, and only
  # when that id is on the server _h talks to. Never from a hand. Never any
  # other tab.
  local tab=${HALL_TAB_ID:-} sock
  [ -z "${REEVE_HAND:-}" ] || { echo "hall: a hand never labels its tab with a reeve's name" >&2; return 1; }
  [ -n "$tab" ] || { echo "hall: no HALL_TAB_ID, so no tab of this reeve's to label" >&2; return 1; }
  sock=$(_h_sock)
  if [ -z "$sock" ] || [ "$sock" != "${HALL_SOCKET_PATH:-}" ]; then
    echo "hall: tab $tab is not on the server this backend talks to, so it was not labelled" >&2; return 1
  fi
  _h tab get "$tab" >/dev/null || { echo "hall: tab $tab cannot be read, so it was not labelled" >&2; return 1; }
  _h tab rename "$tab" "$1" >/dev/null
}

reeve_backend_hall_relabel() {
  # Optional. Renames the tab or workspace create_endpoint made, found by id.
  # A nested hand renames its tab only. A target that carries its label in its
  # identity is printed again with the new one.
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
