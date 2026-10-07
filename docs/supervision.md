# Supervision: the mechanism

`AGENTS.md` section 6 holds the rules a reeve acts on. This file holds how they work: what a
caretaker's line promises, and the exact thresholds and limits behind `idle` and `wedged`. Read it
when a wake, a listing or a silence does not match what you expected.

## What a caretaker's line promises

A caretaker leaves the terminal line for the session that briefed the errand, and either
`bin/reeve-sentry` or a whole-fleet listing (`bin/reeve-status` bare, `--all` or `--orphans`) hands
it over the next time you run one. Exactly:

- it is kept until its line has actually been written, so a trimmed listing costs you nothing
- a listing writes those lines on STDERR, so one you grep costs you nothing either: a filter takes
  the table, the line goes past it
- a watch is the other reader, and there the single line it prints IS the report
- delivering marks that errand reported, so one event stays one report. It is recorded in a file of
  the errand's own, written by nothing else, and never as a cursor: a cursor says how much of a log
  a watch has read, and a delivery reads none of it. A delivery that cannot be recorded, which is a
  home that has gone read only, costs you a duplicate and never the line: the line is written first
  and the failure to record it is said out loud
- a second reader cannot take it twice or destroy the rest, and a claim on one expires rather than
  lasting as long as the reader's pid number
- it follows the errand if another session adopts it with `bin/reeve-adopt`
- a command asking some other question never spends one, so `bin/reeve-handoff new` copies pending
  lines into the handoff instead, which is what makes them survive your reset. `bin/reeve-status
  <id>`, the single-errand form, never delivers either
- a spool holding something it cannot give up says so, as a line of its own opening
  `undeliverable:`, instead of reading as an empty one

Three cases have no answer:

- an errand whose record names no session, which is every errand on a harness that exports no
  session id. There is no session to leave a line for, so nothing is left, and instead the caretaker
  stops short of finishing the cleanup. The errand keeps its copy and stays in flight, where the
  next watch on that home reports it.
- a reader that throws the line away after it has arrived: `2>/dev/null` or `2>&1 |` over a listing,
  or a filter over the watch's own one line. The errand is marked reported and nothing says it again.
- an undelivered line in the spool of a session `sessions_prune` collects once it is past
  `session-retain`. Legitimate under that rule, and still a line that ends unread.

The caretaker stands aside only for an errand whose owner is watching right now, proved by that
session's own watch marker; an owner merely alive is not watching. It acts within one of its polls.

## `idle`: thresholds and limits

The sentry calls a hand `idle` once its status file has been silent past `config/hand-stale`
(default two hours) with its session idle, or past `config/hand-stale-error` (default ten minutes)
when the pane also shows the API error that ended the turn. The wake waits for the session to read
idle for the same 90 seconds a `waiting` one must.

- Once per silence, re-armed when the hand writes a line or its session is seen working again, or
  it is steered with `bin/reeve-steer`, so a steered hand that dies a second time wakes you a
  second time. Typed into its session by hand, a steer re-arms it only if a watch happens to see
  that turn working.
- A `blocked:` hand is not checked, because it already woke you.
- `bin/reeve-status` shows `idle` in its process column only once the sentry's own clock says so,
  reading it and writing nothing, so the listing and the wake never disagree; before that it shows
  the silence without the word.
- A backend or harness that cannot tell idle from busy never reads idle, so the check cannot fire
  there: the sentry says so on stderr, once per watch, for a hand silent past `config/hand-stale`.
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
- `bin/reeve-status` shows `wedged` in its process column on the same second the sentry wakes,
  reading the screen again and writing nothing; before that a working hand shows as working.
- A backend or harness that cannot tell idle from busy never reads working, so the check cannot
  fire there: the sentry says so on stderr, once per watch, alongside the idle limit.
- A screen that cannot be read, or a backend that cannot capture, cannot be judged: no wake, said on
  stderr once per watch for a hand silent past the window.
- A threshold that is not a whole number turns the check off, which the sentry and the listing both
  say on stderr; 0 turns it off silently.
