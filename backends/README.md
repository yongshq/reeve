# Backend contract

A backend answers one question: **where does a hand's session live?** It knows nothing about
offices, briefs, memory or errands. It never decides anything. If a backend function has to
adjudicate meaning, the abstraction is in the wrong place.

Worktrees are deliberately **not** part of this contract. `git worktree` is identical everywhere,
so `bin/reeve-dispatch` creates worktrees itself and hands a backend a plain directory. A backend may
optionally *adopt* that directory for presentation (herdr groups it in the sidebar), but must work
correctly if it does not.

herdr (`herdr.sh`) is the only backend shipped. The contract stays so another can be added, and the
tests drive it through stub backends of their own.

## Required functions

Each is `reeve_backend_<name>_<fn>`, sourced only through `bin/reeve-backend`.

| Function | Arguments | Must print | Exit |
|---|---|---|---|
| `available` | none | nothing | 0 if this backend can be used on this machine, else non-zero with one line on stderr saying what is missing |
| `describe` | none | one line: name and version | 0 |
| `create_endpoint` | `<cwd> <label> [<group>]` | one line: an opaque target string | 0 on success. With `<group>`, from `ensure_group`, the endpoint opens inside it; a backend that cannot falls back to an endpoint of its own |
| `launch` | `<target> <cmdline>` | nothing | 0 if the command line was submitted |
| `capture` | `<target> <lines>` | up to `<lines>` lines of plain-text scrollback | 0 |
| `send_text_submit` | `<target> <text>` | nothing | 0 only if submission was **confirmed**, not merely typed |
| `target_exists` | `<target>` | nothing | 0 if the endpoint is still there |
| `agent_state` | `<target>` | one word: `alive`, `dead`, `missing` or `unreadable` | 0 |
| `attention_state` | `<target>` | one word: `working`, `waiting`, `settled` or `unknown` | 0 |
| `wait_change` | `<target> <timeout_ms>` | nothing | 0 a change was observed, 1 timed out with no signal, 2 this backend cannot wait and the caller must poll |
| `kill` | `<target>` | nothing | 0 |

Six optional functions. A backend may leave any of them out; `bin/reeve-backend` then refuses
the call, and every caller treats that refusal as a no and carries on.

| Function | Arguments | Must print | Exit |
|---|---|---|---|
| `relabel` | `<target> <label>` | nothing, or the target to keep from now on | 0 if the endpoint now shows `<label>`. Used by `bin/reeve-adopt`, so an adopted hand carries its new reeve's name. A target whose identity holds its label is printed again with the new one |
| `ensure_group` | `<label> [<known-id> [<held-id>...]]` | one line: a group id | 0 if the group exists and shows `<label>`. The reeve's own group: a herdr workspace. `<known-id>` is what an earlier call printed, to reuse while it is still there; it may be empty. Each `<held-id>` is a group another reeve holds, never relabelled, nested into or reused. Used by `bin/reeve-dispatch` and `bin/reeve-name` |
| `label_own` | `<label>` | nothing | 0 if the endpoint this reeve itself runs in now shows `<label>`, its name. That one only, never any other, and never from a hand. herdr renames `$HERDR_TAB_ID` only when it is on the server the backend talks to. Used by `bin/reeve-name` |
| `pane_gone` | `<pane-id> <socket>` | nothing | 0 only when the server on `<socket>` answers that the pane is not there. Anything it cannot check is 1. Used to free a group whose reeve's pane has closed |
| `pane_vacant` | `<pane-id> <socket>` | nothing | 0 only when that server answers that the pane is gone or runs no harness. Anything it cannot check is 1. Used so a reeve that crashed stops holding its name |
| `group_gone` | `<target>` | nothing | 0 only when the target opened inside a group and the server answers that group is gone. Used by the sentry to say a hand died with its reeve's workspace |

A group is a reeve's own place, labelled with its name, and its hands open inside it: herdr tabs in
its workspace. The group id, like a target, is opaque to callers; only the backend that printed it
reads it. A target made inside a group stays opaque too, and `kill` on it closes that endpoint
only, **never the group**: the group is usually the workspace the reeve itself runs in, so closing
it would kill the reeve and every hand beside it.

One reeve per group. The workspace a reeve runs in is its group only when no other reeve holds it,
when the id really is on the server the backend talks to, and never from inside a hand: dispatch
launches every hand with `REEVE_HAND=<id>` and with `HERDR_WORKSPACE_ID` unset, since the workspace
a hand sits in is its reeve's. Otherwise the reeve gets one of its own. A reeve holds its group for
as long as its recorded pane is open, whatever its heartbeat says; only `pane_gone` on that pane's
own server frees it, and a pane that cannot be checked keeps it held. A reeve with no pane, in a
plain terminal, holds it while its heartbeat is fresh. herdr group ids carry their server's socket
(`w5@<socket>`), and a known id is reused only on that same server, and only while it shows the
reeve's name or one its records held (`$REEVE_GROUP_NAMES`, set by `reeve_group`): ids are counters,
so after a server restart a known id may be someone else's. Under `REEVE_GROUP_KEEP=1`, set by
`reeve_group` while the known group still holds hands of this reeve's errands, the known group is
preferred to the workspace the reeve now sits in.

A server restart reuses ids, so a stored target or pane key may name someone else's endpoint. A
target may end `#<identity>`, what the endpoint was when it was made, and every function that acts
on a target checks it first: a different endpoint under the same id is `missing` to `agent_state`
and is never killed, relabelled or typed into. herdr's identity is checksums of the pane's working
directory and of its label, either matching enough: a restored endpoint keeps its label and
usually its directory, while its `terminal_id` does not survive a restart. A label is shared by
every hand of one office from one reeve (`Scout sent by Aldric`), so a label match from a pane
sitting in another git checkout does not count: that is another hand, in its own copy. A target without one is
trusted as before. A herdr pane key carries no server epoch: herdr restores its panes with their
ids, so the same id is the same pane.

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

## Adding one

Start from `herdr.sh`, implement the required functions, and `bin/reeve-doctor` will pick it up.
A backend is not usable until an errand has actually run through it end to end.
