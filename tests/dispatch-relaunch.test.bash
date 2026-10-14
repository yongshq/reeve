#!/usr/bin/env bash
# A hand whose session was lost is sent out again from the same brief, into the
# copy it left. A hall restart drops a hand's pane (it is made with
# --no-agent-resume) and keeps its copy and branch, so `reeve-dispatch <id>`
# again used to refuse on the copy it had itself made: "worktree path already
# exists". Every office with a copy was stuck there; only a steward relaunched.
#
# Pinned here: the relaunch happens only on proof, all of it. The record names
# the copy and branch, the copy is a worktree of the holding on that branch (a
# detached one for an office with none), the old session reads missing or dead,
# the errand was not torn down and did not finish. Then no second worktree, no
# new branch, the commits and the uncommitted work kept, a fresh hand told to
# look before it builds, a new target recorded, the branch's birth untouched,
# and one status line saying so. Anything less is today's refusal, with the
# reason named. Only for an errand sent out on hall, by the reeve that owns it,
# from the hall session its hand was made on; a herdr errand refuses as it
# always did, word for word. One dispatch of an errand at a time, a failed
# launch closes the session it opened, a dead session is closed before a new
# one opens, and a first dispatch that cannot open a session undoes its copy.
#
# Scratch homes only. Backend and harness are stubs, so no session is opened.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
case $SCRATCH in "$real_home"|"$real_home"/*) printf 'FAIL  refusing: scratch is inside the real home\n'; exit 1 ;; esac
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/home"
export REEVE_NO_CARETAKER=1
mkdir -p "$REEVE_HOME"
unset CLAUDE_CODE_SESSION_ID REEVE_SESSION REEVE_NAME REEVE_HAND REEVE_BACKEND REEVE_ROOT HALL_ENV HERDR_ENV

REPO="$SCRATCH/holding"
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
gitc() { git -C "$1" -c user.email=reeve@example.invalid -c user.name=reeve -c commit.gpgsign=false "${@:2}"; }
gitc "$REPO" commit -q --allow-empty -m init

# The stub backends: each endpoint a new `stub:<n>`, its state read from
# $STATES/<n> (alive when unset), every launch line kept in $LAUNCHES, every
# create and kill in $EVENTS. The same adapter is installed as `hall`, the one
# backend whose errands relaunch into their copy, and as `herdr`, whose errands
# keep the refusal they always had. STUB_SLOW makes a create take a second,
# STUB_CREATE_FAIL refuses one (STUB_CREATE_DIRTY leaving an untracked file in
# the copy first, STUB_CREATE_COMMIT a commit), STUB_CREATE_STATE is what a new
# endpoint reads (alive when unset; hall reads a pane whose harness is not up
# yet as dead), STUB_LAUNCH_RC is what a launch returns after recording its
# line, STUB_LAUNCH_HOLD holds a launch until that file exists and then reads
# the endpoint alive, STUB_KILL_FAIL refuses a kill, and STUB_PLACE is the
# session `place` names, none when unset.
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
export STATES="$SCRATCH/states" LAUNCHES="$SCRATCH/launches" EVENTS="$SCRATCH/events"
mkdir -p "$STATES"; : > "$LAUNCHES"; : > "$EVENTS"
for bk in hall herdr; do
  sed "s/@B@/$bk/g" > "$STUB/backends/$bk.sh" <<'ADAPTER'
reeve_backend_@B@_available()       { return 0; }
reeve_backend_@B@_describe()        { printf 'stub backend\n'; }
reeve_backend_@B@_create_endpoint() {
  local n
  [ -n "${STUB_SLOW:-}" ] && sleep 1
  if [ -n "${STUB_CREATE_FAIL:-}" ]; then
    [ -n "${STUB_CREATE_DIRTY:-}" ] && printf 'x\n' > "$1/left.txt"
    [ -n "${STUB_CREATE_COMMIT:-}" ] && git -C "$1" -c user.email=r@e.invalid -c user.name=r \
      -c commit.gpgsign=false commit -q --allow-empty -m 'made while opening'
    echo "stub: no room" >&2; return 1
  fi
  n=$(ls "$STATES" | wc -l | tr -d ' '); n=$((n + 1))
  printf '%s\n' "${STUB_CREATE_STATE:-alive}" > "$STATES/$n"
  printf 'create stub:%s\n' "$n" >> "$EVENTS"; printf 'stub:%s\n' "$n"
}
reeve_backend_@B@_launch() {
  local i=0
  printf '%s\t%s\n' "$1" "$2" >> "$LAUNCHES"
  if [ -n "${STUB_LAUNCH_HOLD:-}" ]; then
    while [ ! -e "$STUB_LAUNCH_HOLD" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
    printf 'alive\n' > "$STATES/${1#stub:}"
  fi
  return "${STUB_LAUNCH_RC:-0}"
}
reeve_backend_@B@_agent_state()     { cat "$STATES/${1#stub:}" 2>/dev/null || printf 'alive\n'; }
reeve_backend_@B@_attention_state() { printf 'settled\n'; }
reeve_backend_@B@_wait_change()     { return 2; }
reeve_backend_@B@_kill() {
  [ -z "${STUB_KILL_FAIL:-}" ] || return 1
  printf 'kill %s\n' "$1" >> "$EVENTS"; printf 'missing\n' > "$STATES/${1#stub:}"
}
reeve_backend_@B@_place()           { [ -n "${STUB_PLACE:-}" ] || return 1; printf '%s\n' "$STUB_PLACE"; }
ADAPTER
done
cat > "$STUB/harnesses/stub.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {settings} {prompt}"
settings_flag = "--settings {settings}"
prompt_mode = "argv"
HARNESS
# The reeve that briefs every errand here, and so owns it.
export REEVE_SESSION=lead

brief_for() { # brief_for <id> <office>
  REEVE_ROOT="$ROOT" "$ROOT/bin/reeve-brief" "$1" "$REPO" --office "$2" >/dev/null || return 1
  local b="$REEVE_HOME/errands/$1/brief.md"
  sed -e 's/{INTENT}/the liege said so/' -e 's/{SPEC}/build the thing/' "$b" > "$b.filled" && mv "$b.filled" "$b"
}
dispatch() { # dispatch <id> [args...] -> OUT, ERR, RC
  local id=$1; shift
  ERR=$(mktemp "$SCRATCH/err.XXXXXX")   # its own file, so two at once never share one
  OUT=$(REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" "$id" --backend "${BK:-hall}" --harness stub "$@" 2>"$ERR"); RC=$?
  ERR=$(cat "$ERR")
}
meta() { sed -n "s/^$2=//p" "$REEVE_HOME/state/$1.meta" | head -n 1; }
lose() { printf '%s\n' "${2:-missing}" > "$STATES/$(meta "$1" target | sed 's/^stub://')"; }  # lose <id> [state]
say()  { "$ROOT/bin/reeve-say" "$REEVE_HOME/errands/$1/status" "$2" "$3" >/dev/null; }
worktrees() { git -C "$REPO" worktree list --porcelain | grep -c '^worktree '; }
last_launch() { tail -n 1 "$LAUNCHES" | cut -f2-; }

echo "--- 1. an artificer whose session was lost is sent out again into its copy ---"
brief_for art artificer || bad "1 reeve-brief refused"
dispatch art
eq  "1 the first dispatch succeeds"                         "$RC" 0
WT=$(meta art worktree); BR=$(meta art branch)
nas "1 its launch line is not a relaunch's"                 "$(last_launch)" "This is a relaunch"
say art working 'building'
printf 'one\n' > "$WT/a.txt"; gitc "$WT" add a.txt; gitc "$WT" commit -q -m 'the first hand committed'
printf 'half done\n' > "$WT/b.txt"
TIP=$(git -C "$REPO" rev-parse "refs/heads/$BR"); MADE=$(meta art branchMade); WTN=$(worktrees)
lose art missing

M0=$(cat "$REEVE_HOME/state/art.meta"); S0=$(cat "$REEVE_HOME/errands/art/status")
dispatch art --dry-run
eq  "1 a dry run of the relaunch succeeds"                  "$RC" 0
has "1 and says it relaunches onto the copy"                "$OUT" "relaunching onto the existing copy $WT ($BR)"
has "1 and that the copy and its work are kept"             "$OUT" "would keep: the copy, its branch, its commits and any uncommitted work"
has "1 and the status line it would add"                    "$OUT" "would run: reeve-say $REEVE_HOME/errands/art/status working 'relaunched onto existing copy after its session was lost'"
has "1 the line it would launch tells the hand to look"     "$OUT" "This is a relaunch"
nas "1 and would add no worktree"                           "$OUT" "worktree add"
eq  "1 changing nothing"                                    "$(cat "$REEVE_HOME/state/art.meta")|$(cat "$REEVE_HOME/errands/art/status")|$(worktrees)" "$M0|$S0|$WTN"

dispatch art
eq  "1 the relaunch succeeds"                               "$RC" 0
has "1 saying it was a relaunch"                            "$ERR" "relaunching"
eq  "1 no second worktree"                                  "$(worktrees)" "$WTN"
eq  "1 the branch is where the first hand left it"          "$(git -C "$REPO" rev-parse "refs/heads/$BR")" "$TIP"
eq  "1 the copy still holds its uncommitted work"           "$(cat "$WT/b.txt")" "half done"
eq  "1 still on the errand's branch"                        "$(git -C "$WT" symbolic-ref --short HEAD)" "$BR"
eq  "1 a new session is recorded"                           "$(meta art target)" "stub:2"
eq  "1 the branch's birth is untouched"                     "$(meta art branchMade)" "$MADE"
has "1 the fresh hand is told to look first"                "$(last_launch)" "Inspect git status and git log first"
has "1 and launched from the same brief"                    "$(last_launch)" "Read the file $REEVE_HOME/errands/art/brief.md and follow it exactly."
has "1 the status file says so"                             "$(tail -n 1 "$REEVE_HOME/errands/art/status")" "relaunched onto existing copy after its session was lost"
eq  "1 in a working line, stamped"                          "$(tail -n 1 "$REEVE_HOME/errands/art/status" | grep -cE '^working: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z ')" 1

echo "--- 2. a session that is alive, or cannot be read, refuses ---"
dispatch art
eq  "2 a live hand is never doubled"                        "$RC" 1
has "2 saying it is running"                                "$ERR" "already running at stub:2"
lose art unreadable
dispatch art
eq  "2 an unreadable session refuses"                       "$RC" 1
has "2 saying it cannot be read"                            "$ERR" "whose state cannot be read"
lose art unknown
dispatch art
eq  "2 a word that is not missing or dead refuses"          "$RC" 1
has "2 naming what it read"                                 "$ERR" "its earlier session at stub:2 reads unknown, not missing or dead"
eq  "2 and nothing was launched"                            "$(meta art target)" "stub:2"
lose art dead
dispatch art
eq  "2 a dead session, a shell where the hand was, relaunches" "$RC" 0
eq  "2 still one worktree"                                  "$(worktrees)" "$WTN"

echo "--- 3. a copy that is not the errand's as recorded refuses ---"
gitc "$WT" checkout -q -b elsewhere
lose art missing
dispatch art
eq  "3 a copy on another branch refuses"                    "$RC" 1
has "3 naming both branches"                                "$ERR" "it is on elsewhere, not the errand's branch '$BR'"
has "3 in today's refusal"                                  "$ERR" "worktree path already exists: $WT"
has "3 with today's move, since the reason names none"      "$ERR" "pick another errand id or clean that up first"
gitc "$WT" checkout -q "$BR"
T=$(meta art target)
sed 's/^target=.*/target=/' "$REEVE_HOME/state/art.meta" > "$SCRATCH/m" && mv "$SCRATCH/m" "$REEVE_HOME/state/art.meta"
dispatch art
eq  "3 no session recorded refuses"                         "$RC" 1
has "3 since nothing shows no hand is in it"                "$ERR" "no earlier session is recorded for it"
sed "s/^target=.*/target=$T/" "$REEVE_HOME/state/art.meta" > "$SCRATCH/m" && mv "$SCRATCH/m" "$REEVE_HOME/state/art.meta"
mv "$WT" "$SCRATCH/moved"; mkdir -p "$WT"
dispatch art
eq  "3 a plain directory where the copy was refuses"        "$RC" 1
has "3 saying it is no checkout"                            "$ERR" "it is not the top of a git checkout"
rmdir "$WT"; mv "$SCRATCH/moved" "$WT"
OTHER="$SCRATCH/other"; git init -q "$OTHER"; gitc "$OTHER" commit -q --allow-empty -m x
mv "$WT" "$SCRATCH/moved"; gitc "$OTHER" worktree add -q -b "$BR" "$WT" 2>/dev/null
dispatch art
eq  "3 a worktree of another repository refuses"            "$RC" 1
has "3 saying whose it is not"                              "$ERR" "it is not a worktree of $REPO"
git -C "$OTHER" worktree remove --force "$WT"; mv "$SCRATCH/moved" "$WT"

echo "--- 4. a finished or torn down errand is not sent out again ---"
dispatch art
eq  "4 (the copy is restored and relaunches)"               "$RC" 0
for st in done failed; do
  say art "$st" "it was $st"; lose art missing
  dispatch art
  eq  "4 one that reported $st refuses"                     "$RC" 1
  has "4 saying it finished"                                "$ERR" "it reported $st with nothing open"
done
say art 'needs-decision [key=which]' 'which one?'
dispatch art
eq  "4 one with a question still open is not finished"      "$RC" 0
lose art missing
printf 'tornDown=2026-10-14T00:00:00\n' >> "$REEVE_HOME/state/art.meta"
dispatch art
eq  "4 one torn down refuses"                               "$RC" 1
has "4 saying so"                                           "$ERR" "the errand was torn down"

echo "--- 5. a scout's detached copy relaunches the same way ---"
brief_for sc scout || bad "5 reeve-brief refused"
dispatch sc
eq  "5 the first dispatch succeeds"                         "$RC" 0
SWT=$(meta sc worktree); WTN=$(worktrees)
eq  "5 its copy is detached"                                "$(git -C "$SWT" symbolic-ref -q HEAD || echo detached)" detached
lose sc missing
dispatch sc
eq  "5 its session lost, it relaunches"                     "$RC" 0
eq  "5 into the same copy, no second worktree"              "$(worktrees)" "$WTN"
has "5 its fresh hand told to look first"                   "$(last_launch)" "This is a relaunch"
eq  "5 under a new session"                                 "$(meta sc target)" "stub:$(ls "$STATES" | wc -l | tr -d ' ')"
gitc "$SWT" checkout -q -b scouting
lose sc missing
dispatch sc
eq  "5 a scout copy on a branch refuses"                    "$RC" 1
has "5 saying the copy should be detached"                  "$ERR" "it is on branch 'scouting', while this errand's copy is a detached checkout"

echo "--- 6. a herdr errand keeps today's refusal, word for word ---"
# The liege: leave the herdr setup untouched. Only an errand sent out on hall
# relaunches into its copy; one sent out on herdr refuses as it always did.
brief_for hd artificer || bad "6 reeve-brief refused"
BK=herdr dispatch hd
eq  "6 the first dispatch on herdr succeeds"                "$RC" 0
HWT=$(meta hd worktree); WTN=$(worktrees); L0=$(wc -l < "$LAUNCHES"); E0=$(wc -l < "$EVENTS")
for st in missing dead; do
  lose hd "$st"; HT=$(meta hd target)
  BK=herdr dispatch hd
  eq  "6 its session $st, it refuses"                       "$RC" 1
  eq  "6 its whole stderr is today's, byte for byte"        "$ERR" "reeve: errand 'hd' had a previous endpoint ($HT, now $st), relaunching
reeve: worktree path already exists: $HWT. pick another errand id or clean that up first"
done
eq  "6 nothing was opened, closed or launched"              "$(wc -l < "$LAUNCHES")|$(wc -l < "$EVENTS")|$(worktrees)" "$L0|$E0|$WTN"
eq  "6 and no lock was left"                                "$(ls -d "$REEVE_HOME"/state/.lock-dispatch-* 2>/dev/null)" ''

echo "--- 7. only the reeve that owns an errand relaunches it ---"
brief_for own artificer || bad "7 reeve-brief refused"
dispatch own; lose own missing
REEVE_SESSION=stranger dispatch own
eq  "7 another session's dispatch refuses"                  "$RC" 1
has "7 saying whose it is, and how to take it"              "$ERR" "it belongs to session lead, not this one (stranger); adopt it first: reeve-adopt own"
nas "7 and no other move after it"                          "$ERR" "pick another errand id"
REEVE_SESSION='' dispatch own
eq  "7 a session with no id refuses"                        "$RC" 1
has "7 the same way"                                        "$ERR" "adopt it first: reeve-adopt own"
BK=herdr dispatch own
eq  "7 a hall errand dispatched on herdr refuses"           "$RC" 1
has "7 saying where it was sent"                            "$ERR" "it was sent out on hall, and this dispatch is on herdr"
nas "7 and no other move after it"                          "$ERR" "pick another errand id"
dispatch own
eq  "7 its owner relaunches it"                             "$RC" 0

echo "--- 8. a hand made on another hall session is not relaunched from here ---"
brief_for pl scout || bad "8 reeve-brief refused"
STUB_PLACE=one dispatch pl
eq  "8 the record names the session the hand is in"         "$(meta pl place)" one
lose pl missing
STUB_PLACE=two dispatch pl
eq  "8 a reeve on another session refuses"                  "$RC" 1
has "8 naming both"                                         "$ERR" "its hand was made on hall session 'one', and this reeve talks to 'two'"
nas "8 and no other move after it"                          "$ERR" "pick another errand id"
dispatch pl
eq  "8 so does one that cannot say which"                   "$RC" 1
has "8 saying none"                                         "$ERR" "this reeve talks to 'none'"
STUB_PLACE=one dispatch pl
eq  "8 the same session relaunches it"                      "$RC" 0

echo "--- 9. two relaunches at once put one hand in the copy ---"
# git used to refuse the second, on the worktree path. A relaunch adds none, so
# a lock per errand does: the second is refused, never waits.
brief_for par artificer || bad "9 reeve-brief refused"
dispatch par; lose par missing
L0=$(wc -l < "$LAUNCHES"); WTN=$(worktrees)
( STUB_SLOW=1 dispatch par; printf '%s\n%s\n' "$RC" "$ERR" > "$SCRATCH/par.a" ) &
( STUB_SLOW=1 dispatch par; printf '%s\n%s\n' "$RC" "$ERR" > "$SCRATCH/par.b" ) &
wait
eq  "9 one succeeds and one refuses"                        "$( (head -n 1 "$SCRATCH/par.a"; head -n 1 "$SCRATCH/par.b") | sort | tr '\n' ' ')" "0 1 "
has "9 the refusal says another run has it"                 "$(cat "$SCRATCH/par.a" "$SCRATCH/par.b")" "errand 'par' is being dispatched by another run right now"
eq  "9 one launch, into the one copy"                       "$(( $(wc -l < "$LAUNCHES") - L0 ))|$(worktrees)" "1|$WTN"
eq  "9 and the lock is gone after"                          "$(ls -d "$REEVE_HOME"/state/.lock-dispatch-par 2>/dev/null)" ''
# A first dispatch on hall records its session before its launch, so it holds
# the same lock: one held by a live run refuses it too, before any copy.
brief_for fd artificer || bad "9 reeve-brief refused"
mkdir "$REEVE_HOME/state/.lock-dispatch-fd"; printf '%s\n' "$$" > "$REEVE_HOME/state/.lock-dispatch-fd/pid"
dispatch fd
eq  "9 a first dispatch on hall waits for no one"           "$RC" 1
has "9 refused while another run holds it"                  "$ERR" "errand 'fd' is being dispatched by another run right now"
has "9 naming the lock"                                     "$ERR" "holding $REEVE_HOME/state/.lock-dispatch-fd"
eq  "9 before any copy was made"                            "$([ -e "$(meta fd worktree)" ] && echo made || echo none)" none
rm -rf "$REEVE_HOME/state/.lock-dispatch-fd"
dispatch fd
eq  "9 and goes out once it is free"                        "$RC" 0

echo "--- 10. a launch that reports failure cannot be retried into a second hand ---"
brief_for fl artificer || bad "10 reeve-brief refused"
dispatch fl; lose fl missing; OLD=$(meta fl target)
STUB_LAUNCH_RC=1 dispatch fl
eq  "10 the failed relaunch fails"                          "$RC" 1
NEW=$(meta fl target)
eq  "10 the new session is recorded, not the lost one"      "$NEW" "stub:$(ls "$STATES" | wc -l | tr -d ' ')"
eq  "10 as its session, no longer as launching"             "$(meta fl launching)" ''
has "10 the session it opened is closed"                    "$(cat "$EVENTS")" "kill $NEW"
has "10 and it says a retry sends out one hand"             "$ERR" "that session was closed and is recorded, so dispatching 'fl' again sends out one fresh hand"
dispatch fl
eq  "10 the retry relaunches"                               "$RC" 0
alive=0
for t in $(grep "/errands/fl/" "$LAUNCHES" | cut -f1 | sort -u); do
  [ "$(cat "$STATES/${t#stub:}")" = alive ] && alive=$((alive + 1))
done
eq  "10 one hand alive in the copy, not two"                "$alive" 1
lose fl missing
STUB_LAUNCH_RC=1 STUB_KILL_FAIL=1 dispatch fl
eq  "10 a failed launch whose session will not close fails" "$RC" 1
has "10 saying it may still be starting"                    "$ERR" "that session could not be closed. it is recorded as the errand's session"
T=$(meta fl target)
eq  "10 that one too is recorded as its session"            "$(meta fl launching)|$T" "|stub:$(ls "$STATES" | wc -l | tr -d ' ')"
dispatch fl
eq  "10 a retry reads that session, the hand came up after all" "$RC" 1
has "10 and refuses on it"                                  "$ERR" "already running at $T"

echo "--- 11. a dead session is closed before a new one opens ---"
lose fl dead; E0=$(wc -l < "$EVENTS")
STUB_KILL_FAIL=1 dispatch fl
eq  "11 one that will not close refuses"                    "$RC" 1
has "11 saying it may still be starting a hand"             "$ERR" "reads dead and could not be closed"
eq  "11 and opens nothing"                                  "$(wc -l < "$EVENTS")" "$E0"
dispatch fl --dry-run
has "11 a dry run says it would close it"                   "$OUT" "call kill $T --backend hall"
eq  "11 and closes nothing"                                 "$(wc -l < "$EVENTS")" "$E0"
dispatch fl
eq  "11 the relaunch succeeds"                              "$RC" 0
eq  "11 the old session closed, then the new one opened"    "$(sed -n "$((E0 + 1)),\$p" "$EVENTS" | cut -d' ' -f1 | tr '\n' ' ')" "kill create "
has "11 the one closed is the old one"                      "$(sed -n "$((E0 + 1))p" "$EVENTS")" "kill $T"
has "11 its warning comes once the relaunch is allowed"     "$ERR" "relaunching"
lose fl unknown
dispatch fl
nas "11 and not before a refusal"                           "$ERR" "relaunching"

echo "--- 12. a copy made by a dispatch that could not open a session is undone ---"
brief_for rb artificer || bad "12 reeve-brief refused"
RWT=$(meta rb worktree); RBR=$(meta rb branch)
STUB_CREATE_FAIL=1 dispatch rb
eq  "12 the dispatch fails"                                 "$RC" 1
eq  "12 its copy is removed"                                "$([ -e "$RWT" ] && echo kept || echo gone)" gone
eq  "12 and its empty branch"                               "$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$RBR" || echo gone)" gone
has "12 saying so"                                          "$ERR" "removed what this dispatch made, the copy and branch '$RBR', so 'rb' can be dispatched again"
dispatch rb
eq  "12 so the id is not stuck"                             "$RC" 0
eq  "12 and the new branch's birth is recorded"             "$([ -n "$(meta rb branchMade)" ] && echo yes)" yes
lose rb missing; TIP=$(git -C "$REPO" rev-parse "refs/heads/$RBR")
STUB_CREATE_FAIL=1 dispatch rb
eq  "12 a relaunch that cannot open a session fails"        "$RC" 1
eq  "12 and never touches the copy it found"                "$([ -d "$RWT" ] && echo kept)|$(git -C "$REPO" rev-parse "refs/heads/$RBR")" "kept|$TIP"
nas "12 nor says it removed anything"                       "$ERR" "removed"
brief_for rd artificer || bad "12 reeve-brief refused"
STUB_CREATE_FAIL=1 STUB_CREATE_DIRTY=1 dispatch rd
eq  "12 a copy left dirty is kept"                          "$(cat "$(meta rd worktree)/left.txt" 2>/dev/null)" x
eq  "12 with its branch"                                    "$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$(meta rd branch)" >/dev/null && echo kept)" kept
has "12 saying why"                                         "$ERR" "git would not remove the copy as clean"
brief_for ra artificer || bad "12 reeve-brief refused"
STUB_CREATE_FAIL=1 STUB_CREATE_COMMIT=1 dispatch ra
eq  "12 a branch ahead of its base is kept, copy and all"   "$([ -d "$(meta ra worktree)" ] && echo kept)|$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$(meta ra branch)" >/dev/null && echo kept)" "kept|kept"
has "12 saying why"                                         "$ERR" "the branch is 1 ahead of main"
brief_for rs scout || bad "12 reeve-brief refused"
STUB_CREATE_FAIL=1 dispatch rs
eq  "12 a scout's detached copy is removed the same way"    "$([ -e "$(meta rs worktree)" ] && echo kept || echo gone)" gone
has "12 saying so"                                          "$ERR" "removed what this dispatch made, the copy, so 'rs'"
brief_for rh artificer || bad "12 reeve-brief refused"
STUB_CREATE_FAIL=1 BK=herdr dispatch rh
eq  "12 on herdr the copy is left, as it always was"        "$([ -d "$(meta rh worktree)" ] && echo kept)" kept
nas "12 and nothing is said removed"                        "$ERR" "removed"

# The empty branch is deleted where HEAD is its own tip. From the holding, `-d`
# measured it against the primary checkout's main, which lacks a commit the
# base has, and refused it: the id was stranded again.
git -C "$REPO" branch -q other main; gitc "$REPO" commit -q --allow-empty -m 'not on main' >/dev/null
git -C "$REPO" checkout -q other; gitc "$REPO" commit -q --allow-empty -m 'only on other'; git -C "$REPO" checkout -q main
brief_for ro artificer || bad "12 reeve-brief refused"
sed 's/^base=.*/base=other/' "$REEVE_HOME/state/ro.meta" > "$SCRATCH/m" && mv "$SCRATCH/m" "$REEVE_HOME/state/ro.meta"
STUB_CREATE_FAIL=1 dispatch ro
eq  "12 on a base main lacks, the copy is removed"          "$([ -e "$(meta ro worktree)" ] && echo kept || echo gone)" gone
eq  "12 and its empty branch"                               "$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$(meta ro branch)" || echo gone)" gone
nas "12 with no word from git about merging"                "$ERR" "not fully merged"
eq  "12 its birth record cleared"                           "$(meta ro branchMade)" ''
eq  "12 the primary checkout still on main"                 "$(git -C "$REPO" symbolic-ref --short HEAD)" main
dispatch ro
eq  "12 so that id is not stuck either"                     "$RC" 0
eq  "12 its branch made from the base it named"             "$(git -C "$REPO" rev-parse "refs/heads/$(meta ro branch)")" "$(git -C "$REPO" rev-parse other)"

echo "--- 13. a watch during a hall launch does not call the starting hand lost ---"
# Until the harness reaches the foreground hall reads the new pane as a shell
# with no agent, dead. Recorded as `target=` before the launch, that made a
# watch polling then say `stale:` and end. It is `launching=` until the launch
# returns, which only dispatch reads.
REEVE_HOME="$SCRATCH/home13"; export REEVE_HOME; mkdir -p "$REEVE_HOME"
watch() { REEVE_ROOT="$STUB" "$ROOT/bin/reeve-sentry" --once --no-reap 2>&1; }
until_meta() { # until_meta <id> <key>: wait, bounded, for the key to be set
  local n=0; while [ "$n" -lt 100 ] && [ -z "$(meta "$1" "$2" 2>/dev/null)" ]; do sleep 0.1; n=$((n + 1)); done
}
brief_for ml artificer || bad "13 reeve-brief refused"
HOLD="$SCRATCH/hold.ml"
( STUB_CREATE_STATE=dead STUB_LAUNCH_HOLD=$HOLD dispatch ml; printf '%s\n%s\n' "$RC" "$ERR" > "$SCRATCH/ml.out" ) &
MLP=$!
until_meta ml launching; L=$(meta ml launching)
eq  "13 mid launch, the new session is recorded as launching" "$(cat "$STATES/${L#stub:}")|$(meta ml target)" "dead|"
W=$(watch)
nas "13 a watch then says nothing is stale"                 "$W" "stale:"
touch "$HOLD"; wait "$MLP"
eq  "13 the dispatch succeeds"                              "$(head -n 1 "$SCRATCH/ml.out")" 0
eq  "13 and moves it to its session"                        "$(meta ml target)|$(meta ml launching)" "$L|"
W=$(watch)
nas "13 a watch after says nothing is stale either"         "$W" "stale:"
has "13 and sees the hand working"                          "$W" "quiet"
# A relaunch the same way: its new session is launching, the lost one already
# said once by the watch that saw it go.
lose ml missing; W=$(watch)
has "13 (the lost hand is said once)"                       "$W" "stale: ml"
rm -f "$HOLD"
( STUB_CREATE_STATE=dead STUB_LAUNCH_HOLD=$HOLD dispatch ml; printf '%s\n' "$RC" > "$SCRATCH/ml.out" ) &
MLP=$!
n=0; while [ "$n" -lt 100 ] && [ "$(meta ml launching)" = '' ]; do sleep 0.1; n=$((n + 1)); done
L2=$(meta ml launching)
eq  "13 mid relaunch, its new session is launching"         "$([ -n "$L2" ] && [ "$L2" != "$L" ] && echo yes)|$(meta ml target)" "yes|$L"
W=$(watch)
nas "13 a watch mid relaunch says nothing is stale"         "$W" "stale:"
touch "$HOLD"; wait "$MLP"
eq  "13 the relaunch succeeds onto the new session"         "$(cat "$SCRATCH/ml.out")|$(meta ml target)|$(meta ml launching)" "0|$L2|"

echo "--- 14. a dispatch killed outright leaves a lock that is broken, and one hand ---"
brief_for kl artificer || bad "14 reeve-brief refused"
HOLD="$SCRATCH/hold.kl"
REEVE_ROOT="$STUB" STUB_LAUNCH_HOLD=$HOLD "$ROOT/bin/reeve-dispatch" kl --backend hall --harness stub >/dev/null 2>&1 &
KP=$!
until_meta kl launching; L=$(meta kl launching)
pkill -9 -P "$KP" 2>/dev/null; kill -9 "$KP" 2>/dev/null; wait "$KP" 2>/dev/null
touch "$HOLD"; sleep 0.5
LK="$REEVE_HOME/state/.lock-dispatch-kl"
eq  "14 its lock is left, its holder dead"                  "$([ -d "$LK" ] && ! kill -0 "$(cat "$LK/pid")" 2>/dev/null && echo left)" left
eq  "14 and its session still launching"                    "$(meta kl launching)|$(meta kl target)" "$L|"
dispatch kl
eq  "14 a retry at once is refused"                         "$RC" 1
has "14 naming the lock, so it can be acted on"             "$ERR" "holding $LK"
has "14 and when it will be broken"                         "$(printf '%s\n' "$ERR" | tail -n 1)" "broken once its holder is dead past that"
touch -t 202001010000 "$LK"
printf 'alive\n' > "$STATES/${L#stub:}"
dispatch kl
has "14 one past lock-stale is broken"                      "$ERR" "broke stale lock dispatch-kl"
eq  "14 and the retry reads the launching session, alive"   "$RC" 1
has "14 refusing a second hand"                             "$ERR" "already running at $L"
eq  "14 and leaves no lock"                                 "$([ -d "$LK" ] && echo left || echo none)" none
printf 'missing\n' > "$STATES/${L#stub:}"
dispatch kl
eq  "14 when that session is lost, the retry relaunches"    "$RC" 0
alive=0
for t in $(grep "/errands/kl/" "$LAUNCHES" | cut -f1 | sort -u); do
  [ "$(cat "$STATES/${t#stub:}")" = alive ] && alive=$((alive + 1))
done
eq  "14 one hand alive, not two"                            "$alive" 1
eq  "14 recorded as its session"                            "$(meta kl launching)|$([ "$(meta kl target)" != "$L" ] && echo new)" "|new"

echo "--- 15. a dispatch stopped by a signal mid launch records its new session ---"
# The EXIT trap released the lock and nothing else, so the new hand stayed under
# `launching=`, which only dispatch reads: a first dispatch read `nothing in
# flight`, a relaunch read its lost session `stale:`, and teardown removed the
# copy under the live hand and left its session open. The trap moves it to
# `target=`, as a launch that returned would, and closes nothing.
REEVE_HOME="$SCRATCH/home15"; export REEVE_HOME; mkdir -p "$REEVE_HOME"
teardown() { # teardown <id> -> TOUT, TRC
  TOUT=$(REEVE_ROOT="$STUB" "$ROOT/bin/reeve-teardown" "$1" 2>&1); TRC=$?
}
stopped() { # stopped <id> <signal>: dispatch, held mid launch, sent <signal>
  local hold="$SCRATCH/hold.$1.$RANDOM" p
  REEVE_ROOT="$STUB" STUB_LAUNCH_HOLD=$hold "$ROOT/bin/reeve-dispatch" "$1" --backend hall --harness stub >/dev/null 2>&1 &
  p=$!
  n=0; while [ "$n" -lt 100 ] && [ -z "$(meta "$1" launching)" ]; do sleep 0.1; n=$((n + 1)); done
  L=$(meta "$1" launching)
  kill "-$2" "$p" 2>/dev/null; wait "$p" 2>/dev/null
  touch "$hold"; sleep 0.5
}
brief_for tm scout || bad "15 reeve-brief refused"
E0=$(wc -l < "$EVENTS")
stopped tm TERM
eq  "15 a first dispatch stopped by TERM records its session" "$(meta tm target)|$(meta tm launching)" "$L|"
eq  "15 as dispatched, on hall"                             "$([ -n "$(meta tm dispatched)" ] && echo yes)|$(meta tm backend)" "yes|hall"
eq  "15 with a status file to read"                         "$([ -f "$REEVE_HOME/errands/tm/status" ] && echo yes)" yes
nas "15 and closes nothing, the hand may be coming up"      "$(sed -n "$((E0 + 1)),\$p" "$EVENTS")" "kill"
eq  "15 and leaves no lock"                                 "$(ls -d "$REEVE_HOME"/state/.lock-dispatch-tm 2>/dev/null)" ''
W=$(watch)
nas "15 a watch sees it in flight"                          "$W" "nothing in flight"
has "15 working"                                            "$W" "quiet: 1 errand(s) working"
TWT=$(meta tm worktree)
teardown tm
eq  "15 teardown refuses while it is alive"                 "$TRC" 1
has "15 naming it"                                          "$TOUT" "a hand is still working at $L"
eq  "15 and keeps its copy"                                 "$([ -d "$TWT" ] && echo kept)" kept
dispatch tm
eq  "15 a dispatch again refuses on it"                     "$RC|$(printf '%s' "$ERR" | grep -c "already running at $L")" "1|1"
# The relaunch the same way: its lost session already said once by a watch.
lose tm missing; W=$(watch)
has "15 (the lost hand is said once)"                       "$W" "stale: tm"
OLD=$(meta tm target)
stopped tm TERM
eq  "15 a relaunch stopped by TERM records its new session" "$([ "$L" != "$OLD" ] && echo new)|$(meta tm target)|$(meta tm launching)" "new|$L|"
has "15 and says in its log it was relaunched"              "$(tail -n 1 "$REEVE_HOME/errands/tm/status")" "relaunched onto existing copy after its session was lost"
W=$(watch)
nas "15 a watch calls nothing lost"                         "$W" "stale:"
has "15 and sees the new hand working"                      "$W" "quiet: 1 errand(s) working"
teardown tm
eq  "15 teardown refuses while the new hand is alive"       "$TRC" 1
has "15 naming the new session"                             "$TOUT" "a hand is still working at $L"
eq  "15 and keeps the copy under it"                        "$([ -d "$TWT" ] && echo kept)" kept
lose tm missing; W=$(watch)
has "15 a later loss of the new hand is said"               "$W" "stale: tm"

echo "--- 16. teardown reads a session left launching by a dispatch killed outright ---"
# SIGKILL runs no trap, so the new session stays under `launching=` alone.
brief_for kt scout || bad "16 reeve-brief refused"
KWT=$(meta kt worktree)
stopped kt KILL
eq  "16 killed outright, it is still launching"             "$(meta kt launching)|$(meta kt target)" "$L|"
teardown kt
eq  "16 teardown refuses while it is alive"                 "$TRC" 1
has "16 naming it"                                          "$TOUT" "a hand is still working at $L"
eq  "16 and keeps its copy"                                 "$([ -d "$KWT" ] && echo kept)" kept
printf 'unreadable\n' > "$STATES/${L#stub:}"
teardown kt
eq  "16 one that cannot be read refuses too"                "$TRC|$(printf '%s' "$TOUT" | grep -c "the state of the endpoint at $L cannot be read")" "1|1"
printf 'dead\n' > "$STATES/${L#stub:}"; E0=$(wc -l < "$EVENTS")
teardown kt
eq  "16 a dead one is torn down"                            "$TRC" 0
has "16 closing it, as it closes a target"                  "$(sed -n "$((E0 + 1)),\$p" "$EVENTS")" "kill $L"
eq  "16 and clearing it from the record"                    "$(meta kt launching)" ''
eq  "16 the copy removed"                                   "$([ -e "$KWT" ] && echo kept || echo gone)" gone

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
