#!/usr/bin/env bash
# The launch line is the seam between reeve and any agent CLI. These cases exist
# because each one was a real bug: a single-item array parsed as empty, a bare
# glob bracket ate the parse, and a variadic flag swallowed the prompt.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REEVE_HOME=$(mktemp -d)
H="$ROOT/bin/reeve-harness"
PASS=0; FAIL=0
ck() { # ck <name> <expect-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want substring: %s\n      got: %s\n' "$1" "$2" "$3"; fi
}
nk() { # nk <name> <expect-ABSENT-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then FAIL=$((FAIL+1)); printf 'FAIL  %s\n      should NOT contain: %s\n' "$1" "$2"
  else PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; fi
}

B=/abs/errands/demo/brief.md
S=/abs/errands/demo/settings.json
line=$("$H" render claude "$B" --settings "$S")

ck "binary present"                 "claude"                          "$line"
ck "env prefix rendered"            "env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="  "$line"
ck "errand dir granted"             "--add-dir /abs/errands/demo"     "$line"
ck "settings file passed"           "--settings $S"                   "$line"
ck "configured mcp servers off"     "--strict-mcp-config"             "$line"
ck "built-in chrome mcp off"        "--no-chrome"                     "$line"
nk "no mcp config alongside it"     "--mcp-config"                    "$line"
ck "argv separator present"         " -- "                            "$line"
ck "prompt points at the brief"     "$B"                              "$line"
nk "brief text is NOT inlined"      "Definition of done"              "$line"
nk "no unexpanded placeholder"      "{"                               "$line"

# model and effort are optional slots: absent unless asked for, and an effort
# that renders away to nothing is worse than no flag, because dispatch accepts
# --effort and the hand silently runs at the default.
nk "no effort unless asked"  "--effort"       "$line"
withe=$("$H" render claude "$B" --settings "$S" --model opus --effort high)
ck "model reaches the line"  "--model opus"   "$withe"
ck "effort reaches the line" "--effort high"  "$withe"

# arrays: single item and multi item both parse fully
ck "single item array"   "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false" "$("$H" get claude env)"
ck "multi item array 1"  "CLAUDE.md"  "$("$H" get claude instruction_files)"
ck "multi item array 2"  "AGENTS.md"  "$("$H" get claude instruction_files)"
ck "multi detect_env 2"  "CLAUDE_CODE_SESSION_ID" "$("$H" get claude detect_env)"

# quoting: a JSON value with quotes and a glob char must survive as one token
oc=$("$H" render opencode "$B" 2>/dev/null || true)
ck "opencode flag prompt mode" "--prompt" "$oc"
ck "json env survives quoting" 'OPENCODE_CONFIG_CONTENT=' "$oc"
tokens=$(python3 -c "import shlex,sys; print(len(shlex.split(sys.argv[1])))" "$oc" 2>/dev/null || echo 0)
if [ "$tokens" -ge 4 ]; then PASS=$((PASS+1)); printf 'ok    opencode line is shell-parseable (%s tokens)\n' "$tokens"
else FAIL=$((FAIL+1)); printf 'FAIL  opencode line does not shell-parse\n'; fi

# refusals
out=$("$H" render claude relative/path.md --settings "$S" 2>&1 || true)
ck "relative brief refused" "must be absolute" "$out"
out=$("$H" check codex 2>&1 || true)
ck "uninstalled harness refused" "not installed" "$out"
out=$("$H" render claude "$B" 2>&1 || true)
ck "missing settings refused" "needs a settings file" "$out"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
