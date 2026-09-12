# strike

The liege told you to forget something. Retire it to the archive.

Load the `memory` skill first.

## Steps

1. **Find what they mean.** `reeve-memory list` and match against their words. If two entries
   could be it, show both and ask which. Striking the wrong fact is worse than asking.

2. **Check whether it is wrong, or just done.** These are different and the liege may not have
   distinguished them:
   - **Wrong**: it was never true, or is no longer true. Strike it.
   - **Superseded**: something replaced it. Strike it and add the replacement in one step, so the
     household is never briefly missing both.
   - **Finished**: it described work that is now complete. Strike it. This is what perishable
     entries are for.

3. **Strike it.**

   ```sh
   reeve-memory strike --scope <scope> "<distinctive phrase>"
   ```

4. **Say where it went.** The entry moved to `archive.md`, which is append only and never loaded.
   Nothing was deleted, so nothing is unrecoverable. Say that plainly: the liege should know that
   "forget this" is reversible.

## If it is not in memory at all

Say so, and check whether it lives in the repo's own `.reeve.md` instead. If it does, removing it
needs a scribe errand, because the reeve never edits a project file. Offer that.

## What not to do

- Do not delete. The archive exists so that retiring knowledge is free and reversible.
- Do not strike a pinned entry without confirming. Pinned means the liege chose it deliberately.
- Do not strike a whole file because several entries in it are stale. Strike entries.
