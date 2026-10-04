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
_h_ws()   { printf '%s\n' "${1%%|*}"; }
_h_pane() { local r=${1#*|}; printf '%s\n' "${r%%|*}"; }
_h_tab()  { local r=${1#*|}; case $r in *'|'*) printf '%s\n' "${r#*|}" ;; esac; }

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

reeve_backend_herdr_ensure_group() {
  # Optional. The workspace a reeve's hands open in as tabs. Its own workspace
  # first, when it runs inside herdr on this same server: that is where the
  # liege is already looking, and it is relabelled with the reeve's name so the
  # sidebar says whose it is. Then the one a previous call made, if it is still
  # there. Then a fresh one under the name. Identity is always an id herdr
  # returned, never a label: herdr does not enforce label uniqueness.
  local label=$1 known=${2:-} ws out
  ws=${HERDR_WORKSPACE_ID:-}
  if [ -n "$ws" ] && _h workspace get "$ws" >/dev/null; then
    _h workspace rename "$ws" "$label" >/dev/null || :
    printf '%s\n' "$ws"; return 0
  fi
  if [ -n "$known" ] && _h workspace get "$known" >/dev/null; then
    printf '%s\n' "$known"; return 0
  fi
  out=$(_h workspace create --cwd "${HOME:-$PWD}" --label "$label" --no-focus) || return 1
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // .result.workspace_id // empty' 2>/dev/null)
  [ -n "$ws" ] || { echo "herdr: workspace create returned no id" >&2; return 1; }
  printf '%s\n' "$ws"
}

reeve_backend_herdr_create_endpoint() {
  local cwd=$1 label=$2 group=${3:-} out ws pane tab
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
      printf '%s|%s|%s\n' "$group" "$pane" "$tab"; return 0
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
  printf '%s|%s\n' "${ws:-}" "$pane"
}

_h_expected_bin() {
  # The harness binary, derived from the rendered command line by skipping the
  # env prefix and any VAR=value assignments. Used as the submission proof.
  local tok
  for tok in $1; do
    case $tok in
      env) continue ;;
      *=*) continue ;;
      *) basename "$tok"; return 0 ;;
    esac
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
  _h pane read "$(_h_pane "$target")" --source recent-unwrapped --lines "$lines" --format text
}

reeve_backend_herdr_send_text_submit() {
  local target=$1 text=$2 pane
  pane=$(_h_pane "$target")
  # `agent prompt --wait` is deliberately not used: it can return success while
  # the text still sits unsubmitted in the composer (herdr #2422). pane run at
  # least submits atomically. For an agent already running there is no process
  # transition to watch, so confirmation here is best effort by design, and the
  # caller must treat the durable record as the delivery rather than this call.
  _h pane run "$pane" "$text" >/dev/null || return 1
}

reeve_backend_herdr_target_exists() {
  local pane
  pane=$(_h_pane "$1")
  _h pane get "$pane" | jq -e '.result.pane.pane_id // .result.pane_id' >/dev/null 2>&1
}

reeve_backend_herdr_agent_state() {
  local target=$1 pane native procs
  pane=$(_h_pane "$target")

  if ! _h pane get "$pane" >/dev/null 2>&1; then
    # Distinguish "definitely gone" from "could not read". A transient read
    # failure must never be reported as dead: a false dead is what launches a
    # second hand onto a live worktree.
    if herdr status server --json >/dev/null 2>&1; then echo missing; else echo unreadable; fi
    return 0
  fi

  native=$(_h agent get "$pane" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  procs=$(_h pane process-info --pane "$pane" \
            | jq -r '.result.process_info.foreground_processes[]?.name // empty' 2>/dev/null)

  # Two independent name sources, and either one naming a harness is enough for
  # alive. herdr keeps a stale agent registration after the process exits to a
  # shell, so a registration alone is not believed; but the process table alone
  # is not required either, because it can be unreadable.
  if printf '%s\n' "$procs" | grep -qiE '^(claude|codex|opencode|cursor-agent|grok|gemini|pi|node|bun)$'; then
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

reeve_backend_herdr_relabel() {
  # Optional. Renames the tab or workspace create_endpoint made, found by the id
  # in the target and never by its old label. A nested hand renames its tab
  # only: the workspace is its reeve's, named for the reeve. The label is one
  # argument whatever it holds; herdr answers with JSON nobody here reads.
  local ws tab; tab=$(_h_tab "$1")
  if [ -n "$tab" ]; then _h tab rename "$tab" "$2" >/dev/null; return; fi
  ws=$(_h_ws "$1")
  [ -n "$ws" ] || return 1
  _h workspace rename "$ws" "$2" >/dev/null
}
