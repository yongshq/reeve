#!/usr/bin/env bash
# tmux backend. Second implementation, and deliberately the minimal honest one.
#
# It exists to keep the backend contract real rather than decorative: a seam
# with a single implementation is not a seam. Where tmux genuinely cannot do
# something (push events, confirmed submission) it says so instead of pretending.

_t_session() { printf '%s\n' "${REEVE_TMUX_SESSION:-reeve}"; }
_t_target()  { printf '%s\n' "${1%%|*}:${1#*|}"; }   # "<ses>|@3" -> "<ses>:@3"

reeve_backend_tmux_available() {
  command -v tmux >/dev/null 2>&1 || { echo "tmux not on PATH" >&2; return 1; }
  return 0
}

reeve_backend_tmux_describe() { printf 'tmux %s (session %s)\n' "$(tmux -V | awk '{print $2}')" "$(_t_session)"; }

reeve_backend_tmux_create_endpoint() {
  local cwd=$1 label=$2 ses win
  [ -d "$cwd" ] || { echo "cwd does not exist: $cwd" >&2; return 1; }
  ses=$(_t_session)
  tmux has-session -t "$ses" 2>/dev/null || tmux new-session -d -s "$ses" -c "$cwd" || return 1
  # automatic-rename off so a hand's own cd cannot break name based targeting
  win=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$label" -c "$cwd") || return 1
  tmux set-window-option -t "$ses:$win" automatic-rename off >/dev/null 2>&1 || :
  tmux set-window-option -t "$ses:$win" allow-rename off    >/dev/null 2>&1 || :
  printf '%s|%s\n' "$ses" "$win"
}

reeve_backend_tmux_launch() {
  tmux send-keys -t "$(_t_target "$1")" "$2" Enter
}

reeve_backend_tmux_capture() {
  local lines=${2:-200}
  tmux capture-pane -p -J -t "$(_t_target "$1")" -S "-$lines" 2>/dev/null
}

reeve_backend_tmux_send_text_submit() {
  local target tgt=$1 text=$2 tail_now
  target=$(_t_target "$tgt")
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
  local tgt=$1 ses win
  ses=${tgt%%|*}; win=${tgt#*|}
  tmux list-windows -t "$ses" -F '#{window_id}' 2>/dev/null | grep -qx -- "$win"
}

reeve_backend_tmux_agent_state() {
  local tgt=$1 target cmd
  target=$(_t_target "$tgt")
  if ! tmux has-session -t "${tgt%%|*}" 2>/dev/null; then echo missing; return 0; fi
  reeve_backend_tmux_target_exists "$tgt" || { echo missing; return 0; }
  cmd=$(tmux list-panes -t "$target" -F '#{pane_current_command}' 2>/dev/null | head -1)
  [ -n "$cmd" ] || { echo unreadable; return 0; }
  case $cmd in
    claude|codex|opencode|cursor-agent|grok|gemini|pi|node|bun) echo alive ;;
    *) echo dead ;;
  esac
}

reeve_backend_tmux_wait_change() {
  # tmux has no push event source. Exit 2 is the honest answer: it tells the
  # sentry to fall back to polling rather than pretending to have waited.
  return 2
}

reeve_backend_tmux_kill() { tmux kill-window -t "$(_t_target "$1")" 2>/dev/null; }
