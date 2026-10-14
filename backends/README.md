# Backend contract

A backend answers one question: **where does a hand's session live?** It knows nothing about
offices, briefs, memory or errands. It never decides anything. If a backend function has to
adjudicate meaning, the abstraction is in the wrong place.

Worktrees are deliberately **not** part of this contract. `git worktree` is identical everywhere,
so `bin/reeve-dispatch` creates worktrees itself and hands a backend a plain directory. A backend may
optionally *adopt* that directory for presentation (herdr groups it in the sidebar), but must work
correctly if it does not.

Two backends are shipped. herdr (`herdr.sh`) is the default outside hall. hall (`hall.sh`) is a copy of it that
speaks only to hall, a multiplexer forked from herdr whose CLI keeps herdr's commands: it runs
hall's own binary (`$HALL_BIN_PATH`, `$REEVE_HALL_BIN`, `config/hall-bin`, then `hall` on `PATH`),
names its server by socket (`$REEVE_HALL_SOCKET`, `$HALL_SOCKET_PATH`, then the default session hall
lists) and never by `--session`, and never runs `herdr` or reads `HERDR_*`. `REEVE_BACKEND=hall`
selects it; hall sets that in its own panes. Inside a hall pane (`HALL_ENV=1`) hall is also the
default when no flag, `REEVE_BACKEND` or `config/backend` names one, so a pane that lost the
variable still never reaches herdr. An errand keeps the backend its record names, so a herdr errand
stays on herdr whatever the caller's environment, and a record with none is herdr's.
From a hall pane (`HALL_ENV=1`), `reeve-backend list` and `reeve-doctor` do not run herdr at all,
since herdr's own checks there would read herdr's config folder; each says so in one line, and a
herdr pane or a plain terminal checks it.
On hall every pane a hand gets (`tab create`, `worktree open`, `workspace create` in
`create_endpoint`) is made with `--no-agent-resume`. A hall restart drops a pane so marked, and any
tab or workspace it leaves empty, instead of resuming the hand's harness bare, without its
environment or flags. So after a restart the hand is gone: its target no longer resolves,
`agent_state` reads `missing`, the watch says `stale:`, and `bin/reeve-dispatch <id>` sends a fresh
hand out again from its instructions into the copy it left (the `errand` skill says on what proof;
only an errand sent out on hall relaunches into its copy, a herdr one refuses as it always did).
Work committed on its branch, and any uncommitted work in its copy, is kept; its unfinished
conversation is not. The reeve's own pane is never made with the flag, so it resumes as before.
`available` reads hall's own usage for the flag and refuses a hall that predates it, so a dispatch
stops before it makes a copy. It cannot ask the running server: hall's ping reports a version,
protocol and capabilities the flag left unchanged, so a binary updated under a server still running
an older build passes, its create is refused after the copy exists, and dispatch removes the copy
and empty branch it just made. After each create the new pane's `agent_resume` is read back, and one
that is not `false` (a server running a build from before the flag ignores it) is closed and
refused. `worktree open` is never asked of a checkout hall already shows open, since it would hand
back that workspace's own pane, unmarked, and rename it; such a hand gets a workspace of its own.
Accepted and left as it is: `worktree open` may also open the holding's primary checkout as a parent
workspace, unmarked. It is a shell with nothing to resume, and `kill` never closes it.
Known limit: hall can answer `already_open: false` with a workspace that was already there (its
two lookups for an open checkout disagreeing); no case of it is known, and `_h_open_here` asks
first, but such a workspace, unmarked, is then closed as the create's own.
Known limit: a workspace that opens on the checkout between `_h_open_here` and `worktree open` is
renamed to the hand's label inside that call, and discarding it does not undo the rename. A narrow
window, and only the label changes.
The tests drive the contract through stub backends of their own.

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

Eight optional functions. A backend may leave any of them out; `bin/reeve-backend` then refuses
the call, and every caller treats that refusal as a no and carries on.

| Function | Arguments | Must print | Exit |
|---|---|---|---|
| `relabel` | `<target> <label>` | nothing, or the target to keep from now on | 0 if the endpoint now shows `<label>`. Used by `bin/reeve-adopt`, so an adopted hand carries its new reeve's name. A target whose identity holds its label is printed again with the new one |
| `ensure_group` | `<label> [<known-id> [<held-id>...]]` | one line: a group id | 0 if the group exists and shows `<label>`. The reeve's own group: a herdr workspace. `<known-id>` is what an earlier call printed, to reuse while it is still there; it may be empty. Each `<held-id>` is a group another reeve holds, never relabelled, nested into or reused. Used by `bin/reeve-dispatch` and `bin/reeve-name` |
| `label_own` | `<label>` | nothing | 0 if the endpoint this reeve itself runs in now shows `<label>`, its name. That one only, never any other, and never from a hand. herdr renames `$HERDR_TAB_ID`, hall `$HALL_TAB_ID`, only when it is on the server the backend talks to. Used by `bin/reeve-name` |
| `pane_gone` | `<pane-id> <socket>` | nothing | 0 only when the server on `<socket>` answers that the pane is not there. Anything it cannot check is 1. Used to free a group whose reeve's pane has closed. Asked of the backend the pane's holder recorded in its session's `place`, herdr when it has none |
| `pane_vacant` | `<pane-id> <socket>` | nothing | 0 only when that server answers that the pane is gone or runs no harness. Anything it cannot check is 1. Used so a reeve that crashed stops holding its name |
| `group_gone` | `<target>` | nothing | 0 only when the target opened inside a group and the server answers that group is gone. Used by the sentry to say a hand died with its reeve's workspace |
| `place` | none | one line: the name of the session the backend talks to | 0 if it can say. Kept in an errand's record (`place=`) and beside a reeve's pane (`state/sessions/<sid>/place`, `<backend> <name>`), for `bin/reeve-listing`. herdr has none |
| `dismiss_dialog` | `<target>` | nothing | 0 if the backend's way of saying no to a dialog was sent: herdr presses Escape. Never anything that could answer Allow. 3, nothing sent, if the session no longer reads `waiting` just before the key. Says nothing about whether the dialog went; the caller reads `attention_state` again. Used by `bin/reeve-deny` |

A group is a reeve's own place, labelled with its name, and its hands open inside it: herdr tabs in
its workspace. The group id, like a target, is opaque to callers; only the backend that printed it
reads it. A target made inside a group stays opaque too, and `kill` on it closes that endpoint
only, **never the group**: the group is usually the workspace the reeve itself runs in, so closing
it would kill the reeve and every hand beside it.

One reeve per group. The workspace a reeve runs in is its group only when no other reeve holds it,
when the id really is on the server the backend talks to, and never from inside a hand: dispatch
launches every hand with `REEVE_HAND=<id>` and with `HERDR_WORKSPACE_ID` unset, and `HALL_WORKSPACE_ID`
too for a hand going out on hall or from inside it, since the workspace a hand sits in is its reeve's. Otherwise the reeve gets one of its own. A reeve holds its group for
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
every hand of one office from one reeve (`Scout of Aldric`), so a label match from a pane
sitting in another git checkout does not count: that is another hand, in its own copy. A target
without one is trusted as before. A herdr pane key carries no server epoch: herdr restores its panes
with their ids, so the same id is the same pane.

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
