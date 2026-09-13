# Backend contract

A backend answers one question: **where does a hand's session live?** It knows nothing about
offices, briefs, memory or errands. It never decides anything. If a backend function has to
adjudicate meaning, the abstraction is in the wrong place.

Worktrees are deliberately **not** part of this contract. `git worktree` is identical everywhere,
so `bin/reeve-dispatch` creates worktrees itself and hands a backend a plain directory. A backend may
optionally *adopt* that directory for presentation (herdr groups it in the sidebar), but must work
correctly if it does not.

## Required functions

Each is `reeve_backend_<name>_<fn>`, sourced only through `bin/reeve-backend`.

| Function | Arguments | Must print | Exit |
|---|---|---|---|
| `available` | none | nothing | 0 if this backend can be used on this machine, else non-zero with one line on stderr saying what is missing |
| `describe` | none | one line: name and version | 0 |
| `create_endpoint` | `<cwd> <label>` | one line: an opaque target string | 0 on success |
| `launch` | `<target> <cmdline>` | nothing | 0 if the command line was submitted |
| `capture` | `<target> <lines>` | up to `<lines>` lines of plain-text scrollback | 0 |
| `send_text_submit` | `<target> <text>` | nothing | 0 only if submission was **confirmed**, not merely typed |
| `target_exists` | `<target>` | nothing | 0 if the endpoint is still there |
| `agent_state` | `<target>` | one word: `alive`, `dead`, `missing` or `unreadable` | 0 |
| `attention_state` | `<target>` | one word: `working`, `waiting`, `settled` or `unknown` | 0 |
| `wait_change` | `<target> <timeout_ms>` | nothing | 0 a change was observed, 1 timed out with no signal, 2 this backend cannot wait and the caller must poll |
| `kill` | `<target>` | nothing | 0 |

## The rules every backend obeys

1. **A target is opaque to callers.** Only the backend parses it. herdr pane ids contain a colon
   (`w4:p1`), so a naive `cut -d:` on a `session:pane` target splits in the wrong place. Split on
   the **first** colon only, inside the adapter.
2. **`agent_state` must be recovery grade.** A false `dead` is the one verdict that can launch a
   second hand onto a live worktree, so return `alive` if any evidence says alive. Return
   `unreadable` for a transient failure, never `dead`, because a transient read failure must never
   license a duplicate.
3. **Never trust a native idle or done status as proof a hand stopped.** Accept a native "working"
   as evidence of activity and nothing more. The status file is the contract.
4. **`agent_state` and `attention_state` answer different questions, and neither substitutes for the
   other.** `agent_state` asks whether there is still a process, and is recovery grade. `attention_state`
   asks whether the session is getting on with it, and exists because a hand suspended at a permission
   dialog is `alive` by every process measure while nothing at all is happening. Keep them apart:
   folding one into the other puts a false `dead` back within reach. `attention_state` is also allowed
   to be wrong in the safe direction, which is `unknown`, because nothing destructive hangs off it.
5. **Labels are never authority.** herdr does not enforce label uniqueness, so never place or
   destroy anything because a label matched. Resolve identity from ids the backend itself returned.
6. **A refusal is terminal.** If `available` fails, say why and stop. Never silently fall back to
   another backend.
7. **`wait_change` is an optimisation, never a source of truth.** Exit 2 is a perfectly good
   answer, and the polling caller is the contract. Its states may also be **latched**, so it can
   return "a change was observed" instantly and forever; a caller that reads that as time having
   passed busy-spins.

## The two backends are not symmetric about attention

herdr composes its answer from a detection manifest it updates remotely, so `attention_state` there is
one call against the live screen and the regexes are never this repository's problem.

Under tmux there is nothing to ask but the pane's text. Measured: `pane_current_command` is the
harness binary in every condition, working or suspended, and `#{pane_title}` carries the harness's OSC
title but never the working glyph, because that glyph is herdr's own composition of an OSC progress
region tmux has no format variable for. So the highest priority rule in the herdr scheme has no tmux
equivalent and `working` cannot be recognised positively at all. The tmux adapter therefore borrows
herdr's classifier on captured text where herdr happens to be installed, and falls back to two
conditions of its own where it is not, answering `unknown` rather than guessing.

That gap is a property of tmux, not an unfinished adapter.

## Adding one

Copy `tmux.sh`, which is the minimal honest implementation, then `bin/reeve-doctor` will pick it up.
A backend is not usable until an errand has actually run through it end to end.
