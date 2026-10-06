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

Measured against claude 2.1.236, four configurations, in a detached session so nothing reached
the user's terminal:

| configuration | result |
|---|---|
| `--permission-mode acceptEdits` | **stalls.** Edits are fine, but an unusual Bash command still raises "Do you want to proceed?" |
| `--permission-mode bypassPermissions` | **stalls.** Raises a full screen consent dialog defaulting to "No, exit" |
| `--dangerously-skip-permissions` | **stalls.** Same consent dialog |
| `--settings <file>` with an explicit `allow` list | **works.** No dialog, no prompt, Bash runs |
| the same, on a machine with any MCP tool source | **stalls, silently.** An inherited MCP tool falls outside the allow list and raises a consent dialog. `--strict-mcp-config --no-chrome`, with no `--mcp-config`, starts the hand with no MCP tools at all and removes the class |
| the same, plus `--mcp-config` naming the household browser alone, its tools in the allow list | **works.** Only that server's tools load and a call to one raises no dialog. See the household browser below |

The first row is the trap, because it *looks* like it works: common commands match the user's own
`settings.local.json` allow list and run fine, so a hand gets minutes into real work before hitting
one that does not. That is exactly how the first live errand failed here.

The last row is worse than a stall, because it is a stall nobody is told about: the hand is
suspended inside a tool call, so it cannot append `blocked:` and its last status line stays
`working:`. Measured on a scribe errand that sat six minutes at a `claude-in-chrome` dialog. Two
flags because there are two sources: `--strict-mcp-config` drops the servers in the machine's MCP
configuration, and `--no-chrome` drops Claude in Chrome, which is a built-in integration that
`claude mcp list` never mentions and the strict flag alone leaves fully loaded.

## The household browser

Shutting off every MCP tool also shut off the only way a hand could look at a page it had changed,
so a builder shipped UI it had never seen and the liege checked it by hand after it landed. The
browser comes back as the household's own, not the machine's:

- **What:** one MCP server, `reeve-browser`: `chrome-devtools-mcp` at a pinned version, run
  through `npx`.
- **Which Chrome:** its own instance, `--headless` and `--isolated`, with a temporary profile
  deleted when it closes.
- **Never:** `--browserUrl`, `--wsEndpoint`, `--autoConnect`, port 9222, or any browser a person
  is using.
- **Who:** an office whose settings allow `mcp__reeve-browser`. Today the artificer and the warden.
- **How:** `bin/reeve-dispatch` writes the server config into the errand directory, beside
  settings.json, and the harness's `browser_flag` passes it next to `--strict-mcp-config
  --no-chrome`.
- **Why no dialog:** the allow rule is in the office's own settings, so the server's tools are
  pre-approved like `Bash`.

`--strict-mcp-config` still keeps every configured server out and `--no-chrome` still keeps Claude
in Chrome out; `--mcp-config` adds exactly the one server back. The office text owns the conduct:
the hand starts the project's dev server on a free port of its own, in its own copy, looks at the
result, stops the server, and says in its `done:` line what it saw. Never the liege's running app,
never a port the liege's server uses.

Builder and warden both look, on purpose. The builder checks its own result first, which catches
the obvious before anyone else spends time on it. The warden checks again in fresh context against
the intent, which catches what an author cannot see in its own work. Two different checks, not a
cycle.

The browser is optional. `bin/reeve-doctor` reports whether this machine has it: `node` and `npx`
on PATH, and a Chrome the server can launch. That Chrome is the one place `chrome-devtools-mcp`
looks for stable Chrome on this platform, or whatever `$REEVE_HOME/config/browser-chrome` names,
one line holding an executable's absolute path. Any Chromium build works there, a person's own
browser included, because the hand's instance is `--isolated`, headless, on a temporary profile, and
never attaches to a running one. Chrome for Testing (`npx @puppeteer/browsers install chrome@stable
--path <dir>`) stays a valid option, not the recommendation. A dispatch never refuses for want of it: the hand goes out without the
server, the dispatch says why, and the hand reports `not visually verified: <reason>`.

## Tool grants are coarse

`allow: ["Write"]` permits writing anywhere the hand can reach, not only the one file an office is
supposed to produce. Three things narrow it, and none of them is the tool list:

1. the hand's working directory is its own git worktree
2. the directories granted on top of it: its errand directory, and every other holding in its
   manor
3. `bin/reeve-teardown` refuses when a read-only errand's copy is dirty or its HEAD has moved

So a scout that writes where it should not is caught, not prevented. If you need it prevented, add
a `deny` entry rather than trusting the office text.

### The manor grant, and the deny that bounds it

A manor may span several repositories and a hand routinely has to READ one to understand another.
Without that a hand stalls, and stalls in the worst way available: the refusal arrives inside a
tool call, so it never appends `blocked:`, its last line stays `working:`, and the sentry reads it
as a healthy hand thinking.

`--add-dir` grants read and write together and the harness offers no read-only form, so the write
half is taken back per errand. `bin/reeve-dispatch` writes an `Edit(//<path>/**)` deny into the
errand's own copy of this office's settings, for each sibling holding it granted. Three details
are load bearing, all three measured against the installed harness rather than assumed:

- **Two leading slashes** is the absolute form. One slash anchors the pattern at the settings
  file's own directory, so the rule would match nothing and the grant would be a plain read-write
  handout.
- **`Edit(...)`, never `Write(...)` or `Glob(...)`.** Only `Edit(path)` and `Read(path)` rules are
  consulted. The others are accepted, never checked, and warned about at startup: a rule that
  looks like protection and is none.
- **`deny` beats `allow` and `defaultMode`**, in every scope, which is what makes this enforcement
  rather than a preference.

Bash is untouched by any of it, and always was. A hand has been able to write wherever a shell can
reach since the first errand, which is exactly why point 3 above exists. This closes the
tool-shaped route the grant itself opens, and claims nothing more.

## Folder trust

A directory claude has never seen raises a separate trust dialog, which no permission setting
suppresses. In practice worktrees inherit trust from an already trusted parent, which is why
a worktree of a repository you have already trusted never sees it. A holding somewhere untrusted
will stall every hand on its first launch, so `bin/reeve-doctor` checks for this and says so.
