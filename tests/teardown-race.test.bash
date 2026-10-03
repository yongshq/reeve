#!/usr/bin/env bash
# Two cleaners on one errand at once, which a caretaker that no longer stands
# aside for a reeve that is merely alive makes an everyday event rather than a
# theoretical one. A foreground watch and a caretaker can both decide the same
# hand is finished in the same instant, and both hand it to bin/reeve-teardown.
#
# A scout is the case that cannot survive a double teardown. It commits nothing,
# so the landed-work guard has nothing to refuse over and the copy goes for good;
# the danger is not a lost commit but the loser of the race reading a git error
# that looks exactly like the guard refusing, and a session killed twice. So
# every round here asserts the copy was removed exactly ONCE, the session freed
# exactly once, and that neither teardown refused.
#
# Removals are counted at the source: a `git` on PATH that writes one line per
# `worktree remove`, naming the session that ran it, and then runs the real one.
# Nothing is inferred from the filesystem afterwards, which reads the same for
# one removal as for two.
#
# Section 2 does not leave the interleaving to the scheduler. Left alone, the
# watch published its marker first in 50 rounds of 50, the caretaker stood aside
# every time, and the race the section was named for never ran once. So the same
# PATH carries gates: a `mkdir` and a `git` that, when a round arms them, stop
# one process at one named point until the round says go. Each order is forced,
# and each round asserts the order it forced actually happened.
#
# Scratch homes and scratch repositories only, never the real ones.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
[ -n "$real_home" ] || { printf 'FAIL  refusing to run: the real home could not be resolved\n'; exit 1; }
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
for guard in "${REEVE_HOME:-}" "$real_home/.reeve"; do
  [ -n "$guard" ] || continue
  g=$(cd -P "$guard" 2>/dev/null && pwd) || g=$guard
  case $SCRATCH in
    "$g"|"$g"/*) printf 'FAIL  refusing to run: the scratch dir %s is inside %s\n' "$SCRATCH" "$g"; exit 1 ;;
  esac
done
trap 'rm -rf "$SCRATCH"' EXIT

# A stubbed code root, so no session is ever opened and every kill is countable.
STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_launch()          { return 0; }
reeve_backend_stub_agent_state()     { printf 'alive\n'; }
reeve_backend_stub_attention_state() { printf 'settled\n'; }
reeve_backend_stub_wait_change()     { return 2; }
reeve_backend_stub_kill()            { printf '%s\n' "$1" >> "$STUB_KILLS"; return 0; }
ADAPTER
export REEVE_ROOT="$STUB"

REAL_GIT=$(command -v git)
REAL_MKDIR=$(command -v mkdir)
FAKEBIN="$SCRATCH/fakebin"; mkdir -p "$FAKEBIN"
# gate <name>   a no-op unless the round armed <name>. Armed, it is taken once,
# says it is held, and waits for go. A gate never released gives up after
# thirty seconds and says so, so a broken round fails instead of hanging.
cat > "$FAKEBIN/gate" <<'EOF'
#!/bin/sh
[ -n "${GATES:-}" ] || exit 0
mv "$GATES/$1.armed" "$GATES/$1.taken" 2>/dev/null || exit 0
: > "$GATES/$1.held"
n=0
while [ ! -e "$GATES/$1.go" ]; do
  n=$((n + 1)); [ "$n" -lt 600 ] || { : > "$GATES/$1.timeout"; exit 0; }
  sleep 0.05
done
EOF
# Two points in mkdir. <session>-wake: a caretaker that has decided to reap and
# is about to leave its line in the owner's spool. <session>-lock: a teardown
# about to take the errand lock. Every try at that lock is also written down, by
# session, so a round can prove the loser actually waited on it.
cat > "$FAKEBIN/mkdir" <<EOF
#!/bin/sh
case " \$* " in
  *"/sessions/owner/wake"*) "$FAKEBIN/gate" "\${REEVE_SESSION:-}-wake" ;;
  *"/.lock-errand-scout"*)
    "$FAKEBIN/gate" "\${REEVE_SESSION:-}-lock"
    [ -z "\${GATES:-}" ] || printf '%s\n' "\${REEVE_SESSION:-}" >> "\$GATES/lock-tries" ;;
esac
exec "$REAL_MKDIR" "\$@"
EOF
# And one in git. <session>-remove: a teardown holding the errand lock, its
# session already freed, about to remove the copy.
cat > "$FAKEBIN/git" <<EOF
#!/bin/sh
case " \$* " in
  *" worktree remove "*)
    "$FAKEBIN/gate" "\${REEVE_SESSION:-}-remove"
    printf 'remove %s\n' "\${REEVE_SESSION:-}" >> "\$STUB_REMOVES" ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKEBIN/gate" "$FAKEBIN/mkdir" "$FAKEBIN/git"

# scout <round dir>   a fresh home and repository holding one finished scout,
# with a real copy on disk, owned by session `owner`. Sets REEVE_HOME, WT,
# STUB_KILLS and STUB_REMOVES for the round.
scout() {
  local d=$1 repo
  mkdir -p "$d"
  export REEVE_HOME="$d/home" STUB_KILLS="$d/kills" STUB_REMOVES="$d/removes"
  : > "$STUB_KILLS"; : > "$STUB_REMOVES"
  repo="$d/repo"; WT="$d/repo.worktrees/scout"
  mkdir -p "$repo" "$REEVE_HOME/state" "$REEVE_HOME/errands/scout"
  "$REAL_GIT" -C "$repo" init -q -b main
  "$REAL_GIT" -C "$repo" -c user.email=reeve@example.invalid -c user.name=reeve \
      -c commit.gpgsign=false commit -q --allow-empty -m init
  "$REAL_GIT" -C "$repo" worktree add -q --detach "$WT" main
  printf 'target=stub:1\nbackend=stub\noffice=scout\nrepo=%s\nworktree=%s\nbranch=\nbase=main\nwrites=no\ndispatched=2026-10-03T12:00:00\nsession=owner\n' \
    "$repo" "$WT" > "$REEVE_HOME/state/scout.meta"
  printf 'working: reading\ndone: the answer is in report.md\n' > "$REEVE_HOME/errands/scout/status"
}
count() { grep -c . "$1" 2>/dev/null | tr -d '[:space:]'; }

echo "--- 1. two teardowns of one scout, started together ---"
# The mechanism on its own: the watch's reap and the caretaker's reap are both
# exactly this call, so the race between them is a race between two of these.
ROUNDS=20
once=0; freed=0; clean=0; gone=0; n=0
while [ "$n" -lt "$ROUNDS" ]; do
  n=$((n + 1))
  scout "$SCRATCH/t$n"
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/reeve-teardown" scout >"$SCRATCH/t$n/a.out" 2>&1 &
  A=$!
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/reeve-teardown" scout >"$SCRATCH/t$n/b.out" 2>&1 &
  B=$!
  wait "$A"; ra=$?; wait "$B"; rb=$?
  [ "$(count "$STUB_REMOVES")" = 1 ] && once=$((once + 1)) \
    || printf '        round %s removed the copy %s time(s)\n' "$n" "$(count "$STUB_REMOVES")"
  [ "$(count "$STUB_KILLS")" = 1 ] && freed=$((freed + 1)) \
    || printf '        round %s freed the session %s time(s)\n' "$n" "$(count "$STUB_KILLS")"
  [ "$ra:$rb" = 0:0 ] && clean=$((clean + 1)) \
    || printf '        round %s exited %s and %s: %s\n' "$n" "$ra" "$rb" "$(cat "$SCRATCH/t$n"/*.out | tr '\n' ' ')"
  [ -d "$WT" ] || gone=$((gone + 1))
done
eq "1 the copy was removed exactly once in every one of $ROUNDS rounds" "$once"  "$ROUNDS"
eq "1 and the session freed exactly once"                              "$freed" "$ROUNDS"
eq "1 and neither teardown refused, in any round"                      "$clean" "$ROUNDS"
eq "1 and the copy is gone afterwards"                                 "$gone"  "$ROUNDS"

echo "--- 2. a real watch and a real caretaker, in every order they can meet ---"
# The pair itself, as they meet in a home: the owner's foreground watch and a
# caretaker, both real, both reaping only through bin/reeve-teardown. Four
# orders, each forced by the gates above, ROUNDS2 rounds of each:
#
#   care-first      the caretaker is inside teardown, holding the errand lock,
#                   when the watch starts. The watch finds the line already in
#                   its spool and delivers that.
#   care-contended  the caretaker decided to reap before the watch published its
#                   marker, and the watch reports off its cursor too. The
#                   caretaker takes the lock first; the watch tries it while it
#                   is held, and waits.
#   watch-contended the same window, the other way round: the watch holds the
#                   lock and the caretaker, having left its line, waits on it.
#   watch-first     the watch's marker is up before the caretaker looks, so the
#                   caretaker stands aside and the watch alone cleans up.
#
# The two contended orders are the "duplicate, never lost" window: the spool
# holds the line AND the watch reported, so the owner hears it twice. Every
# round, whatever the order: the copy removed exactly once, the session freed
# exactly once, and the owner told at least once, never zero. Told is counted
# across the watch itself and a second watch afterwards that drains the spool.
ROUNDS2=5
GATEWAIT=20
waitfor() { # waitfor <seconds> <condition>   poll a condition, never a blind sleep
  local n=0 limit=$(( ${1:-5} * 20 ))
  while [ "$n" -lt "$limit" ]; do
    eval "$2" && return 0
    sleep 0.05
    n=$((n + 1))
  done
  return 1
}
arm()  { local g; for g in "$@"; do : > "$GATES/$g.armed"; done; }
go()   { : > "$GATES/$1.go"; }
held() { waitfor "$GATEWAIT" "[ -e \"$GATES/$1.held\" ]" || printf '        gate %s was never reached\n' "$1"; }
watch_bg() {
  PATH="$FAKEBIN:$PATH" REEVE_SESSION=owner "$ROOT/bin/reeve-sentry" --once --poll 1 >"$1" 2>&1 &
  W=$!
}
care_bg() {
  PATH="$FAKEBIN:$PATH" REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 \
    >"$1" 2>&1 &
  C=$!
}
tries() { grep -cx "$1" "$GATES/lock-tries" 2>/dev/null | tr -d '[:space:]'; }
spooled() { cat "$REEVE_HOME/state/sessions/owner/wake"/* 2>/dev/null | grep -c 'scout is done' | tr -d '[:space:]'; }

once=0; freed=0; told=0; order=0; window=0; waited=0; caredid=0; total=0
for how in care-first care-contended watch-first watch-contended; do
  n=0
  while [ "$n" -lt "$ROUNDS2" ]; do
    n=$((n + 1)); total=$((total + 1))
    d="$SCRATCH/s-$how-$n"
    scout "$d"
    export GATES="$d/gates"; mkdir -p "$GATES"
    dup=no loser=
    case $how in
      care-first)
        arm janitor-remove
        care_bg "$d/care.out"; held janitor-remove
        [ -d "$REEVE_HOME/state/.lock-errand-scout" ] \
          || printf '        round %s/%s: the caretaker was not holding the errand lock\n' "$how" "$n"
        watch_bg "$d/fg.out"; wait "$W"
        go janitor-remove; wait "$C"
        want=janitor ;;
      care-contended)
        arm janitor-wake owner-lock janitor-remove
        care_bg "$d/care.out"; held janitor-wake
        watch_bg "$d/fg.out"; held owner-lock
        go janitor-wake; held janitor-remove
        go owner-lock
        waitfor "$GATEWAIT" '[ "$(tries owner)" -ge 1 ]'
        go janitor-remove; wait "$C"; wait "$W"
        want=janitor dup=yes loser=owner ;;
      watch-first)
        arm owner-remove
        watch_bg "$d/fg.out"; held owner-remove
        care_bg "$d/care.out"; wait "$C"
        go owner-remove; wait "$W"
        want=owner ;;
      watch-contended)
        arm janitor-wake owner-remove
        care_bg "$d/care.out"; held janitor-wake
        watch_bg "$d/fg.out"; held owner-remove
        go janitor-wake
        waitfor "$GATEWAIT" '[ "$(tries janitor)" -ge 1 ]'
        go owner-remove; wait "$W"; wait "$C"
        want=owner dup=yes loser=janitor ;;
    esac
    ls "$GATES"/*.timeout >/dev/null 2>&1 \
      && printf '        round %s/%s: a gate timed out: %s\n' "$how" "$n" "$(ls "$GATES")"
    inspool=$(spooled)
    lost=$( [ "$dup" = yes ] && tries "$loser" )
    unset GATES
    PATH="$FAKEBIN:$PATH" REEVE_SESSION=owner "$ROOT/bin/reeve-sentry" --once --poll 1 >"$d/fg2.out" 2>&1
    said=$(cat "$d/fg.out" "$d/fg2.out" | grep -c 'scout is done' | tr -d '[:space:]')

    [ "$(count "$STUB_REMOVES")" = 1 ] && once=$((once + 1)) \
      || printf '        round %s/%s removed the copy %s time(s)\n' "$how" "$n" "$(count "$STUB_REMOVES")"
    [ "$(count "$STUB_KILLS")" = 1 ] && freed=$((freed + 1)) \
      || printf '        round %s/%s freed the session %s time(s)\n' "$how" "$n" "$(count "$STUB_KILLS")"
    [ "${said:-0}" -ge 1 ] && told=$((told + 1)) \
      || printf '        round %s/%s: the owner was never told. watch said [%s], then [%s]\n' "$how" "$n" \
           "$(tr '\n' ' ' < "$d/fg.out")" "$(tr '\n' ' ' < "$d/fg2.out")"
    by=$(sed -n 's/^remove //p' "$STUB_REMOVES" | head -1)
    [ "$by" = "$want" ] && order=$((order + 1)) \
      || printf '        round %s/%s: the copy was removed by [%s], forced order wanted [%s]\n' "$how" "$n" "$by" "$want"
    [ "$by" = janitor ] && caredid=$((caredid + 1))
    if [ "$dup" = yes ]; then
      if grep -qF 'signal: scout is done - ' "$d/fg.out" && [ "${inspool:-0}" -ge 1 ]; then
        window=$((window + 1))
      else
        printf '        round %s/%s: the window did not open. watch said [%s], spool held %s\n' \
          "$how" "$n" "$(tr '\n' ' ' < "$d/fg.out")" "${inspool:-0}"
      fi
      # Two tries: the one refused while the winner held the lock, and the one
      # that took it after. One would mean the loser never met the lock held.
      [ "${lost:-0}" -ge 2 ] && waited=$((waited + 1)) \
        || printf '        round %s/%s: %s tried the lock %s time(s), never while it was held\n' \
             "$how" "$n" "$loser" "${lost:-0}"
    fi
  done
done
eq "2 every forced order happened as forced, in all $total rounds"        "$order"  "$total"
eq "2 the copy was removed exactly once in every round"                    "$once"   "$total"
eq "2 and the session freed exactly once"                                  "$freed"  "$total"
eq "2 and the owner was told at least once in every round, never zero"     "$told"   "$total"
eq "2 the duplicate window opened in every contended round"                "$window" "$((ROUNDS2 * 2))"
eq "2 and in each the loser met the errand lock held, and waited"          "$waited" "$((ROUNDS2 * 2))"
eq "2 the caretaker did the teardown in $((ROUNDS2 * 2)) of them"          "$caredid" "$((ROUNDS2 * 2))"

echo "--- 3. a kept hand stays up, whoever holds the home ---"
# REEVE_NO_CARETAKER=1 promises a finished hand stays up for debugging, and a
# switch that only skips its own dispatch's caretaker stopped working the moment
# any other caretaker held the home: one poll later the hand was gone. So the
# opt-out is keep= on the errand itself, and every cleaner reads it. The
# reviewer's probe: a finished scout, its owner alive and not watching, kept.
scout "$SCRATCH/k1"
printf 'keep=REEVE_NO_CARETAKER\n' >> "$REEVE_HOME/state/scout.meta"
mkdir -p "$REEVE_HOME/state/sessions/owner"
date +%s > "$REEVE_HOME/state/sessions/owner/seen"
PATH="$FAKEBIN:$PATH" REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1
eq "3 a caretaker frees nothing of a kept hand"     "$(count "$STUB_KILLS")" 0
eq "3 and leaves its copy"                          "$([ -d "$WT" ] && echo kept || echo removed)" kept
eq "3 and leaves no line, it is still in flight"    "$(spooled)" 0
OUT=$(PATH="$FAKEBIN:$PATH" REEVE_SESSION=owner "$ROOT/bin/reeve-sentry" --once --poll 1 2>&1)
case $OUT in *'scout is done'*'[session kept'*) ok "3 the owner's watch reports it, and says it was kept" ;;
  *) bad "3 the owner's watch reports it, and says it was kept" "$OUT" ;; esac
eq "3 and frees nothing either"                     "$(count "$STUB_KILLS") $([ -d "$WT" ] && echo kept || echo removed)" "0 kept"
PATH="$FAKEBIN:$PATH" REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1
eq "3 still up after another caretaker pass"        "$(count "$STUB_KILLS") $([ -d "$WT" ] && echo kept || echo removed)" "0 kept"

# The same probe without keep=: freed as before.
scout "$SCRATCH/k2"
mkdir -p "$REEVE_HOME/state/sessions/owner"
date +%s > "$REEVE_HOME/state/sessions/owner/seen"
PATH="$FAKEBIN:$PATH" REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 >/dev/null 2>&1
eq "3 without it the caretaker frees the hand"      "$(count "$STUB_KILLS")" 1
eq "3 and removes the copy"                         "$([ -d "$WT" ] && echo kept || echo removed)" removed
eq "3 with the line left for its owner"             "$(spooled)" 1

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
