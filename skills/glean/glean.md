# glean

End of a working session. Harvest what was actually learned, and nothing else.

Load the `memory` skill first. This skill is where its evidence rule gets tested, because at the
end of a long session almost everything feels worth keeping and almost none of it is.

## Steps

1. **Report the budget before you start.**

   ```sh
   reeve-memory budget
   ```

2. **List candidates, with their evidence, before writing anything.** Go back through the session
   and for each candidate write the fact and the evidence in one line. If you cannot name the
   evidence, the candidate is already rejected. Expect to reject most of them.

3. **Route each survivor by scope** using the `memory` skill's table. Facts about one repo are not
   yours to write: collect them and offer a single scribe errand at the end.

4. **Check each against what is already there.** `reeve-memory list --scope <scope>`. A restatement
   is a refresh or a rewording, never a second entry.

5. **Write them.** `reeve-memory add` per survivor, correct tier.

6. **Handle what has gone stale.**

   ```sh
   reeve-memory stale
   ```

   For each stale entry, one of three things, and you must pick deliberately:
   - You saw evidence this session that it is still true: refresh it, and name that evidence.
   - You saw evidence it is false: strike it, and add the correction.
   - You saw nothing either way: **strike it.** This is the common case and it is the right answer.
     An unconfirmed claim that nobody has checked in a month is not knowledge.

7. **Report the budget again.** If it is over, follow the reduction ladder in the `memory` skill and
   open a decision rather than cutting quietly.

## Reporting to the liege

Counts and the interesting parts, never the full list:

```
gleaned this session
  added      3   (2 about this project, 1 about you)
  refreshed  1   (the test command, confirmed by running it)
  archived   4   (stale, nothing this session confirmed them)
  budget     1,240 of 6,000

one fact belongs in the repo rather than my notes:
  portfolio: e2e tests need the dev server on 5173 already running
  that is a scribe errand, say the word and I will send it
```

## The limits, which you must respect rather than work around

- **You can only preserve what the session still knows.** This is not a reconciliation against the
  repository, the branch list, or reality. Do not go hunting for facts the session did not produce.
- **Never end over budget as an accepted exception.** Either reduce it or open a decision.
- **Never describe the session as safe to end while over budget.** That is exactly the state that
  quietly degrades every future session.
- **An entry is never evidence for itself.** If the only support for refreshing something is that
  it is written down, let it go stale.
