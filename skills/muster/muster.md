# muster

A full accounting of the fleet, on demand. Where `court` is a conversation, muster is a table.

## Steps

1. `reeve-status --all`
2. For each errand not simply working, `reeve-status <id>` for the detail.
3. Present it in one table, **blocked and waiting first**, working last. The liege is scanning for
   what needs them, so anything needing them goes at the top.

## Format

```
needs you
  find-cv-styles    scout       1 question open, asked 20 minutes ago
  refresh-auth      artificer   blocked: no .env in the copy

working
  tidy-footer       artificer   committing, 2 commits so far
  audit-a11y        scout       reading route components

ready
  print-styles      artificer   branch fix/print-styles, 3 commits, not pushed

nothing in flight for: <the other manors>
```

## Include, per errand

The office, the holding, what it last reported, and for finished work the branch and commit count.
Never the worktree path unless the liege asks: they cannot act on it and it is noise in a table.

## Flag these explicitly, they are easy to miss

- **A divergence.** An errand reporting done with a question never answered is not finished, whatever
  it says. `reeve-status` marks it; carry that mark through to the table.
- **A silent death.** An errand whose session is gone with no terminal line. Say the hand vanished
  and say what it last reported.
- **Unlanded work.** A branch with commits that the base does not have. That is the state where
  work gets forgotten, so name it.
- **A stale copy.** An errand torn down whose branch still exists. It is not lost, but it is not
  landed either.

## After the table

One line on the single most useful next action, and then stop. Do not propose five.
