#!/usr/bin/env bash
# tmux backend. Second implementation, and deliberately the minimal honest one.
#
# It exists to keep the backend contract real rather than decorative: a seam
# with a single implementation is not a seam. Where tmux genuinely cannot do
# something (push events, confirmed submission) it says so instead of pretending.

_t_session() { printf '%s\n' "${REEVE_TMUX_SESSION:-reeve}"; }
# "<ses>|@3" -> "<ses>:@3". A target may end `#<identity>`, which is not part of it.
_t_target()  { local b=${1%%#*}; printf '%s\n' "${b%%|*}:${b#*|}"; }

# A window's identity is its server's start time and its first pane's pid,
# `<start_time>.<pane_pid>`. Window ids restart at @0 on every server, and the
# session a hand opens in is now the reeve's own, which the liege recreates
# under the same name, so after a restart `<ses>|@3` names someone else's
# window. Read from the full pane list, never `display -t`, which was measured
# answering for the current pane when the target window does not exist.
_t_ident() { # _t_ident <window id>
  tmux list-panes -a -F '#{window_id} #{start_time}.#{pane_pid}' 2>/dev/null \
    | awk -v w="$1" '$1 == w { print $2; exit }'
}

# _t_verified <target>   0 when it carries no identity, or its window still
# shows it, or no window by that id is there to ask (the callers' own checks
# then find it missing, as before). 1 is a different window under the same id.
_t_verified() {
  local want have b
  case $1 in *'#'*) want=${1##*#} ;; *) return 0 ;; esac
  b=${1%%#*}
  have=$(_t_ident "${b#*|}")
  [ -z "$have" ] || [ "$have" = "$want" ]
}

_t_refuse() {
  echo "tmux: $(_t_target "$1") is not the window this target was made for, so nothing was done to it" >&2
  return 1
}

# A native claude install runs a binary named for its version, `2.1.3`, which is
# the name the process table shows: a harness too.
_t_harness_re='^(claude|codex|opencode|cursor-agent|grok|gemini|pi|node|bun|[0-9]+(\.[0-9]+)+)$'

reeve_backend_tmux_available() {
  command -v tmux >/dev/null 2>&1 || { echo "tmux not on PATH" >&2; return 1; }
  return 0
}

reeve_backend_tmux_describe() { printf 'tmux %s (session %s)\n' "$(tmux -V | awk '{print $2}')" "$(_t_session)"; }

reeve_backend_tmux_ensure_group() {
  # Optional. The session a reeve's hands open in as windows. $REEVE_TMUX_SESSION
  # when the liege set one, as before. Else the session the reeve itself runs in,
  # where the reeve's OWN window takes its name; the session keeps the liege's
  # name, which other windows may be relying on. Else a detached session named
  # for the reeve. A known id, the detached session an earlier call made under
  # an older name, is renamed to the new one rather than left beside it; only
  # a `reeve-*` session, never one the liege named.
  #
  # Every argument after the known id is a session another live reeve holds,
  # and one reeve per session: a held one is neither renamed in nor nested into,
  # and the reeve gets its own. A hand (REEVE_HAND, set by dispatch) never takes
  # the session it sits in, which is its reeve's.
  #
  # REEVE_GROUP_KEEP says the known session still holds hands of this reeve's,
  # so a reeve that moved keeps sending hands there while any are left.
  local label=$1 known=${2:-} ses='' win h
  shift; [ $# -gt 0 ] && shift
  if [ -n "${REEVE_TMUX_SESSION:-}" ]; then
    ses=$REEVE_TMUX_SESSION
  elif [ -n "${REEVE_GROUP_KEEP:-}" ] && [ -n "$known" ] && tmux has-session -t "=$known" 2>/dev/null \
       && ! _t_held "$known" "$@"; then
    ses=$known
  elif [ -n "${TMUX_PANE:-}" ] && [ -z "${REEVE_HAND:-}" ]; then
    ses=$(tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || ses=''
    win=$(tmux display -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null) || win=''
    for h in "$@"; do
      [ -n "$ses" ] && [ "$h" = "$ses" ] || continue
      echo "tmux: session $ses belongs to another live reeve, so $label gets a session of its own" >&2
      ses=''; break
    done
    if [ -n "$ses" ] && [ -n "$win" ]; then
      tmux rename-window -t "$win" "$label" 2>/dev/null || :
      tmux set-window-option -t "$win" automatic-rename off >/dev/null 2>&1 || :
    fi
  fi
  if [ -z "$ses" ]; then
    ses="reeve-$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
    case $known in
      reeve-?*)
        for h in "$@"; do [ "$h" = "$known" ] && known=''; done
        if [ -n "$known" ] && [ "$known" != "$ses" ] && tmux has-session -t "=$known" 2>/dev/null \
           && ! tmux has-session -t "=$ses" 2>/dev/null; then
          tmux rename-session -t "=$known" "$ses" 2>/dev/null && { printf '%s\n' "$ses"; return 0; }
        fi ;;
    esac
    tmux has-session -t "=$ses" 2>/dev/null \
      || tmux new-session -d -s "$ses" -c "${HOME:-$PWD}" || return 1
  fi
  printf '%s\n' "$ses"
}

_t_held() { local k=$1 h; shift; for h in "$@"; do [ "$h" = "$k" ] && return 0; done; return 1; }

reeve_backend_tmux_pane_gone() {
  # Optional. <pane id> <socket>: 0 only when the server on that socket lists
  # its panes and that one is not among them. Pane ids restart at %0 on every
  # server, so it is asked of that socket only. `display -t` on a missing pane
  # was measured printing nothing and exiting 0 on tmux 3.7b, so the list is the
  # proof instead. A server that does not answer is not proof, so it is a no.
  #
  # The socket may end `#<epoch>`, the server's start time when the key was
  # made. A server answering with another start time is another server, so
  # every pane of the old one is gone, whatever ids the new one reuses.
  local pane=$1 sock=${2:-} ep='' out
  case $sock in *'#'*) ep=${sock##*#}; sock=${sock%#*} ;; esac
  [ -n "$pane" ] && [ -n "$sock" ] || return 1
  out=$(tmux -S "$sock" list-panes -a -F '#{pane_id} #{start_time}' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  if [ -n "$ep" ]; then
    [ "$(printf '%s\n' "$out" | awk 'NR == 1 { print $2 }')" = "$ep" ] || return 0
  fi
  ! printf '%s\n' "$out" | awk '{ print $1 }' | grep -qxF -- "$pane"
}

reeve_backend_tmux_pane_vacant() {
  # Optional. <pane id> <socket[#epoch]>: 0 only when that server answers that
  # the pane is gone, or that it runs no harness. Not proof otherwise.
  local pane=$1 sock=${2:-} cmd
  reeve_backend_tmux_pane_gone "$pane" "$sock" && return 0
  sock=${sock%#*}
  [ -n "$pane" ] && [ -n "$sock" ] || return 1
  cmd=$(tmux -S "$sock" list-panes -a -F '#{pane_id} #{pane_current_command}' 2>/dev/null \
    | awk -v p="$pane" '$1 == p { print $2; exit }')
  [ -n "$cmd" ] || return 1
  ! printf '%s\n' "$cmd" | grep -qiE "$_t_harness_re"
}

reeve_backend_tmux_group_gone() {
  # Optional. <target>: 0 only when the server answers and the session the
  # hand's window was in is not among its sessions. Closing a reeve's session
  # closes every hand window in it.
  local b=${1%%#*} out
  out=$(tmux list-sessions -F '#{session_name}' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  ! printf '%s\n' "$out" | grep -qxF -- "${b%%|*}"
}

reeve_backend_tmux_create_endpoint() {
  # The group, when given, is the session ensure_group printed. The target
  # format is the same either way: a window is a window.
  local cwd=$1 label=$2 ses=${3:-} win id
  [ -d "$cwd" ] || { echo "cwd does not exist: $cwd" >&2; return 1; }
  [ -n "$ses" ] || ses=$(_t_session)
  tmux has-session -t "$ses" 2>/dev/null || tmux new-session -d -s "$ses" -c "$cwd" || return 1
  # automatic-rename off so a hand's own cd cannot break name based targeting
  win=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$label" -c "$cwd") || return 1
  tmux set-window-option -t "$ses:$win" automatic-rename off >/dev/null 2>&1 || :
  tmux set-window-option -t "$ses:$win" allow-rename off    >/dev/null 2>&1 || :
  id=$(_t_ident "$win")
  printf '%s|%s%s\n' "$ses" "$win" "${id:+#$id}"
}

reeve_backend_tmux_launch() {
  tmux send-keys -t "$(_t_target "$1")" "$2" Enter
}

reeve_backend_tmux_capture() {
  local lines=${2:-200}
  _t_verified "$1" || return 1
  tmux capture-pane -p -J -t "$(_t_target "$1")" -S "-$lines" 2>/dev/null
}

reeve_backend_tmux_send_text_submit() {
  local target tgt=$1 text=$2 tail_now
  target=$(_t_target "$tgt")
  _t_verified "$tgt" || { _t_refuse "$tgt"; return 1; }
  tmux send-keys -t "$target" "$text" Enter || return 1
  sleep 1
  # tmux has no notion of a composer, so confirmation is best effort: if the
  # literal text is still the last thing on screen, Enter did not take. Retry
  # Enter once, never retype, then report honestly.
  tail_now=$(tmux capture-pane -p -t "$target" -S -3 2>/dev/null | grep -c -- "$text" 2>/dev/null || echo 0)
  if [ "${tail_now:-0}" -gt 0 ]; then
    tmux send-keys -t "$target" Enter || return 1
    sleep 1
    tail_now=$(tmux capture-pane -p -t "$target" -S -3 2>/dev/null | grep -c -- "$text" 2>/dev/null || echo 0)
    [ "${tail_now:-0}" -eq 0 ] || return 1
  fi
  return 0
}

reeve_backend_tmux_target_exists() {
  local tgt=${1%%#*} ses win
  ses=${tgt%%|*}; win=${tgt#*|}
  tmux list-windows -t "$ses" -F '#{window_id}' 2>/dev/null | grep -qx -- "$win" || return 1
  _t_verified "$1"
}

reeve_backend_tmux_agent_state() {
  local tgt=$1 target cmd
  target=$(_t_target "$tgt")
  if ! tmux has-session -t "${tgt%%|*}" 2>/dev/null; then echo missing; return 0; fi
  # target_exists checks the identity too: another window under the same id
  # is missing, never alive.
  reeve_backend_tmux_target_exists "$tgt" || { echo missing; return 0; }
  cmd=$(tmux list-panes -t "$target" -F '#{pane_current_command}' 2>/dev/null | head -1)
  [ -n "$cmd" ] || { echo unreadable; return 0; }
  if printf '%s\n' "$cmd" | grep -qiE "$_t_harness_re"; then echo alive; else echo dead; fi
}

_t_attn_from_text() {
  # Captured pane text in, one word out, with no herdr and no server. Two
  # conditions, deliberately, and no more: the cancel footer every dialog
  # carries, AND the absence of an empty composer prompt on a line of its own.
  #
  # The AND is load bearing. A hand writing ABOUT permission prompts puts that
  # footer in its own scrollback, and its composer is still there underneath, so
  # either half alone reports a working hand as stuck.
  #
  # It cannot tell `working` from `settled`, because without the OSC title
  # nothing in the text says which, so it answers `unknown` rather than
  # guessing. That is enough for what the sentry polices, which only ever acts
  # on `waiting`.
  #
  # Here-strings, not pipes into grep: `... | grep -q` closes the pipe on the
  # first match, the writer takes EPIPE, and pipefail then reports the whole
  # pipeline failed, so a pattern that DID match reads as no match.
  local text=$1
  if grep -qEi 'esc to cancel|\(esc\)' <<<"$text" \
     && ! grep -qE '^[[:space:]]*(>|❯)[[:space:]]*$' <<<"$text"; then
    echo waiting
  else
    echo unknown
  fi
}

reeve_backend_tmux_attention_state() {
  local tgt=$1 target text st box e
  target=$(_t_target "$tgt")
  reeve_backend_tmux_target_exists "$tgt" || { echo unknown; return 0; }
  text=$(tmux capture-pane -p -J -t "$target" -S -200 2>/dev/null)
  [ -n "$text" ] || { echo unknown; return 0; }

  # The asymmetry with herdr is real and not an oversight, so it is written down
  # rather than left to be discovered. Under tmux there is nothing to ask but
  # the pane's text. Measured: pane_current_command is the harness binary in
  # every condition, working or suspended, and #{pane_title} carries claude's OSC
  # title but never the working glyph, because that glyph is herdr's own
  # composition of an OSC progress region tmux has no format variable for. So the
  # highest priority rule in the herdr scheme has no tmux equivalent, and
  # `working` cannot be recognised positively here at all.
  #
  # Preferred path: hand the captured text to herdr's own classifier, which reads
  # a file and needs no server, so the regexes stay in the manifest herdr updates
  # rather than in this repository. An optimisation, never a requirement: the
  # point of this backend is to work where herdr is not.
  #
  # A target says nothing about which harness is in it, so both paths are asked
  # in claude's terms. On another harness they answer `unknown` rather than
  # guessing, which is the safe direction.
  if command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    e=$(herdr agent explain --file /dev/stdin --agent claude --json 2>/dev/null <<<"$text")
    if [ -n "$e" ]; then
      st=$(printf '%s' "$e"  | jq -r '.state // empty' 2>/dev/null)
      box=$(printf '%s' "$e" | jq -r '[.evaluated_rules[]? | select(.id == "live_prompt_box") | .matched] | first // false' 2>/dev/null)
      case $st in
        working)   echo working; return 0 ;;
        blocked)   echo waiting; return 0 ;;
        idle|done) if [ "$box" = true ]; then echo settled; else echo waiting; fi; return 0 ;;
      esac
    fi
  fi

  _t_attn_from_text "$text"
}

reeve_backend_tmux_wait_change() {
  # tmux has no push event source. Exit 2 is the honest answer: it tells the
  # sentry to fall back to polling rather than pretending to have waited.
  return 2
}

# Never a window a reused id now names: the one this target was made for is gone.
reeve_backend_tmux_kill() {
  _t_verified "$1" || { _t_refuse "$1"; return 1; }
  tmux kill-window -t "$(_t_target "$1")" 2>/dev/null
}

# Optional. automatic-rename is off on every window create_endpoint made, so the
# new name holds.
reeve_backend_tmux_relabel() {
  _t_verified "$1" || { _t_refuse "$1"; return 1; }
  tmux rename-window -t "$(_t_target "$1")" "$2" 2>/dev/null
}
