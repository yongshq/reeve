# Harness contract

A harness file answers one question: **how do I start this agent CLI so it runs one errand
unattended?** One file per harness. Never a branch inside a script.

## Format

A deliberately small subset of TOML: a single flat table of scalars and string arrays. No nested
tables, no multi-line strings, no dotted keys. The parser is about twenty lines of shell so that
reeve needs neither python nor jq to start a hand.

| Key | Meaning |
|---|---|
| `name` | must equal the filename without `.toml` |
| `bin` | the executable to look for on PATH |
| `verified` | `true` only after an errand has actually run through it end to end |
| `source` | where the flags came from, so an unverified file is auditable |
| `launch` | command template. Placeholders: `{bin} {perm} {mcp} {model} {effort} {prompt}` |
| `prompt_mode` | `argv` (positional), `flag` (via `prompt_flag`), or `stdin` (piped in) |
| `prompt_flag` | used only when `prompt_mode = "flag"` |
| `perm_flag` | the autonomy flag. See the warning below |
| `mcp_flag` | valueless flags that start the hand with no MCP tools, from any source, or empty if the harness has none. See the trap below |
| `model_flag` | template containing `{model}`, or empty if the harness has none |
| `effort_flag` | template containing `{effort}`, or empty |
| `env` | environment assignments prefixed to the command |
| `instruction_files` | filenames this harness reads by itself, in precedence order |
| `detect_env` | env vars whose presence means reeve is itself running under this harness |
| `herdr_kind` | the value herdr's agent detection uses, for reference only |

## Why the prompt is always a pointer

`bin/reeve-harness render` never puts the brief text into the command line. It passes a short sentence
telling the hand to read an absolute path. This matters for three reasons: a multi-kilobyte
positional argument is fragile on every harness and fatal on some, a brief that changes on disk
should not need a relaunch to take effect, and the pointer wording is then identical everywhere,
which is what makes an office behave the same under codex as under claude.

## The autonomy flag, and why isolation is the thing that makes it acceptable

`perm_flag` puts the hand into a mode where it does not stop to ask a human for permission. That is
not optional: a hand that blocks on a permission prompt hangs forever and looks identical to a hand
that is thinking, so the whole supervision model breaks.

What makes it safe enough is everything around it, not the flag itself:

- the hand runs in its own git worktree, never the primary checkout
- it is on its own branch and forbidden to push, open a pull request, or touch the base branch
- it cannot reach another errand's worktree, and git refuses the same branch twice
- teardown refuses while work is uncommitted or unlanded

If you want a tighter setting, change `perm_flag` in one file. For claude, `--permission-mode
acceptEdits` is the tighter option, at the cost of a hand that stalls the first time it needs to
run a test.

## Three traps that cost real time here

**A variadic option eats the positional prompt.** `claude --allowedTools A B C "the prompt"`
consumes the prompt as another tool name, and the hand launches with an empty composer and no task,
looking perfectly healthy. Keep variadic options out of `launch`, or put the prompt behind a flag.

**"Do not ask" may mean "deny".** claude's `--permission-mode dontAsk` denies every tool call
rather than allowing it, so a hand on that mode reports everything as blocked and looks like an
environment problem. Never infer a permission mode's behaviour from its name: run the two-line
probe in `docs/verifying-a-harness.md` and read the result.

**An inherited MCP server suspends the hand where nothing can see it.** A hand picks up the user
level MCP configuration of the machine it runs on, and an office allow list covers core tools only,
so an inherited MCP tool raises a consent dialog. Unlike every other stall, this one is invisible:
the hand is suspended inside a tool call, so it cannot append `blocked:`, its last status line stays
`working:` and the sentry sees a healthy hand. That is what `mcp_flag` is for.

Two things make it easy to get wrong. A harness may have more than one source of MCP tools, and
shutting off the configured servers can leave a built-in integration untouched: claude needs
`--strict-mcp-config` *and* `--no-chrome`, and its own `claude mcp list` reports the second one as
nothing at all. And servers connect asynchronously, so a hand asked in its first seconds answers
"no MCP tools" whether or not the flag works. Probe a minute in, and assume every harness inherits
until you have measured otherwise.

## Verifying a harness

`verified = false` means reeve **refuses to dispatch on it** until you say otherwise. To verify one:

1. Install the CLI and confirm `bin/reeve-doctor` reports it installed.
2. Run a scout errand with `--harness <name>`, accepting the unverified warning.
3. Confirm the hand read its brief, appended status lines, and wrote a report.
4. Only then set `verified = true`, and note in `source` that you tested it.

Flags in the unverified files came from published documentation and from reading firstmate's launch
templates. They are written down honestly rather than omitted, because a wrong flag you can see and
fix beats an axis that pretends not to exist.
