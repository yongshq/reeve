# court

The liege wants to know where things stand and to settle whatever is waiting on them. Hold court:
report briefly, then walk the open decisions one at a time.

## Steps

1. **Gather.**

   ```sh
   reeve-status --all
   ```

   For anything with open decisions, `reeve-status <id>` for the questions themselves.

2. **Read the newest handoff for this manor**, if there is one, from `~/.claude/handoffs/`. The
   liege already has a handoff convention and a format they read fluently. Use it rather than
   inventing a second recap format.

3. **Open with one paragraph, not a table.** What landed, what is in flight, what is stuck. Tables
   are for `/muster`; court is a conversation.

4. **Then take the decisions one at a time.** This is the part that matters, and the order matters
   too: sort by what is blocking the most work, not by what arrived first.

   For each, give the liege everything needed to answer without reading a diff:
   - the question, in their vocabulary
   - why it came up
   - what each answer would mean
   - **your recommendation**, and why

   Then stop and wait. One question per turn. A list of five questions gets one answer.

5. **Record each answer as it arrives.** Append a `resolved [key=<key>]:` line to that errand's
   status file, then steer the hand if it is still alive, or note the answer for the relaunch if it
   is not. Never leave an answer only in the chat: the status file is the durable record and the
   chat is not.

6. **Close by naming the next action and whose it is.** Never end a court leaving the liege to
   guess what happens next.

## If there is nothing open

Say so in one line and stop. Do not pad it into a status report. "Three errands working, nothing
needs you" is a complete and useful answer.

## What not to do

- Do not relay a hand's status lines verbatim. Read them, decide what they mean, say that.
- Do not ask about something you can determine yourself. Check first.
- Do not batch questions to be efficient. One at a time is the whole point of holding court: a
  batched list gets a partial answer and the rest silently rots.
- Do not re-ask something the liege already settled. Check the status file for a `resolved` line
  before raising anything.
