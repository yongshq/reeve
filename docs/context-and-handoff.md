# Context and handoff

> The reeve's state should never depend on its context in the first place. A clean reset is
> deterministic and reviewable; a compaction is neither.

That sentence is the whole design. Everything below follows from it.

## Why the reeve is different

A coding agent holds a mental model of a codebase that genuinely lives in its head. Losing context
hurts, so compaction is a reasonable trade.

The reeve holds almost nothing of the kind. Its entire job is knowing which errands exist, what
they reported, what is open and what it has learned, and every one of those is already a file:

| What | Where | Rebuilt by |
|---|---|---|
| every errand, its instructions, its result | `$REEVE_HOME/errands/<id>/` | reading the directory |
| what each one reported, in order | `errands/<id>/status` | `bin/reeve-status <id>`, which reconciles the whole log |
| where each ran, on what branch | `state/<id>.meta` | `bin/reeve-status --all` |
| what the household knows | `liege.md`, `manors/*.md` | session start |
| retired knowledge | `archive.md` | never loaded, on purpose |

So a fresh reeve reads three things and knows everything the old one did. On this machine that
durable record is 300K on disk and **218 tokens** of always-loaded context, because the rest is
read on demand.

## What a reset actually costs

About one page, and none of it is facts:

1. the goal above the individual errands
2. threads raised in conversation but never dispatched
3. decisions made in chat that never reached a brief or a memory entry
4. the next action, and whose move it is

That is what `/handoff` writes down, and it is the only thing it writes down. A handoff that
restates errand records is a long document that hides the four things that matter.

## Why not auto-compaction

Three reasons, in order of weight.

**It cannot keep its promise.** Compaction is lossy summarisation by definition. A skill offering
to compact "without losing detail" would be lying, and you would discover it at the worst possible
moment.

**It duplicates a built-in, worse.** Claude Code already auto-compacts and has the real token
accounting. A skill guessing from outside cannot do better.

**It hides the signal.** Context pressure means the session has accumulated state that should have
been written down. Compacting removes the symptom and leaves the cause. Handing off writes the
state where the next reeve can read it, which is what you wanted anyway.

## The gauge

The model cannot see its own context usage. The statusline can, so it writes the figure out and the
reeve reads it:

```sh
bin/reeve-context            # one line, plus an exit code
bin/reeve-context --percent  # just the number
```

Exit `0` comfortable, `1` past the threshold, `2` unknown. The threshold defaults to 50 and lives
in `$REEVE_HOME/config/context-threshold`.

Installation is nine guarded lines in the statusline, which no-op silently when `$REEVE_HOME/state`
does not exist, so they cannot break a machine without reeve on it:

```sh
if [ -n "$ctx_pct" ] && [ -d "${REEVE_HOME:-$HOME/.reeve}/state" ]; then
  printf '%s\n' "$ctx_pct" > "${REEVE_HOME:-$HOME/.reeve}/state/context" 2>/dev/null || :
fi
```

**An unknown reading is reported as unknown.** A reeve that invented a figure would hand off at the
wrong moment, or fail to hand off at all.

## Offer, never act

Past the threshold the reeve says where it is and stops:

> I am at 62% of my context. Want me to write a handoff so you can start me fresh?

It does not compact, does not summarise the conversation into a note, and does not suggest a reset
mid-errand. The moment to reset is a judgement about what you are in the middle of, and the reeve
cannot see that from a percentage.

## Resuming

Session start reads `bin/reeve-handoff newest <manor>` before anything else. If it resumed from
one it says so and names the next action, because you may not remember writing it.

```sh
bin/reeve-handoff new <manor>      # scaffold, factual sections pre-filled from disk
bin/reeve-handoff newest [manor]   # path of the most recent
bin/reeve-handoff list [manor]
```

Handoffs live in `$REEVE_HOME/handoffs/`, deliberately separate from `~/.claude/handoffs/` so
reeve's household records do not mix with the liege's own.

## The habit this is really enforcing

Never hold something only in conversation that belongs in a file. If a decision matters past this
session it goes into memory through `/inscribe`. If it only matters until the work lands it goes
into a handoff. If it matters to one errand it goes in that errand's brief.

Do that consistently and a reset stops being an event. It becomes free.
