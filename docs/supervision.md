# Supervision: the mechanism

`AGENTS.md` section 6 holds the rules a reeve acts on. This file holds only what that section does
not say: what a caretaker's line promises, and the exact thresholds and limits behind `idle` and
`wedged`. Read it when a wake, a listing or a silence does not match what you expected.

## What a caretaker's line promises

Additions to `AGENTS.md` section 6 (who delivers the line, and on which stream):

- it is kept until its line has actually been written, so a trimmed listing costs you nothing
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
  `undeliverable:`, instead of reading as an empty one. A listing says it as a `cannot be
  delivered` warning on stderr, with no `undeliverable:` word

One case beyond the contract's: an undelivered line in the spool of a session `sessions_prune`
collects once it is past `session-retain`. Legitimate under that rule, and still a line that ends
unread.

An owner's watching right now (the caretaker stands aside for it, `AGENTS.md` section 6) is proved
by that session's own watch marker; an owner merely alive is not watching. The caretaker acts
within one of its polls, after leaving the terminal line in your spool if it is still owed.

## `idle`: thresholds and limits

Additions to the `idle:` row of `AGENTS.md` section 6. Defaults: `config/hand-stale` is two hours,
`config/hand-stale-error` ten minutes. The wake waits for the session to read idle for the same 90
seconds a `waiting` one must.

- Once per silence, re-armed when the hand writes a line or its session is seen working again, or
  it is steered with `bin/reeve-steer`. Typed into its session by hand, a steer re-arms it only if
  a watch happens to see that turn working.
- The listing reads the sentry's clock and writes nothing; before the threshold it shows the
  silence without the word.
- The "cannot tell idle from busy" notice is said once per watch, for a hand silent past
  `config/hand-stale`.
- A threshold set to anything but a whole number of seconds turns its half of the check off, which
  the sentry and the listing both say on stderr.

## `wedged`: thresholds and limits

Additions to the `wedged:` row of `AGENTS.md` section 6. Default: `config/hand-wedged` is two
hours, for the status file's silence and for the screen unchanged. A timeout on silence alone would
cry wolf at every long turn, hence the screen test.

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
- The listing shows `wedged` on the same second the sentry wakes, reading the screen again and
  writing nothing; before that a working hand shows as working.
- The "cannot tell idle from busy" notice is said once per watch, alongside the idle limit. An
  unreadable screen, or a backend that cannot capture, gives no wake and is said on stderr once per
  watch for a hand silent past the window.
- A threshold that is not a whole number turns the check off, which the sentry and the listing both
  say on stderr; 0 turns it off silently.
