# handoff

Write down the part of this session that will not survive a reset, so the next reeve resumes
instead of restarting.

## When

- The liege asks for one.
- You are stopping for the day, or the liege is.
- `reeve-context` says you are past the threshold. **Offer, do not act.** A reset is the liege's
  call and mid-errand is the wrong moment for one.
- A long thread is about to change direction, and the reasoning behind the old direction is worth
  keeping.

## What is already safe without you

Do not write these down. They are on disk and `reeve-status --all` rebuilds them:

- every errand, its brief, its status log, its report
- which branch each one is on and how far ahead
- everything in `liege.md` and the manor files
- what any hand actually did, which lives in its own record

Copying them into a handoff makes a long document that hides the four things that matter.

## What is actually lost, and therefore what to write

1. **The goal above the errands.** Individual briefs say what each errand is for. Nothing says what
   the liege is trying to achieve overall, and that is what makes the difference between resuming
   and restarting.
2. **Threads raised but not dispatched.** Things mentioned in conversation that never became an
   errand. These vanish completely on a reset and nobody ever notices they are gone.
3. **Decisions made in chat.** Choices the liege made that have not reached a brief, a memory entry
   or the repository. If one is durable, put it in memory with `/inscribe` and leave a pointer here
   rather than a second copy.
4. **The next action, and whose move it is.** Never "continue where we left off".

## Steps

```sh
reeve-handoff new <manor>
```

It fills the factual sections from disk and leaves seams: `{TITLE}`, `{RESUME}`, `{GOAL}`,
`{OPEN}`, `{DECIDED}`, `{NEXT}`. Fill every one. A handoff with an unfilled seam is worse than
none, because it reads as complete.

Then:

1. **Run `/glean` first if you have not.** A handoff is for session working state; durable facts
   belong in memory, where they are budgeted and decay. Writing a fact into a handoff instead is
   how knowledge ends up somewhere nothing reads.
2. **Check the in-flight section against reality.** If an errand is mid-flight, say whether the
   next reeve should wait for it, steer it, or tear it down.
3. **Tell the liege it is written, and where.** One line.

## Writing it

Specific beats complete. "Discussed the CV page-break work, liege wants the build-cv guard
extended to the PNG too, not yet dispatched" is useful. "Various CV improvements discussed" is
noise that will be deleted unread.

Write for a reeve with no memory of this conversation, because that is exactly who reads it. Any
reference only this session understands is a dead link.

## What not to do

- Do not summarise the conversation. A handoff is not a transcript.
- Do not restate errand records. They survive on their own.
- Do not leave `{NEXT}` vague to seem open-minded. The next reeve will pick something, and it will
  be the wrong thing.
- Do not write one while an errand is mid-decision without saying so. An open question is the most
  important thing on the page.
