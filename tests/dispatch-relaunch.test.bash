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
# reason named.
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

# The stub backend: each endpoint a new `stub:<n>`, its state read from
# $STATES/<n> (alive when unset), every launch line kept in $LAUNCHES.
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
export STATES="$SCRATCH/states" LAUNCHES="$SCRATCH/launches"
mkdir -p "$STATES"; : > "$LAUNCHES"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() {
  local n; n=$(ls "$STATES" | wc -l | tr -d ' '); n=$((n + 1))
  printf 'alive\n' > "$STATES/$n"; printf 'stub:%s\n' "$n"
}
reeve_backend_stub_launch()          { printf '%s\t%s\n' "$1" "$2" >> "$LAUNCHES"; }
reeve_backend_stub_agent_state()     { cat "$STATES/${1#stub:}" 2>/dev/null || printf 'alive\n'; }
reeve_backend_stub_attention_state() { printf 'settled\n'; }
reeve_backend_stub_wait_change()     { return 2; }
reeve_backend_stub_kill()            { return 0; }
ADAPTER
cat > "$STUB/harnesses/stub.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {settings} {prompt}"
settings_flag = "--settings {settings}"
prompt_mode = "argv"
HARNESS

brief_for() { # brief_for <id> <office>
  REEVE_ROOT="$ROOT" "$ROOT/bin/reeve-brief" "$1" "$REPO" --office "$2" >/dev/null || return 1
  local b="$REEVE_HOME/errands/$1/brief.md"
  sed -e 's/{INTENT}/the liege said so/' -e 's/{SPEC}/build the thing/' "$b" > "$b.filled" && mv "$b.filled" "$b"
}
dispatch() { # dispatch <id> [args...] -> OUT, ERR, RC
  local id=$1; shift
  ERR="$SCRATCH/err.$id"
  OUT=$(REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" "$id" --backend stub --harness stub "$@" 2>"$ERR"); RC=$?
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

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
