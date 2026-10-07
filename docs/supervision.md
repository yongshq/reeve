# Supervision: the mechanism

`AGENTS.md` section 6 holds the rules a reeve acts on. This file holds only what that section does
not say: what a caretaker's line promises, and the exact thresholds and limits behind `idle` and
`wedged`. Read it when a wake, a listing or a silence does not match what you expected.

## What a caretaker's line promises

Beyond `AGENTS.md` section 6 (who delivers the line, and on which stream), exactly:

- it is kept until its line has actually been written, so a trimmed listing costs you nothing
- a listing's stderr line goes past a filter over the table, so one you grep costs you nothing
- a watch is the other reader, and there the single line it prints IS the report
- delivering marks that errand reported, so one event stays one report. It is recorded in a file of
  the errand's own, written by nothing else, and never as a cursor: a cursor says how much of a log
  a watch has read, and a delivery reads none of it. A delivery that cannot be recorded, which is a
  home that has gone read only, costs you a duplicate and never the line: the line is written first
  and the failure to record it is said out loud
- a second reader cannot take it twice or destroy the rest, and a claim on one expires rather than
  lasting as long as the reader's pid number
- it follows the errand if another session adopts it with `bin/reeve-adopt`
- a command asking some other question never spends one, which is what lets the handoff copy
  survive your reset
- a spool holding something it cannot give up says so, as a line of its own opening
  `undeliverable:`, instead of reading as an empty one and leaving you told that nothing is in
  flight

Three cases have no answer:

- an errand whose record names no session, which is every errand on a harness that exports no
  session id. There is no session to leave a line for, so the caretaker stops short of finishing
  the cleanup.
- a reader that throws the line away after it has arrived: `2>/dev/null` or `2>&1 |` over a listing,
  or a filter over the watch's own one line. The errand is marked reported and nothing says it again.
- an undelivered line in the spool of a session `sessions_prune` collects once it is past
  `session-retain`. Legitimate under that rule, and still a line that ends unread.

The owner's watching is proved by that session's own watch marker; an owner merely alive is not
watching. The caretaker acts within one of its polls, after leaving the terminal line in your spool
if it is still owed.

## `idle`: thresholds and limits

The sentry calls a hand `idle` once its status file has been silent past `config/hand-stale`
(default two hours) with its session idle, or past `config/hand-stale-error` (default ten minutes)
when the pane also shows the API error that ended the turn. The wake waits for the session to read
idle for the same 90 seconds a `waiting` one must.

- Once per silence, re-armed when the hand writes a line or its session is seen working again, or
  it is steered with `bin/reeve-steer`, so a steered hand that dies a second time wakes you a
  second time. Typed into its session by hand, a steer re-arms it only if a watch happens to see
  that turn working.
- `bin/reeve-status` shows `idle` only once the sentry's own clock says so, reading it and writing
  nothing; before that it shows the silence without the word.
- A backend or harness that cannot tell idle from busy never reads idle: the sentry says so once per
  watch, for a hand silent past `config/hand-stale`.
- A threshold set to anything but a whole number of seconds turns its half of the check off, which
  the sentry and the listing both say on stderr.

## `wedged`: thresholds and limits

A timeout on silence alone would cry wolf at every long turn, so the sentry calls a hand `wedged`
once its status file has been silent past `config/hand-wedged` (default two hours) with its session
working and its screen unchanged for that same window.

The screen is compared with its ticking chrome taken out: the spinner and its verb, the tip under
it, the composer and everything under it, and around the running tool and its spinner, timers,
counts and blinking bullets. So a turn that puts anything new on screen above the running tool's
own line resets the clock, while a tool whose only news is its own timer or line count reads as
still, and so does a single thinking block that shows nothing new for the whole window: that is
the price.

- Once per silence, re-armed when the hand writes a line, when its screen moves, when its session
  reads settled or waiting, or when it is steered with `bin/reeve-steer`.
- The clock starts the first time a watch sees the screen, so time with no watch running is not
  counted before then.
- `bin/reeve-status` shows `wedged` on the same second the sentry wakes, reading the screen again
  and writing nothing; before that a working hand shows as working.
- A backend or harness that cannot tell idle from busy never reads working: the sentry says so once
  per watch, alongside the idle limit.
- A screen that cannot be read, or a backend that cannot capture, cannot be judged: no wake, said on
  stderr once per watch for a hand silent past the window.
- A threshold that is not a whole number turns the check off, which the sentry and the listing both
  say on stderr; 0 turns it off silently.
