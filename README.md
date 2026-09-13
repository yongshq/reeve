# reeve

Talk to one agent. It manages the rest.

`reeve` is an agent distro: a directory of instructions, offices, tooling and state conventions
that turns one agent session into a household. You speak only to the **reeve**. It dispatches
**hands** into isolated git worktrees, watches them, and comes back to you when something finishes
or gets stuck. It remembers your preferences and each project's facts centrally, keyed by project
rather than by directory, so a lesson learned in one repository is available in all of them.

It is not a model, a harness, a CLI or an MCP server. It is a directory you install once.

## Two pluggable axes

| Axis | Question it answers | Implementations |
|---|---|---|
| **backend** | where does a hand's session live | `herdr` (primary), `tmux` |
| **harness** | which agent CLI runs inside it | `claude` (verified), `codex`, `pi`, `opencode`, `cursor`, `grok`, `gemini` (declared) |

**Verified** means an errand has actually run through it end to end on this machine. Anything else
is refused rather than attempted, because a harness that fails halfway through an errand is worse
than one that never starts. `bin/reeve-doctor` reports installed, declared and verified separately.

## Install

```sh
git clone <this repo> reeve
cd reeve && ./install.sh
bin/reeve-doctor
```

A clone is the whole install. There is no shell config to edit, nothing to put on `PATH` and
nothing written outside the clone and the operational home at `~/.reeve`. The clone can sit
wherever you like, since every path is resolved from where it actually ended up. Every tool is run
by path from the repository root, which is also where a session starts.

Then, from the repository root, introduce a project and start a session:

```sh
bin/reeve-survey ~/path/to/repo      # gathers evidence
bin/reeve-survey --register <name> --manor <manor> --path <abs> --instructions AGENT.md
claude
```

## The vocabulary

| Term | Meaning |
|---|---|
| liege | you |
| reeve | the one agent you talk to |
| hand | a worker the reeve dispatched. Never speaks to you |
| office | a hand's role: artificer, scout, warden, scribe, steward |
| errand | one unit of work: an id, a brief, a worktree, a status file |
| sentry | the supervising process |
| manor | one project, possibly several repositories |
| holding | one repository inside a manor |

## The offices

| Office | For | Can write |
|---|---|---|
| artificer | building and fixing code | its worktree |
| scout | investigating, root-causing, mapping | its report only, `Edit` denied |
| warden | reviewing finished work in a fresh context | its review only, `Edit` denied |
| scribe | docs and prose | its worktree |
| steward | memory maintenance | the reeve's home only |

## Skills

`/court` `/muster` `/errand` `/inscribe` `/strike` `/recall` `/glean` `/survey`

## How an errand actually flows

```
you  ──▶  reeve
            │  reeve-brief: writes a brief with two seams, {INTENT} and {SPEC}
            │  reeve-dispatch: git worktree ─▶ session endpoint ─▶ launch
            ▼
          hand  in <repo>.worktrees/<id>, on <type>/<id>
            │  appends: working: / needs-decision: / blocked: / done:
            ▼
         sentry  absorbs progress, wakes the reeve once per actionable change
            │
            ▼
you  ◀──  reeve   "branch ready" or one question at a time
```

## Cleanup is automatic

An agent never exits itself, so a finished hand would otherwise idle forever holding a pane. When
the sentry reports a finished errand it also cleans up, splitting the job by what it can cost:

- **the session is always freed**, since the status file and any report are already on disk
- **the copy is removed only when nothing would be lost**, so a scout vanishes entirely while an
  artificer keeps its branch and copy until you decide

A blocked hand is never reaped, because it can still be steered. Neither is an errand that claimed
`done` with a question still open, because that is not finished whatever it says.

## The rules that shape everything

1. The reeve never edits a project file. It dispatches or it refuses.
2. A hand commits on its own branch only. Never pushes, never opens a pull request.
3. Teardown refuses while work is uncommitted or unlanded. There is no `--force`.
4. Hands never address the liege.
5. An unverified harness or backend is refused, never silently substituted.
6. Memory is written only with evidence you can name from the session that produced it.

## Documentation

- `AGENTS.md` the reeve's contract, loaded every session
- `offices/README.md` the offices, and why permissions are an allow list
- `harnesses/README.md` the harness contract and its traps
- `backends/README.md` the backend contract
- `docs/verifying-a-harness.md` how to earn a `verified = true`
- `docs/design-notes.md` what was measured, and what was decided against
