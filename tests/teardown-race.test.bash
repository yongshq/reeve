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
# `worktree remove` and then runs the real one. Nothing is inferred from the
# filesystem afterwards, which reads the same for one removal as for two.
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
FAKEBIN="$SCRATCH/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/git" <<EOF
#!/bin/sh
case " \$* " in
  *" worktree remove "*) printf 'remove\n' >> "\$STUB_REMOVES" ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKEBIN/git"

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

echo "--- 2. a real watch and a real caretaker, started together ---"
# The pair itself, as they meet in a home: the owner's foreground watch and the
# caretaker started in the same instant, before the watch has published the
# marker that would make the caretaker stand aside. Whichever wins, the copy
# goes once and the `done:` line reaches the owner, said by the watch or left in
# its spool for the next one. Never neither.
ROUNDS2=10
once=0; freed=0; told=0; n=0
while [ "$n" -lt "$ROUNDS2" ]; do
  n=$((n + 1))
  scout "$SCRATCH/s$n"
  PATH="$FAKEBIN:$PATH" REEVE_SESSION=owner "$ROOT/bin/reeve-sentry" --once --poll 1 \
    >"$SCRATCH/s$n/fg.out" 2>&1 &
  W=$!
  PATH="$FAKEBIN:$PATH" REEVE_SESSION=janitor "$ROOT/bin/reeve-sentry" --caretaker --once --poll 1 \
    >"$SCRATCH/s$n/care.out" 2>&1 &
  C=$!
  wait "$W"; wait "$C"
  [ "$(count "$STUB_REMOVES")" = 1 ] && once=$((once + 1)) \
    || printf '        round %s removed the copy %s time(s)\n' "$n" "$(count "$STUB_REMOVES")"
  [ "$(count "$STUB_KILLS")" = 1 ] && freed=$((freed + 1)) \
    || printf '        round %s freed the session %s time(s)\n' "$n" "$(count "$STUB_KILLS")"
  if grep -qF 'scout is done' "$SCRATCH/s$n/fg.out" \
     || grep -rqF 'scout is done' "$REEVE_HOME/state/sessions/owner/wake" 2>/dev/null; then
    told=$((told + 1))
  else
    printf '        round %s: the watch said [%s] and the spool holds nothing\n' "$n" "$(tr '\n' ' ' < "$SCRATCH/s$n/fg.out")"
  fi
done
eq "2 the copy was removed exactly once in every one of $ROUNDS2 rounds" "$once"  "$ROUNDS2"
eq "2 and the session freed exactly once"                               "$freed" "$ROUNDS2"
eq "2 and the owner was told in every round"                            "$told"  "$ROUNDS2"

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
