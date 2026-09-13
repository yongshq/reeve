# Offices

Each office is two files that travel together:

| File | Owns |
|---|---|
| `<office>.md` | the role: what it does, its rules, its definition of done. Vendor neutral, inlined into every brief |
| `<office>.settings.json` | what it is *able* to do, enforced by the harness |

The second file matters more than it looks. Telling a scout not to edit is an instruction it can
misread. Denying `Edit` means it cannot, whatever it decides. Where a permission can be enforced
rather than requested, enforce it.

## The default tier

The office predicts the tier in most errands, so each one declares its own here and the reeve names
a tier only when the office cannot. `bin/reeve-dispatch` reads this table: the row is the
declaration, not a description of one kept somewhere else. The tiers themselves, and which errand
shape deserves which, are in `skills/errand/errand.md`.

| Office | Model | Effort | Why |
|---|---|---|---|
| artificer | (none) | (none) | the skill's table splits this office: a rename or a migration a test proves is cheap, building something new or hunting a bug is default. Nothing the office alone settles, so the reeve still names it |
| scout | (none) | (none) | default tier, which is what naming nothing already gives |
| warden | (none) | (none) | default, never cheap. Unset is what guarantees it: the harness default is the richest thing available, so the only thing a declaration here could do is make a review cheaper |
| scribe | (none) | low | cheap: a pass over files the brief already names |
| steward | (none) | low | cheap: a pass over entries the brief already names |

`(none)` means unset, and unset means today's behaviour: the harness decides. Precedence, highest
first, is `--model` or `--effort` on the dispatch, then this table, then the harness. The two
resolve independently, so an office may default effort without pinning a model.

No office pins a model, which is deliberate rather than unfinished. A model name is harness
specific, `opus` means nothing to codex, while this file is vendor neutral and one row serves every
harness. The reeve knows which harness an errand is going out on and can pass `--model` for it.
Effort is a plain word, `low` through `max`, so it survives the same row on any harness that has
the flag at all.

And when it does not: a harness declaring an empty `effort_flag` drops the setting silently, so a
row here is never proof it applied. `bin/reeve-dispatch` warns at dispatch and `bin/reeve-status`
prints the axis as dropped, naming the harness that has no flag for it.

## Why an allow list and not a blanket bypass

Measured against claude 2.1.236, four configurations, in a detached tmux session so nothing reached
the user's terminal:

| configuration | result |
|---|---|
| `--permission-mode acceptEdits` | **stalls.** Edits are fine, but an unusual Bash command still raises "Do you want to proceed?" |
| `--permission-mode bypassPermissions` | **stalls.** Raises a full screen consent dialog defaulting to "No, exit" |
| `--dangerously-skip-permissions` | **stalls.** Same consent dialog |
| `--settings <file>` with an explicit `allow` list | **works.** No dialog, no prompt, Bash runs |
| the same, on a machine with any MCP tool source | **stalls, silently.** An inherited MCP tool falls outside the allow list and raises a consent dialog. `--strict-mcp-config --no-chrome`, with no `--mcp-config`, starts the hand with no MCP tools at all and removes the class |

The first row is the trap, because it *looks* like it works: common commands match the user's own
`settings.local.json` allow list and run fine, so a hand gets minutes into real work before hitting
one that does not. That is exactly how the first live errand failed here.

The last row is worse than a stall, because it is a stall nobody is told about: the hand is
suspended inside a tool call, so it cannot append `blocked:` and its last status line stays
`working:`. Measured on a scribe errand that sat six minutes at a `claude-in-chrome` dialog. Two
flags because there are two sources: `--strict-mcp-config` drops the servers in the machine's MCP
configuration, and `--no-chrome` drops Claude in Chrome, which is a built-in integration that
`claude mcp list` never mentions and the strict flag alone leaves fully loaded.

## Tool grants are coarse

`allow: ["Write"]` permits writing anywhere the hand can reach, not only the one file an office is
supposed to produce. Three things narrow it, and none of them is the tool list:

1. the hand's working directory is its own git worktree
2. exactly one extra directory is granted, its errand directory
3. `bin/reeve-teardown` refuses when a read-only errand's copy is dirty or its HEAD has moved

So a scout that writes where it should not is caught, not prevented. If you need it prevented, add
a `deny` entry rather than trusting the office text.

## Folder trust

A directory claude has never seen raises a separate trust dialog, which no permission setting
suppresses. In practice worktrees inherit trust from an already trusted parent, which is why
a worktree of a repository you have already trusted never sees it. A holding somewhere untrusted
will stall every hand on its first launch, so `bin/reeve-doctor` checks for this and says so.
