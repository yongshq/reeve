#!/usr/bin/env bash
# The household browser: one MCP server a hand may have, and only a hand whose
# office allows it. Three things have to agree for it to work without a dialog:
# the server name in the generated config, the allow rule in the office's
# settings, and the flags that keep every other MCP source out. Each half is
# checked here, and so is every reason browser_check gives for saying no, since
# a dispatch that cannot name why there is no browser leaves the hand unable to.
#
# Nothing here launches a browser or touches the network: node, npx and Chrome
# are stubs on a PATH and a path in a scratch home.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
}
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() {
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "no [$3] in: $2"; fi
}
nas() {
  if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "has [$3] in: $2"; else ok "$1"; fi
}

SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/home"
mkdir -p "$REEVE_HOME/config"

# A PATH holding only what the library and browser_check use, plus stubs, so a
# machine with or without a real node gives the same answers.
tools="$SCRATCH/tools"
mkdir -p "$tools"
for t in sed grep uname dirname cat tr head readlink basename; do
  p=$(command -v "$t") && ln -s "$p" "$tools/$t"
done
stub() { # stub <dir> <name> <stdout>
  mkdir -p "$1"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$3" > "$1/$2"
  chmod +x "$1/$2"
}
check() { # check <extra-path-dir>   runs browser_check, sets OUT and RC
  OUT=$(PATH="$1:$tools" "$BASH" -c '. "$1/bin/reeve-lib.sh"; browser_check' _ "$ROOT" 2>&1); RC=$?
}

# A Chrome that exists, at a path with the spaces a macOS app path has, and a
# quote, which the generated JSON has to escape.
chrome="$SCRATCH/Chrome for \"Testing\".app/chrome"
mkdir -p "$(dirname "$chrome")"
printf '#!/bin/sh\n' > "$chrome"; chmod +x "$chrome"

# --- 1. every reason it says no ---------------------------------------------
check "$SCRATCH/none"
eq  "1 no node: refuses"                 "$RC" 1
has "1 no node: says so"                 "$OUT" "node is not on PATH"

stub "$SCRATCH/nonpx" node v22.12.0
check "$SCRATCH/nonpx"
has "1 no npx: says so"                  "$OUT" "npx is not on PATH"

for v in v18.20.0 v20.18.1 v21.7.0 v22.11.0; do
  stub "$SCRATCH/old$v" node "$v"; stub "$SCRATCH/old$v" npx ''
  check "$SCRATCH/old$v"
  eq  "1 node $v is too old" "$RC" 1
  has "1 node $v names the floor" "$OUT" "too old for chrome-devtools-mcp@"
done
stub "$SCRATCH/odd" node 'not a version'; stub "$SCRATCH/odd" npx ''
check "$SCRATCH/odd"
has "1 an unreadable version is named"   "$OUT" "which is not a version"

stub "$SCRATCH/good" node v22.12.0; stub "$SCRATCH/good" npx ''
printf '%s\n' "$SCRATCH/no-such-chrome" > "$REEVE_HOME/config/browser-chrome"
check "$SCRATCH/good"
eq  "1 a configured Chrome that is missing: refuses" "$RC" 1
has "1 and names the path it was given"  "$OUT" \
    "config/browser-chrome names $SCRATCH/no-such-chrome"

# --- 2. and when it says yes ------------------------------------------------
for v in v20.19.0 v22.12.0 v23.0.0 v24.1.2; do
  stub "$SCRATCH/new$v" node "$v"; stub "$SCRATCH/new$v" npx ''
  printf '  %s  \n' "$chrome" > "$REEVE_HOME/config/browser-chrome"
  check "$SCRATCH/new$v"
  eq "2 node $v with a configured Chrome is usable" "$RC" 0
done
eq  "2 the path keeps its spaces, trimmed only at the ends" "$OUT" "$chrome"

# --- 3. the generated config ------------------------------------------------
cfg="$SCRATCH/browser.json"
"$BASH" -c '. "$1/bin/reeve-lib.sh"; browser_config_write "$2" "$3"' _ "$ROOT" "$cfg" "$chrome"
body=$(cat "$cfg")
has "3 one server, named for the allow rule" "$body" '"reeve-browser": {'
has "3 the package is pinned"            "$body" '"chrome-devtools-mcp@'
nas "3 never an unpinned latest"         "$body" '@latest'
has "3 its own profile, thrown away"     "$body" '"--isolated"'
has "3 no window"                        "$body" '"--headless"'
has "3 launches the Chrome found"        "$body" '"--executablePath"'
has "3 no usage reporting"               "$body" '"--no-usage-statistics"'
for never in browserUrl wsEndpoint autoConnect 9222 userDataDir; do
  nas "3 never connects to a running browser: $never" "$body" "$never"
done
if command -v python3 >/dev/null 2>&1; then
  got=$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
s = c["mcpServers"]
assert list(s) == ["reeve-browser"], list(s)
a = s["reeve-browser"]["args"]
print(a[a.index("--executablePath") + 1])' "$cfg" 2>&1)
  eq "3 valid JSON, the path round trips with its quote and spaces" "$got" "$chrome"
else
  ok "3 valid JSON (skipped: no python3 on this machine)"
fi

# --- 4. the opt in and the allow rule are one fact --------------------------
# browser_wanted reads the allow rule, so the offices that get the server and
# the offices pre-approved for its tools cannot drift apart. These pin which
# offices that is today.
wanted=$(for o in artificer warden scout scribe steward; do
  "$BASH" -c '. "$1/bin/reeve-lib.sh"; browser_wanted "$2"' _ "$ROOT" "$o" && printf '%s ' "$o"
done)
eq  "4 the builder and the reviewer, and nobody else" "$wanted" "artificer warden "
server=$("$BASH" -c '. "$1/bin/reeve-lib.sh"; printf %s "$BROWSER_SERVER"' _ "$ROOT")
for o in artificer warden; do
  has "4 $o pre-approves the server's tools" "$(cat "$ROOT/offices/$o.settings.json")" \
      "\"mcp__$server\""
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/offices/$o.settings.json" \
      && ok "4 $o settings are still valid JSON" || bad "4 $o settings are still valid JSON"
  fi
done

# --- 5. the launch line -----------------------------------------------------
H="$ROOT/bin/reeve-harness"
B=/abs/errands/demo/brief.md
S=/abs/errands/demo/settings.json
line=$("$H" render claude "$B" --settings "$S" --browser /abs/errands/demo/browser.json)
has "5 the household server is passed"   "$line" "--mcp-config /abs/errands/demo/browser.json"
has "5 next to the flag that keeps the rest out" "$line" \
    "--strict-mcp-config --no-chrome --mcp-config /abs/errands/demo/browser.json"
before=${line%% -- *}
case $before in *"--mcp-config /abs/errands/demo/browser.json"*) ok "5 and before the prompt" ;;
  *) bad "5 and before the prompt" "$line" ;; esac
nas "5 no unexpanded placeholder"        "$line" "{browser}"
plain=$("$H" render claude "$B" --settings "$S")
nas "5 without it, no mcp config at all" "$plain" "--mcp-config"
out=$("$H" render codex "$B" --browser /abs/x.json 2>&1); rc=$?
eq  "5 a harness with no way to pass it refuses" "$rc" 1
has "5 and says which key is missing"    "$out" "declares no browser_flag"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
