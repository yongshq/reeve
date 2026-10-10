# Supervision: the mechanism

`AGENTS.md` section 6 holds the rules a reeve acts on. This file holds only what that section does
not say: what a caretaker's line promises, why a `waiting` wake must be followed by a new watch at
once, how often `stale` is said, and the exact thresholds and limits behind `idle` and `wedged`.
Read it when a wake, a listing or a silence does not match what you expected.

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
- a watch says an undeliverable spool as its own wake line on stdout; a listing says it on stderr
  as `reeve: a pending notification cannot be delivered, check <dir>`, with no `undeliverable:` word

One case beyond the contract's: an undelivered line in the spool of a session `sessions_prune`
collects once it is past `session-retain`. Legitimate under that rule, and still a line that ends
unread.

An owner's watching right now (the caretaker stands aside for it, `AGENTS.md` section 6) is proved
by that session's own watch marker; an owner merely alive is not watching. The caretaker acts
within one of its polls, after leaving the terminal line in your spool if it is still owed.

## After a `waiting` wake: watch again at once

Every wake ends the watch, `waiting` included. A `waiting` errand is usually cleared by the liege
answering the dialog in the hand's own session, which gives you no turn: no reply arrives, so
nothing prompts you to watch again. Start `reeve-sentry` again in the same turn as the wake,
before you report it, whatever the liege is asked.

- Safe while the dialog still stands: that one stall wakes once. The new watch stays quiet over it
  until the hand reports a line, or a poll reads its session as anything but waiting (working,
  settled, even unknown, so it errs to an extra wake, never a missed one); after either, its next
  dialog wakes again. A second dialog that follows the first with neither between reads as the
  first, and stays silent.
- Once the dialog is answered, the listing shows the hand `working` again and no wake comes for it:
  progress, not news.
- The hand's later `done:`, `failed:`, `blocked:` or `needs-decision` reaches that watch as an
  ordinary wake. With no watch running, the caretaker frees the finished hand and leaves the line in
  your notifications, which arrive only when you next watch or list: if you never do, you go on
  reporting a finished hand as stuck.

## `stale`: once per gone session

A watch stops at the first errand with something to say, so a gone session said on every watch
would hide every other errand's wake for as long as it stands in flight.

- Once per gone session, across watches, re-armed when the hand writes a line or its session is
  seen alive again. A terminal line ends it. A session that cannot be read re-arms nothing.
- Once per errand for the whole home, not per reeve: a reeve that adopts it is not told again, and
  only the listing shows it gone.
- Only the owner's watch marks it said. An `--all` watch over another reeve's errand says the line
  once for itself, in a latch of its own, and leaves the one wake to the owner. So an orphan, whose
  owner never watches again, masks no `--all` watch past its first saying. A watch that cannot name
  its session shares that latch with every other such watch.
- Never cleaned up, and the listing still shows the session gone after the wake.

## `idle`: thresholds and limits

Additions to the `idle:` row of `AGENTS.md` section 6. Defaults: `config/hand-stale` is two hours,
`config/hand-stale-error` ten minutes. The wake waits for the session to read idle for the same 90
seconds a `waiting` one must.

- Once per silence, re-armed when the hand writes a line or its session is seen working again, or
  it is steered with `bin/reeve-steer`. Typed into its session by hand, a steer re-arms it only if
  a watch happens to see that turn working.
- The listing reads the sentry's clock and writes nothing; before the threshold it shows the
  silence without the word.
- The "a backend or harness cannot tell idle from busy" notice is said once per watch, for a hand
  silent past `config/hand-stale`.
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
- The "a backend or harness cannot tell idle from busy" notice is said once per watch, alongside the idle
  limit. An unreadable screen, or a backend that cannot capture, gives no wake and is said on stderr
  once per watch for a hand silent past the window.
- A threshold that is not a whole number turns the check off, which the sentry and the listing both
  say on stderr; 0 turns it off silently.
