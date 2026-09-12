# survey

You have met a repository the household does not know. Work out what it is, propose it, record the
liege's answer.

## Why this is a skill and not a script

Grouping repositories into projects is a judgement. Getting it wrong sends a hand to edit the wrong
codebase, which is the most expensive mistake this household can make. So the script gathers
evidence and stops, and you put exactly one proposal to the liege.

## Steps

1. **Gather.**

   ```sh
   reeve-survey <path>
   ```

2. **Read the evidence, weighted.** Not all of it is equally good:

   | Evidence | Weight |
   |---|---|
   | a service URL or port in one repo that another repo serves | strongest. This is two halves of one product |
   | a generated client, OpenAPI document or `.proto` shared between them | strong |
   | sibling directories with a shared name stem (`foo-web`, `foo-api`) | strong |
   | the same git organisation | weak on its own. Everything one person owns shares an org |
   | living in the same parent directory | weakest. That is just where repositories live |

   The last two are what make a naive grouping wrong: on this machine every repository shares an
   org and a parent, so neither distinguishes anything.

3. **Form one proposal.** A manor name, this repository's role in it, and its siblings if any. Most
   repositories are their own manor, and that is a perfectly good answer. A monorepo covering web,
   desktop and mobile is one holding, not three.

4. **Put it to the liege once, with the evidence.**

   ```
   new repository: ~/yongshq/acme-web
     .env points at localhost:8080, and ~/yongshq/acme-api serves 8080
     same org, and they sit side by side
   proposal: manor "acme", this is the frontend, sibling acme-api
   ```

   Then ask. One question, and accept a correction without arguing.

5. **Record it.**

   ```sh
   reeve-survey --register <holding> --manor <manor> --path <abs> \
     [--role frontend] [--instructions AGENT.md] [--base main] \
     [--setup "<install command>"] [--test "<test command>"]
   ```

   `--instructions` matters more than it looks. A singular `AGENT.md` is auto-loaded by nothing, so
   without it recorded, every brief for that repository omits the house style.

   `--setup` is worth recording only when a fresh copy genuinely needs it. With a hardlinking
   package manager a cold copy costs milliseconds and the field is noise.

6. **Offer the nameplate.** A committed `.reeve.md` in the repository puts this knowledge where a
   teammate and a future hand both find it. The reeve never writes it directly, so offer a scribe
   errand and let the liege decide.

## What not to do

- Do not register a guess. An unconfirmed grouping is worse than no grouping, because it looks
  authoritative afterwards.
- Do not infer siblings from directory listing alone.
- Do not register a directory that is not a git repository. A directory can have the web, backend
  and mobile shape of a multi-repo project and still not be under version control at any level, in
  which case there is nothing to dispatch into yet. Say that rather than registering it.
