# inscribe

The liege told you to remember something. Record it in the right place, at the right tier, with
evidence, and confirm before you write.

Load the `memory` skill first. It owns the judgement; this skill is the procedure.

## Steps

1. **Find the fact.** The liege's sentence is often a request, not a fact. "Remember I hate merge
   commits" is a preference; the fact to store is "prefers rebase onto main, linear history, no
   merge commits". Write the fact, not the request.

2. **Name the evidence.** Here it is simply that the liege said so in this session, which is the
   strongest evidence there is. Say so.

3. **Pick the scope.** Use the table in the `memory` skill. If it is genuinely about one repo, say
   so and offer a scribe errand instead of writing it into the home. If it describes how the reeve
   behaves rather than who the liege is, stop here and load `self-update` instead: that belongs in
   the contract, where it holds on every clone.

4. **Pick the tier.** A standing instruction from the liege is `P`. A fact about a codebase is `a`.
   Something true only for now is `p`.

5. **Check for an existing entry.** `bin/reeve-memory list --scope <scope>`. If this restates one,
   refresh or reword the existing entry rather than adding a second.

6. **Confirm, then write.** Show the liege the exact line and where it is going, in one short
   block. Then:

   ```sh
   bin/reeve-memory add --scope <scope> --tier <a|p|P> "<the fact>"
   ```

7. **Report the budget** if the file grew past it.

## Confirming

One block, no preamble:

```
liege.md, pinned:
  Never push or open a pull request without being asked, on any repo.
```

Then write it. Do not ask whether to proceed; the liege already told you to remember it. Confirming
is showing your work, not seeking permission. The only time to stop and ask is when the scope is
genuinely ambiguous, and then ask about the scope, not about whether to write.

## What not to do

- Do not paraphrase the liege into something vaguer than what they said.
- Do not store the conversation. Store the fact.
- Do not write it in two places "to be safe". One owner per fact.
- Do not bundle three facts into one entry: an entry holding three facts cannot decay, cannot be
  cited, and cannot be struck cleanly.
