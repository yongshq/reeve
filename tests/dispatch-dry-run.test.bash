#!/usr/bin/env bash
# `reeve-dispatch --dry-run` prints every command it would run and changes
# nothing. It is the one script in the household that mutates a repository, so
# that promise is what makes it safe to run when you are unsure, and it was
# false: the copy of the office's settings.json into the errand directory was a
# bare `cp` rather than a `run` call, so a dry run left a file behind and then
# printed "nothing was changed."
#
# These cases assert on a MANIFEST of the whole reeve home and the whole code
# root, every path with a checksum, not on the absence of one filename. A second
# unguarded write somewhere else in the script has to fail this file too, or it
# only pins the bug that was already found.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }
# same <name> <before> <after>   a manifest comparison. Reports the difference
# rather than the two trees: a failure here is one or two lines of interest
# buried in a few dozen that never moved.
same() {
  if [ "$2" = "$3" ]; then ok "$1"; return; fi
  bad "$1" "$(diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed -e 's/^</before:/' -e 's/^>/after: /')"
}

# --- scratch everything ------------------------------------------------------
# This suite dispatches for real in one case, which creates worktrees and writes
# errand records, so it refuses to run anywhere a live home could be reached.
# -P because reeve-brief resolves the holding through `git rev-parse
# --show-toplevel`, which reports the real path behind macOS's temp symlink.
real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
[ -n "$real_home" ] || { printf 'FAIL  refusing to run: the real home could not be resolved\n'; exit 1; }
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
inherited=${REEVE_HOME:-}
REEVE_HOME="$SCRATCH/home"
for guard in "$inherited" "$real_home/.reeve"; do
  [ -n "$guard" ] || continue
  g=$(cd -P "$guard" 2>/dev/null && pwd) || g=$guard
  case $REEVE_HOME in
    "$g"|"$g"/*) printf 'FAIL  refusing to run: REEVE_HOME %s is inside %s\n' "$REEVE_HOME" "$g"; exit 1 ;;
  esac
done
export REEVE_HOME
mkdir -p "$REEVE_HOME"

REPO="$SCRATCH/holding"
mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" -c user.email=reeve@example.invalid -c user.name=reeve \
    -c commit.gpgsign=false commit -q --allow-empty -m init
WORKTREES="$SCRATCH/holding.worktrees"

# --- a stubbed code root ------------------------------------------------------
# Backend and harness are stubbed so no session is ever opened and nothing
# depends on which harness is installed on the machine running the suite.
# offices/ is copied rather than symlinked because one case needs an office whose
# settings.json is missing, and because the manifest below has to be able to see
# a write into the code root as well as one into the home.
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
rm -f "$STUB/offices/scribe.settings.json"      # the office-with-no-settings case
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_launch()          { return 0; }
ADAPTER
# Declares settings_flag, like claude does, so the rendered line carries the
# errand settings path and this suite can check it survives the guarded copy.
cat > "$STUB/harnesses/stub.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {settings} {prompt}"
settings_flag = "--settings {settings}"
prompt_mode = "argv"
HARNESS
# The same harness without one, for the office that declares no settings file: a
# harness that needs a path and is given none refuses at render, which is correct
# and is not the branch under test here.
sed '/^settings_flag/d' "$STUB/harnesses/stub.toml" > "$STUB/harnesses/bare.toml"

# --- the manifest -------------------------------------------------------------
# Every path under a tree, with a checksum for each file, so a changed byte, a
# new file and a removed one all show. Directories are listed too: a mkdir with
# nothing in it is still a change.
manifest() { # manifest <dir>
  ( cd "$1" 2>/dev/null || return 0
    find . | LC_ALL=C sort | while IFS= read -r p; do
      if [ -f "$p" ]; then printf '%s  %s\n' "$(cksum < "$p" | tr ' ' '-')" "$p"
      else printf 'dir  %s\n' "$p"; fi
    done )
}
snapshot() { # snapshot <label>   everything a dry run must leave untouched
  manifest "$REEVE_HOME"
  manifest "$STUB"
  git -C "$REPO" status --porcelain
  git -C "$REPO" worktree list
  [ -e "$WORKTREES" ] && printf 'worktree parent exists\n'
  return 0
}

brief_for() { # brief_for <id> <office>
  "$ROOT/bin/reeve-brief" "$1" "$REPO" --office "$2" >/dev/null || return 1
  local b="$REEVE_HOME/errands/$1/brief.md"
  # Dispatch refuses a brief still holding a seam, rightly, so fill both first.
  sed -e 's/{INTENT}/the liege said so/' -e 's/{SPEC}/build the thing/' "$b" > "$b.filled" \
    && mv "$b.filled" "$b"
}

dispatch() { # dispatch <id> <harness> [args...]  -> sets OUT, ERR, RC
  local id=$1 harness=$2; shift 2
  ERR="$SCRATCH/err.$id"
  OUT=$(REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" "$id" \
          --backend stub --harness "$harness" "$@" 2>"$ERR"); RC=$?
  ERR=$(cat "$ERR")
}

# --- 1. the office WITH a settings file --------------------------------------
brief_for guarded artificer || bad "1 reeve-brief refused"
before=$(snapshot)
dispatch guarded stub --dry-run
after=$(snapshot)

eq  "1 the dry run succeeds"                  "$RC" 0
has "1 it still claims nothing was changed"   "$OUT" "nothing was changed."
same "1 the home and the code root are untouched" "$before" "$after"
has "1 the copy is printed as a command it would run" "$OUT" \
    "would run: cp $STUB/offices/artificer.settings.json $REEVE_HOME/errands/guarded/settings.json"

# The subtlety that decides whether this is one line or more: the settings path
# is consumed to render the launch line the dry run prints. Skipping the copy
# must not change that line, so the flag still carries the path even though the
# file it names does not exist.
has "1 the launch line still carries the settings path" "$OUT" \
    "--settings $REEVE_HOME/errands/guarded/settings.json"
eq  "1 and the file it names was not created" \
    "$([ -e "$REEVE_HOME/errands/guarded/settings.json" ] && echo present || echo absent)" absent

# --- 2. the office with NO settings file -------------------------------------
# The warning is part of what a dry run is for: it is how the reeve finds out,
# before dispatching for real, that a hand would run on harness defaults.
brief_for unguarded scribe || bad "2 reeve-brief refused"
before=$(snapshot)
dispatch unguarded bare --dry-run
after=$(snapshot)

eq  "2 the dry run succeeds"                  "$RC" 0
has "2 it warns about the missing settings"   "$ERR" "declares no settings.json"
has "2 it still claims nothing was changed"   "$OUT" "nothing was changed."
nas "2 no settings flag reaches the line"     "$OUT" "--settings"
nas "2 and no copy is claimed"                "$OUT" "would run: cp"
same "2 the home and the code root are untouched" "$before" "$after"

# --- 3. a real dispatch still copies it --------------------------------------
# Asserted on the file and the record, never by starting a session: the stub
# backend's launch does nothing, so nothing is ever running.
brief_for real artificer || bad "3 reeve-brief refused"
dispatch real stub
settings="$REEVE_HOME/errands/real/settings.json"
eq  "3 a real dispatch succeeds"              "$RC" 0
eq  "3 the settings file is there"            "$([ -f "$settings" ] && echo present || echo absent)" present
if cmp -s "$STUB/offices/artificer.settings.json" "$settings"
then ok "3 and is a copy of the office's own"
else bad "3 and is a copy of the office's own" "the two files differ"; fi
eq  "3 the endpoint is recorded"              "$(grep -m1 '^target=' "$REEVE_HOME/state/real.meta")" "target=stub:1"
case $(grep -m1 '^branchMade=' "$REEVE_HOME/state/real.meta") in
  "branchMade=$(git -C "$REPO" rev-parse refs/heads/"$(grep -m1 '^branch=' "$REEVE_HOME/state/real.meta" | cut -d= -f2-)") "[0-9]*)
    ok "3 the record says the household made the branch, by its birth" ;;
  *) bad "3 the record says the household made the branch, by its birth" \
         "$(grep '^branchMade=' "$REEVE_HOME/state/real.meta")" ;;
esac
eq  "3 the copy was really created"           "$([ -d "$WORKTREES/artificer-real" ] && echo present || echo absent)" present

# --- 4. and a dry run after a real one changes nothing either ----------------
# The errand directory now holds a settings.json. An unguarded copy would
# overwrite it, which a checksum manifest sees only because the office file and
# the errand file are identical today: the point of the case is that the dry run
# must not write at all, so it runs against an office file deliberately made to
# differ from what the errand already has.
printf '{"permissions":{"allow":["Bash(true)"]}}\n' > "$STUB/offices/warden.settings.json"
brief_for second warden || bad "4 reeve-brief refused"
cp "$STUB/offices/artificer.settings.json" "$REEVE_HOME/errands/second/settings.json"
before=$(snapshot)
dispatch second stub --dry-run
after=$(snapshot)
eq  "4 the dry run succeeds"                          "$RC" 0
same "4 an existing settings file is not overwritten" "$before" "$after"

# --- 5 to 9. the household browser -------------------------------------------
# An office that allows the browser gets its MCP config generated into the
# errand directory and passed on the launch line, through run() like every other
# write. Without one, the dispatch goes ahead anyway and says why. node, npx and
# Chrome are stubs, so no browser is launched and nothing is fetched.
cat > "$STUB/harnesses/browsing.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {mcp} {settings} {prompt}"
settings_flag = "--settings {settings}"
mcp_flag = "--no-mcp"
browser_flag = "--mcp-config {browser}"
prompt_mode = "argv"
HARNESS
STUBS="$SCRATCH/stubs"
mkdir -p "$STUBS"
printf '#!/bin/sh\necho v22.12.0\n' > "$STUBS/node"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/npx"
chrome="$SCRATCH/Chrome for Testing.app/chrome"
mkdir -p "$(dirname "$chrome")"
printf '#!/bin/sh\n' > "$chrome"
chmod +x "$STUBS/node" "$STUBS/npx" "$chrome"
mkdir -p "$REEVE_HOME/config"
printf '%s\n' "$chrome" > "$REEVE_HOME/config/browser-chrome"
export REEVE_NO_CARETAKER=1
meta_of() { grep -m1 "^$2=" "$REEVE_HOME/state/$1.meta" | cut -d= -f2-; }

brief_for look artificer || bad "5 reeve-brief refused"
before=$(snapshot)
PATH="$STUBS:$PATH" dispatch look browsing --dry-run
after=$(snapshot)
eq  "5 the dry run succeeds"                           "$RC" 0
same "5 the home and the code root are untouched"      "$before" "$after"
has "5 the config is printed as a write it would make" "$OUT" \
    "would run: browser_config_write $REEVE_HOME/errands/look/browser.json $chrome"
has "5 the launch line carries it, after the mcp flag" "$OUT" \
    "--no-mcp --mcp-config $REEVE_HOME/errands/look/browser.json"
has "5 and the dry run says which browser"             "$OUT" "browser: reeve-browser, headless"

PATH="$STUBS:$PATH" dispatch look browsing
cfg="$REEVE_HOME/errands/look/browser.json"
eq  "6 a real dispatch succeeds"                       "$RC" 0
eq  "6 the config is written"   "$([ -f "$cfg" ] && echo present || echo absent)" present
has "6 naming the household server"                    "$(cat "$cfg" 2>/dev/null)" '"reeve-browser"'
has "6 and the Chrome it found"                        "$(cat "$cfg" 2>/dev/null)" "$chrome"
has "6 whose tools the errand's settings pre-approve" \
    "$(cat "$REEVE_HOME/errands/look/settings.json")" '"mcp__reeve-browser"'
has "6 the record says what it went out with"          "$(meta_of look browser)" "reeve-browser"
has "6 and so does the summary"                        "$OUT" "browser  reeve-browser"

printf '%s\n' "$SCRATCH/no-chrome-here" > "$REEVE_HOME/config/browser-chrome"
brief_for blind artificer || bad "7 reeve-brief refused"
PATH="$STUBS:$PATH" dispatch blind browsing --dry-run
nas "7 no mcp config reaches the launch line"          "$OUT" "--mcp-config"
has "7 the dry run names the reason"                   "$OUT" "browser: none: config/browser-chrome"
PATH="$STUBS:$PATH" dispatch blind browsing
eq  "7 no Chrome is no reason to refuse"               "$RC" 0
has "7 it says there is no browser, and why"           "$ERR" \
    "no household browser for this hand: config/browser-chrome names $SCRATCH/no-chrome-here"
has "7 and what the hand will do instead"              "$ERR" "it will verify nothing visually"
eq  "7 and none is written" \
    "$([ -e "$REEVE_HOME/errands/blind/browser.json" ] && echo present || echo absent)" absent
has "7 the record keeps the reason"                    "$(meta_of blind browser)" \
    "none: config/browser-chrome"
printf '%s\n' "$chrome" > "$REEVE_HOME/config/browser-chrome"

brief_for peek scout || bad "8 reeve-brief refused"
PATH="$STUBS:$PATH" dispatch peek browsing --dry-run
eq  "8 an office without the allow rule dispatches"    "$RC" 0
nas "8 and gets no browser"                            "$OUT" "--mcp-config"
nas "8 nor any word about one"                         "$OUT$ERR" "browser"

brief_for plain artificer || bad "9 reeve-brief refused"
PATH="$STUBS:$PATH" dispatch plain stub --dry-run
eq  "9 a harness with no browser_flag still dispatches" "$RC" 0
has "9 and says the harness is why"                    "$ERR" \
    "harness stub declares no browser_flag"
nas "9 with no config written or passed"               "$OUT" "browser_config_write"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
