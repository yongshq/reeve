#!/usr/bin/env bash
# A reeve has a short name, and every hand it sends out carries it:
# `Aldric's scout: fix-auth` in the backend's list is whose hand, which office,
# what for. The session id stays the identity; the name is what the liege reads.
#
# What is pinned here is what makes a name worth having. Two live reeves never
# share one, including two that start in the same instant. A /clear keeps it,
# through the pane the session ran in. A handoff gives it back through claim,
# which refuses only a live rival on another pane. The pool and the label shape
# both yield to the liege's config. And a session with no id degrades to an
# unnamed label rather than failing.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
eq() { # eq <name> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$1" "$2" "$3"; fi
}
ne() { # ne <name> <unwanted> <got>
  if [ "$2" != "$3" ]; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      should differ from: %s\n' "$1" "$2"; fi
}
has() { # has <name> <haystack> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); printf 'ok    %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s\n      missing: %s\n      in:      %s\n' "$1" "$3" "$2"; fi
}

# --- scratch everything ------------------------------------------------------
# Session records and errand metadata are written below, so this refuses rather
# than trusts that mktemp put it nowhere near a real home.
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
refuse_if_inside() { # refuse_if_inside <home that may hold live records>
  local h=$1 p
  [ -n "$h" ] || return 0
  p=$(cd -P "$h" 2>/dev/null && pwd) && h=$p
  case $REEVE_HOME in
    "$h"|"$h"/*)
      printf 'FAIL  refusing to run: REEVE_HOME %s is inside the real reeve home %s\n' \
        "$REEVE_HOME" "$h"
      exit 1 ;;
  esac
}
inherited=${REEVE_HOME:-}
home_p=$(cd -P "${HOME:-/nonexistent}" 2>/dev/null && pwd) \
  || { printf 'FAIL  refusing to run: HOME is unset or unreadable\n'; exit 1; }
REEVE_HOME="$SCRATCH/home"
refuse_if_inside "$inherited"
refuse_if_inside "$home_p/.reeve"
export REEVE_HOME

# Nothing from the caller's own session may leak in: every reeve below is named
# by the test that runs it.
unset CLAUDE_CODE_SESSION_ID REEVE_SESSION REEVE_NAME HERDR_PANE_ID TMUX_PANE HERDR_SOCKET_PATH \
      HERDR_TAB_ID REEVE_HAND
# A bare reeve-name also labels the reeve's workspace through the backend. Run
# from inside a real herdr or tmux, that would rename the caller's own, so both
# are stubs here that refuse everything, and the label is simply not made.
unset HERDR_WORKSPACE_ID HERDR_ENV TMUX REEVE_TMUX_SESSION REEVE_BACKEND
mkdir -p "$SCRATCH/fakebin"
for b in herdr tmux; do printf '#!/bin/sh\nexit 1\n' > "$SCRATCH/fakebin/$b"; chmod +x "$SCRATCH/fakebin/$b"; done
PATH="$SCRATCH/fakebin:$PATH"; export PATH

N="$ROOT/bin/reeve-name"
SESS="$REEVE_HOME/state/sessions"
NOW=$(date +%s)

fresh() { rm -rf "$REEVE_HOME"; mkdir -p "$REEVE_HOME/state/sessions" "$REEVE_HOME/config"; }
# record <sid> <name> <alive|dead> [<pane>]   a session another reeve left
record() {
  mkdir -p "$SESS/$1"
  printf '%s\n' "$2" > "$SESS/$1/name"
  if [ "$3" = alive ]; then printf '%s\n' "$NOW" > "$SESS/$1/seen"
  else printf '%s\n' "$(( NOW - 100000 ))" > "$SESS/$1/seen"; fi
  [ -n "${4:-}" ] && printf '%s\n' "$4" > "$SESS/$1/pane"
  return 0
}
name() { REEVE_SESSION=$1 "$N" 2>/dev/null; }

printf '\n--- the pool ---\n'
fresh
eq "1 the first reeve takes the first name in the pool" "Aldric" "$(name s1)"
eq "1 and keeps it when asked again" "Aldric" "$(name s1)"
eq "1 the second takes the next" "Bran" "$(name s2)"

fresh
record old Aldric alive
eq "2 a name a live reeve holds is skipped" "Bran" "$(name s1)"

# A gone reeve's record still holds its name, and a name nobody holds at all is
# preferred over it, so the liege does not see one name go to two reeves in a
# row. Only when every name has some record does a gone one's come back.
fresh
printf 'Hild\nOdo\n' > "$REEVE_HOME/config/reeve-names"
record gone Hild dead
eq "3 a name no record holds is preferred to a gone reeve's" "Odo" "$(name s1)"
eq "3 then the gone reeve's name is free again" "Hild" "$(name s2)"
eq "3 a pool of live names runs on with a suffix, never failing" "Hild-II" "$(name s3)"

printf '\n--- two reeves at once ---\n'
fresh
REEVE_SESSION=c1 "$N" > "$SCRATCH/c1" 2>/dev/null &
REEVE_SESSION=c2 "$N" > "$SCRATCH/c2" 2>/dev/null &
REEVE_SESSION=c3 "$N" > "$SCRATCH/c3" 2>/dev/null &
wait
a=$(cat "$SCRATCH/c1"); b=$(cat "$SCRATCH/c2"); c=$(cat "$SCRATCH/c3")
ne "4 two reeves starting together never share a name (1, 2)" "$a" "$b"
ne "4 (1, 3)" "$a" "$c"
ne "4 (2, 3)" "$b" "$c"
eq "4 and none came back empty" "3" "$(printf '%s\n%s\n%s\n' "$a" "$b" "$c" | grep -c .)"

printf '\n--- a /clear keeps the name ---\n'
# A pane runs one harness at a time, so the record that ran in this pane before
# is the session /clear replaced, alive or not by the clock.
fresh
record before Merek alive w9:p1
eq "5 a new session in the same herdr pane inherits its name" "Merek" \
   "$(HERDR_PANE_ID=w9:p1 REEVE_SESSION=after "$N" 2>/dev/null)"
eq "5 the pane is recorded with it" "w9:p1" "$(cat "$SESS/after/pane" 2>/dev/null)"
eq "5 a session in another pane does not" "Aldric" \
   "$(HERDR_PANE_ID=w9:p2 REEVE_SESSION=other "$N" 2>/dev/null)"
fresh
record before Rowan dead %7
eq "5 tmux's pane works the same way, and a gone predecessor still counts" "Rowan" \
   "$(TMUX_PANE=%7 REEVE_SESSION=after "$N" 2>/dev/null)"

# A pane is its id on its server. tmux numbers panes from %0 on every server,
# so the same id on another socket is another pane and another reeve.
fresh
record a Aldric alive "%0@/tmp/tmux-1/default"
eq "5 the pane is recorded with its server's socket" "%0@/tmp/tmux-1/default" \
   "$(TMUX=/tmp/tmux-1/default,99,0 TMUX_PANE=%0 REEVE_SESSION=a "$N" >/dev/null 2>&1; cat "$SESS/a/pane")"
eq "5 the same pane id on another tmux server is not this pane" "Bran" \
   "$(TMUX=/tmp/tmux-2/other,98,0 TMUX_PANE=%0 REEVE_SESSION=b "$N" 2>/dev/null)"
eq "5 the same pane on the same server is" "Aldric" \
   "$(TMUX=/tmp/tmux-1/default,99,0 TMUX_PANE=%0 REEVE_SESSION=c "$N" 2>/dev/null)"
fresh
record a Merek alive "w1:p1@/tmp/h1.sock"
eq "5 herdr's pane is keyed by HERDR_SOCKET_PATH the same way" "Aldric" \
   "$(HERDR_SOCKET_PATH=/tmp/h2.sock HERDR_PANE_ID=w1:p1 REEVE_SESSION=b "$N" 2>/dev/null)"
eq "5 and on its own socket is inherited" "Merek" \
   "$(HERDR_SOCKET_PATH=/tmp/h1.sock HERDR_PANE_ID=w1:p1 REEVE_SESSION=c "$N" 2>/dev/null)"

# Not when a live reeve elsewhere has since claimed that name.
fresh
record before Merek dead w9:p1
record rival Merek alive w8:p1
ne "5 a name a live reeve on another pane holds is not inherited" "Merek" \
   "$(HERDR_PANE_ID=w9:p1 REEVE_SESSION=after "$N" 2>/dev/null)"

printf '\n--- claim and set ---\n'
fresh
record rival Wulf alive w1:p1
out=$(HERDR_PANE_ID=w2:p1 REEVE_SESSION=me "$N" claim Wulf 2>&1); rc=$?
eq "6 claim refuses a name a live reeve on another pane holds" "1" "$rc"
has "6 and says who holds it" "$out" "rival"
eq "6 and takes nothing" "" "$(cat "$SESS/me/name" 2>/dev/null)"
out=$(HERDR_PANE_ID=w2:p1 REEVE_SESSION=me "$N" set Wulf 2>&1); rc=$?
eq "6 set refuses it the same way" "1" "$rc"
eq "6 claim allows it from the same pane, which /clear replaced" "Wulf" \
   "$(HERDR_PANE_ID=w1:p1 REEVE_SESSION=me "$N" claim Wulf 2>/dev/null)"
fresh
record gone Wulf dead w1:p1
eq "6 claim allows a name only a gone reeve held" "Wulf" \
   "$(HERDR_PANE_ID=w2:p1 REEVE_SESSION=me "$N" claim Wulf 2>/dev/null)"
REEVE_SESSION=me "$N" set Galen >/dev/null 2>&1
eq "6 set renames, and the name sticks" "Galen" "$(REEVE_SESSION=me "$N" 2>/dev/null)"

printf '\n--- what is a name ---\n'
fresh
for bad in 9lives 'Two words' Abcdefghijklm "Odo's" '-Odo' ''; do
  REEVE_SESSION=me "$N" claim "$bad" >/dev/null 2>&1
  eq "7 claim rejects '$bad'" "1" "$?"
done
eq "7 nothing was stored by any of them" "" "$(cat "$SESS/me/name" 2>/dev/null)"
eq "7 a hyphen is a letter here" "Anne-Marie" "$(REEVE_SESSION=me "$N" claim Anne-Marie 2>/dev/null)"

printf '\n--- the liege overrides ---\n'
fresh
eq "8 REEVE_NAME names a reeve" "Hildegard" "$(REEVE_NAME=Hildegard REEVE_SESSION=s1 "$N" 2>/dev/null)"
eq "8 an invalid REEVE_NAME is ignored for the pool" "Aldric" "$(REEVE_NAME='no good' REEVE_SESSION=s2 "$N" 2>/dev/null)"
# The override names a reeve, but never as a second live holder of one name.
out=$(REEVE_NAME=Hildegard REEVE_SESSION=s3 "$N" 2>"$SCRATCH/err")
eq "8 a REEVE_NAME a live reeve holds is refused for the pool" "Bran" "$out"
has "8 with a warning naming the holder" "$(cat "$SCRATCH/err")" "held by live reeve s1"
record s1 Hildegard dead
eq "8 once its holder is gone, REEVE_NAME takes it" "Hildegard" \
   "$(REEVE_NAME=Hildegard REEVE_SESSION=s4 "$N" 2>/dev/null)"
fresh
printf 'Brother Cadfael\nOswin\n  \n9bad\nEadric\n' > "$REEVE_HOME/config/reeve-names"
eq "8 config/reeve-names replaces the pool, its bad lines skipped" "Oswin" "$(name s1)"
eq "8 in its own order" "Eadric" "$(name s2)"

printf '\n--- no session id ---\n'
fresh
out=$("$N" 2>&1); rc=$?
eq "9 no id, no name: it refuses" "1" "$rc"
has "9 and says why" "$out" "no id"

printf '\n--- where the name shows ---\n'
fresh
REPO="$SCRATCH/holding"
rm -rf "$REPO"; mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" -c user.email=reeve@example.invalid -c user.name=reeve \
    -c commit.gpgsign=false commit -q --allow-empty -m init

STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
ln -s "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_agent_state()     { printf 'missing\n'; }
reeve_backend_stub_relabel()         { printf '%s|%s\n' "$1" "$2" >> "$REEVE_HOME/relabels"; }
ADAPTER
# A backend with no relabel at all, which the contract allows.
sed '/relabel/d; s/stub/bare/g' "$STUB/backends/stub.sh" > "$STUB/backends/bare.sh"
cat > "$STUB/harnesses/stub.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {prompt}"
prompt_mode = "argv"
HARNESS

brief() { # brief <sid> <id> <office>
  REEVE_SESSION=$1 "$ROOT/bin/reeve-brief" "$2" "$REPO" --office "$3" >/dev/null 2>&1 \
    || { FAIL=$((FAIL+1)); printf 'FAIL  reeve-brief refused %s\n' "$2"; }
  local b="$REEVE_HOME/errands/$2/brief.md"
  sed -e 's/{INTENT}/the liege said so/' -e 's/{SPEC}/build the thing/' "$b" > "$b.f" && mv "$b.f" "$b"
}
dry_label() { # dry_label <sid> <id>
  REEVE_SESSION=$1 REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" "$2" \
      --backend stub --harness stub --dry-run 2>/dev/null \
    | sed -n 's/^ *would run: reeve-backend call create_endpoint [^ ]* "\([^"]*\)".*/\1/p'
}

REEVE_SESSION=lead "$N" claim Escanor >/dev/null 2>&1
brief lead fix-auth artificer
eq "10 the brief names the reeve that sent it" "| reeve | Escanor |" \
   "$(grep '^| reeve |' "$REEVE_HOME/errands/fix-auth/brief.md")"
eq "10 and the record keeps it" "reeve=Escanor" "$(grep '^reeve=' "$REEVE_HOME/state/fix-auth.meta")"
eq "10 a dry run labels the hand <Name>'s <office>: <id>" "Escanor's artificer: fix-auth" \
   "$(dry_label lead fix-auth)"
eq "10 the dry run wrote no name for a session that had none" "" \
   "$(dry_label nameless fix-auth >/dev/null; cat "$SESS/nameless/name" 2>/dev/null)"

printf '%s\n' '{office} {id} for {reeve}' > "$REEVE_HOME/config/hand-label"
eq "11 config/hand-label reshapes it, spaces and all" "artificer fix-auth for Escanor" \
   "$(dry_label lead fix-auth)"
printf '%s\n' '"{reeve}" \{office}' > "$REEVE_HOME/config/hand-label"
eq "11 quotes and backslashes are kept out, so the dry run still parses" "Escanor artificer" \
   "$(dry_label lead fix-auth)"
rm -f "$REEVE_HOME/config/hand-label"

# Briefed with no session id: no name to give, so the label says what it can.
brief '' loose scout
eq "12 no name: the brief says so" "| reeve | - |" \
   "$(grep '^| reeve |' "$REEVE_HOME/errands/loose/brief.md")"
eq "12 and the label falls back to <office>: <id>" "scout: loose" "$(dry_label '' loose)"

st=$(REEVE_SESSION=lead "$ROOT/bin/reeve-status" --all --no-wake 2>/dev/null)
eq "13 a whole-home listing ends its header with REEVE" "REEVE" "$(printf '%s\n' "$st" | head -1 | awk '{ print $NF }')"
eq "13 each row ends with its reeve's name" "Escanor" "$(printf '%s\n' "$st" | grep '^fix-auth ' | awk '{ print $NF }')"
eq "13 or ? when none is known" "?" "$(printf '%s\n' "$st" | grep '^loose ' | awk '{ print $NF }')"
eq "13 a bare listing is unchanged" "OPEN" \
   "$(REEVE_SESSION=lead "$ROOT/bin/reeve-status" --no-wake 2>/dev/null | head -1 | awk '{ print $NF }')"
eq "13 the single errand view names the reeve" "reeve     Escanor" \
   "$(REEVE_SESSION=lead "$ROOT/bin/reeve-status" fix-auth 2>/dev/null | grep '^reeve ')"

hf=$(REEVE_SESSION=lead "$ROOT/bin/reeve-handoff" new reeve 2>/dev/null | sed -n 's/^handoff scaffolded: //p')
eq "14 a handoff records the reeve's name for the next session to claim" "- **Reeve:** Escanor" \
   "$(grep -F -- '**Reeve:**' "$hf" 2>/dev/null)"

printf '\n--- adoption renames ---\n'
# The errand's owner is gone, so a new reeve may take it, and the hand's label
# follows: the record, then the backend, by the target it returned.
brief lead other artificer
record lead Escanor dead
REEVE_SESSION=heir "$N" claim Percy >/dev/null 2>&1
printf 'target=stub:1\nbackend=stub\n' >> "$REEVE_HOME/state/fix-auth.meta"
out=$(REEVE_SESSION=heir REEVE_ROOT="$STUB" "$ROOT/bin/reeve-adopt" fix-auth 2>&1); rc=$?
eq "15 adopted" "0" "$rc"
eq "15 the record names the new reeve" "reeve=Percy" "$(grep '^reeve=' "$REEVE_HOME/state/fix-auth.meta")"
eq "15 and the hand is relabelled by its target" "stub:1|Percy's artificer: fix-auth" \
   "$(cat "$REEVE_HOME/relabels" 2>/dev/null)"
has "15 which it says" "$out" "relabelled"

printf 'target=bare:1\nbackend=bare\n' >> "$REEVE_HOME/state/other.meta"
out=$(REEVE_SESSION=heir REEVE_ROOT="$STUB" "$ROOT/bin/reeve-adopt" other 2>&1); rc=$?
eq "16 a backend with no relabel still adopts" "0" "$rc"
eq "16 and the record still names the new reeve" "reeve=Percy" "$(grep '^reeve=' "$REEVE_HOME/state/other.meta")"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
