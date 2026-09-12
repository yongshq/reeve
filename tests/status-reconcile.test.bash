#!/usr/bin/env bash
export REEVE_HOME=$(mktemp -d)/reeve-home-test
rm -rf "$REEVE_HOME"; mkdir -p "$REEVE_HOME/errands/t"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/reeve-lib.sh"
PASS=0; FAIL=0
t() {
  local name=$1 xs=$2 xo=$3 xd=$4
  cat > "$(status_file t)"
  local out s o d
  out=$(status_reconcile t)
  s=$(printf '%s\n' "$out" | grep -m1 '^state='      | sed 's/^state=//')
  o=$(printf '%s\n' "$out" | grep -m1 '^open='       | sed 's/^open=//')
  d=$(printf '%s\n' "$out" | grep -m1 '^divergence=' | sed 's/^divergence=//')
  if [ "$s" = "$xs" ] && [ "$o" = "$xo" ] && [ "$d" = "$xd" ]; then
    PASS=$((PASS+1)); printf 'ok    %-40s state=%s open=%s div=%s\n' "$name" "$s" "$o" "$d"
  else
    FAIL=$((FAIL+1)); printf 'FAIL  %-40s got %s/%s/%s want %s/%s/%s\n' "$name" "$s" "$o" "$d" "$xs" "$xo" "$xd"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

t "plain progress" working 0 no <<'X'
working: reading the auth module
X
t "finished clean" done 0 no <<'X'
working: reading the auth module
done: branch feat/auth-refresh, 3 commits
X
t "blocked" blocked 0 no <<'X'
working: started
blocked: pnpm install fails, no .env present
X
t "open decision" needs-decision 1 no <<'X'
working: started
needs-decision [key=copy]: Save or Submit on the button?
X
t "decision then resolved" done 0 no <<'X'
needs-decision [key=copy]: Save or Submit?
resolved [key=copy]: use Save
done: branch feat/x, 1 commit
X
t "DONE MUST NOT CLOSE DECISION" needs-decision 1 yes <<'X'
needs-decision [key=copy]: Save or Submit?
done: branch feat/x, 1 commit
X
t "wrong key does not close it" needs-decision 1 yes <<'X'
needs-decision [key=copy]: Save or Submit?
resolved [key=other]: unrelated
done: shipped
X
t "two open one resolved" needs-decision 1 no <<'X'
needs-decision [key=a]: first question
needs-decision [key=b]: second question
resolved [key=a]: answered
X
t "duplicate ask dedupes" needs-decision 1 no <<'X'
needs-decision [key=a]: first question
needs-decision [key=a]: nagging again
X
t "unkeyed decision opens" needs-decision 1 no <<'X'
needs-decision: which colour?
X
t "failed with open decision" needs-decision 1 yes <<'X'
needs-decision [key=a]: q
failed: gave up
X
t "unknown verb ignored" working 0 no <<'X'
working: fine
banana: what even is this
X
t "empty file" unknown 0 no <<'X'
X
t "note containing a colon" done 0 no <<'X'
done: branch feat/x: 3 commits at 10:30
X
t "bracket inside a note is safe" working 0 no <<'X'
working: renamed [key=foo] to bar
X
t "blocked then recovered then done" done 0 no <<'X'
blocked: waiting on env
working: env fixed, continuing
done: shipped
X
echo
echo "--- open decisions, in ask order, resolved one dropped ---"
cat > "$(status_file t)" <<'X'
needs-decision [key=copy]: Save or Submit on the button?
needs-decision [key=scope]: Should I also fix the adjacent typo?
resolved [key=copy]: use Save
X
status_reconcile t
echo "--- absent errand ---"
status_reconcile nonexistent
echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
