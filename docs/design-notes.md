# Design notes

Decisions that cost something to learn, recorded so they are not re-litigated.

## Permissions: an allow list, not a bypass

Four configurations were measured against claude 2.1.236, in a detached tmux session:

| configuration | result |
|---|---|
| `--permission-mode acceptEdits` | stalls on an unusual Bash command |
| `--permission-mode bypassPermissions` | stalls on a consent dialog defaulting to "No, exit" |
| `--dangerously-skip-permissions` | stalls on the same dialog |
| `--settings <file>` with an explicit `allow` list | works |

The first row is the dangerous one, because it looks like it works. Common commands match the
user's own `settings.local.json` allow list and run fine, so a hand gets minutes into real work
before meeting one that does not. The first live errand failed exactly this way: it read its brief,
verified isolation, reported progress, read the repository's instruction file, located the relevant
files, and then raised a permission prompt on a `python3 -c` one-liner.

Consequence: permissions live in `offices/<office>.settings.json`, copied per errand. Copied, not
referenced, so editing an office cannot retroactively change what an errand already in flight may do.

## Worktrees: created by the orchestrator, not leased from a pool

firstmate delegates worktrees to `treehouse`, which leases from a pool of pre-warmed checkouts. The
pane's shell runs `treehouse get` and the orchestrator discovers the result by polling the pane's
current path.

Measured before copying it: a full `pnpm install --frozen-lockfile` in a cold worktree of the
portfolio repository took **184ms**, because pnpm hardlinks from a content addressed store. There
were also no gitignored `.env` files to carry over. The problem the pool solves did not exist.

So reeve creates the worktree itself, before the pane exists, and passes it as the pane's cwd. That
gives up the warm pool and gains: the household's own path and branch convention, no cwd discovery
race, no residue leaking between errands, and one less dependency. A holding whose setup genuinely
is expensive declares `setup:` in `manors.md` and dispatch runs it once, which buys the same
warmth without the pool.

## The status file, not the pane, is the truth

Three upstream herdr behaviours forced this and are worth knowing:

- an acknowledged event subscription can silently stop delivering while the connection stays open
  ([#3124](https://github.com/herdrdev/herdr/issues/3124)). So polling is the contract and a native
  event wait is only an optimisation.
- `agent_status` reports `idle` and `done` mid-turn
  ([#3530](https://github.com/herdrdev/herdr/issues/3530)), so a native idle is never evidence a
  hand stopped. Only `working` is accepted, as evidence of activity. **Not reproduced on herdr 0.9.0,
  one harness, one machine**: sampling `agent_status` every 0.2s through a multi-tool turn and then
  through a real hand's whole seventeen minute turn showed no blip either time. The caution stands,
  because one sample of one harness is not a refutation and 0.9.0 may simply have fixed it. What it
  buys is a short dwell where a dwell is needed, nothing more.
- a file descriptor leak can force-restart the server and kill every pane in the session
  ([#3527](https://github.com/herdrdev/herdr/issues/3527)). Durable files survive that; panes do not.

herdr also keeps a stale agent registration after the process exits to a shell, so `agent_state`
cross-checks the pane's foreground process table and never believes a registration alone.

## A `done:` cannot close a question

An errand that reports `done` while a `needs-decision` is still open is recorded as a **divergence**
and reported as unfinished. A hand finishing is not the liege answering, and without this rule a
hand that guessed at a question it should have waited on looks identical to one that got it right.
`bin/reeve-teardown` refuses while a decision is open, for the same reason.

## Folder trust is keyed to the repository, not the directory

A directory claude has not been trusted for raises a "Is this a project you created or one you
trust?" dialog that no permission setting suppresses. A hand cannot answer it and sits there
looking exactly like a hand that is thinking.

Measured: a worktree of an already trusted repository launched with no dialog, while a worktree of
an untrusted one stalled on one. `~/.claude.json` explains it: the trusted repository carries
`hasTrustDialogAccepted: true` and the other carries `false`. Neither worktree path had a record of
its own, so **trust resolves through the git repository**, and every worktree inherits its parent
repository's answer.

So `bin/reeve-dispatch` refuses before creating anything when the holding's repository is untrusted,
and `bin/reeve-doctor` marks it. Granting is a separate deliberate command,
`bin/reeve-trust --grant`, because it writes to the liege's own global claude configuration. It
backs the file up first and writes through a temporary file, so an interrupted write cannot leave a
truncated config.

This is the one genuinely harness specific thing in the system, which is why it lives in a file
named after the harness rather than inside dispatch.

## Three bugs that shaped the shell code

- **Locale collation.** Under many UTF-8 locales the glob `[a-z]` also matches uppercase, so `Bad_ID`
  passed id validation and would have become a branch name and a directory. `LC_COLLATE=C` is
  pinned in `bin/reeve-lib.sh` and ids are validated with negated classes.
- **pipefail plus `grep -q`.** `grep -q` exits on the first match and closes the pipe; the upstream
  writer gets EPIPE and pipefail reports the whole pipeline as failed. The symptom is that matching
  the *first* item of a list fails while the last succeeds. `lines_has` and `words_has` exist so no
  call site uses that pattern.
- **`read` on an unterminated final line.** `printf '%s'` writes no trailing newline, so the loop
  body never runs for the last item. Single item arrays parsed as empty and two item arrays silently
  lost one. Every read loop now carries `|| [ -n "$var" ]`.

## Things deliberately not built

- **A socket event sentry.** Deferred, not rejected. Given #3124 the polling loop has to exist
  underneath it anyway, so it is a latency optimisation and can wait until the polling cadence
  actually feels slow.
- **Focus preservation.** Measured: `workspace create --no-focus`, `worktree open --no-focus` and
  `agent wait` all leave focus alone. A hand's workspace appearing in the sidebar marked blocked is
  what draws attention, and the fix for that is hands that never block, not focus machinery.
- **Turn-end hooks.** The most harness-specific machinery there is: a Stop hook for claude, a
  `notify` config for codex, `hooks.json` for cursor, a plugin for opencode. Omitting it is what
  lets seven harnesses be equal peers today.
