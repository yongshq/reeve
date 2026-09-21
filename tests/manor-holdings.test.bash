#!/usr/bin/env bash
# A hand and the rest of its manor.
#
# A manor is one project that may span several repositories, and until now a
# hand could reach its own working copy and its errand directory and nothing
# else. A scout asked why the web app mishandles a response from the API could
# not open the API repository at all. Worse, it could not say so: the refusal
# arrives INSIDE a tool call, so the hand never appends `blocked:`, its last line
# stays `working:`, and the watch reads it as a healthy hand thinking.
#
# The grant has to come with its own limit. `--add-dir` gives read AND write and
# there is no read-only form, so the write half is taken back by a path-scoped
# deny in the errand's own settings file. Two leading slashes is the absolute
# form; one anchors the pattern at the settings file's directory and would match
# nothing, leaving the grant unguarded.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got  [$2]
want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "did not mention [$3] in: $2"; fi; }
nas() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "should not have mentioned [$3]"; else ok "$1"; fi; }

real_home=$(cd "${HOME:-/nonexistent-home}" 2>/dev/null && pwd -P) || real_home=/nonexistent-home
[ -n "$real_home" ] || { printf 'FAIL  refusing to run: the real home could not be resolved\n'; exit 1; }
SCRATCH=$(mktemp -d) && SCRATCH=$(cd -P "$SCRATCH" && pwd) \
  || { printf 'FAIL  could not make a scratch directory\n'; exit 1; }
case $SCRATCH in "$real_home"|"$real_home"/*) printf 'FAIL  refusing: scratch is inside the real home\n'; exit 1 ;; esac
trap 'rm -rf "$SCRATCH"' EXIT
export REEVE_HOME="$SCRATCH/home"
# No caretaker, and a claude config of this suite's own, so nothing reaches the
# liege's real machine state.
export REEVE_NO_CARETAKER=1
export CLAUDE_CONFIG="$SCRATCH/claude.json"

mkrepo() {
  mkdir -p "$SCRATCH/$1"
  ( cd "$SCRATCH/$1" && git init -q . \
    && git -c user.email=r@invalid -c user.name=r -c commit.gpgsign=false commit -q --allow-empty -m init )
}
mkrepo web; mkrepo api; mkrepo unrelated
python3 - "$CLAUDE_CONFIG" "$SCRATCH" <<'PY'
import json,sys,os
cfg,root=sys.argv[1],sys.argv[2]
p={os.path.realpath(os.path.join(root,n)):{"hasTrustDialogAccepted":True} for n in ("web","api","unrelated")}
json.dump({"projects":p},open(cfg,"w"))
PY

STUB="$SCRATCH/root"
mkdir -p "$STUB/backends" "$STUB/harnesses"
cp -R "$ROOT/offices" "$STUB/offices"
cat > "$STUB/backends/stub.sh" <<'ADAPTER'
reeve_backend_stub_available()       { return 0; }
reeve_backend_stub_describe()        { printf 'stub backend\n'; }
reeve_backend_stub_create_endpoint() { printf 'stub:1\n'; }
reeve_backend_stub_launch()          { return 0; }
ADAPTER
cat > "$STUB/harnesses/stub.toml" <<'HARNESS'
bin = "true"
verified = true
launch = "{bin} {dirs} {settings} {prompt}"
settings_flag = "--settings {settings}"
dirs_flag = "--add-dir {dir}"
prompt_mode = "argv"
HARNESS

reg() { "$ROOT/bin/reeve-survey" --register "$1" --manor "$2" --path "$SCRATCH/$3" >/dev/null; }
reg web product web
reg api product api
reg other separate unrelated

go() { # go <id> <holding> <office> [args...] -> OUT/RC
  "$ROOT/bin/reeve-brief" "$1" "$2" --office "$3" >/dev/null 2>&1 || { OUT='brief refused'; RC=99; return; }
  local b="$REEVE_HOME/errands/$1/brief.md"
  sed -e 's/{INTENT}/the liege said so/' -e 's/{SPEC}/do the thing/' "$b" > "$b.f" && mv "$b.f" "$b"
  shift 3
  OUT=$(REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" "$1" --backend stub --harness stub "$@" 2>&1); RC=$?
}

echo "--- 1. a hand is granted the rest of its manor ---"
"$ROOT/bin/reeve-brief" look web --office scout >/dev/null 2>&1
b="$REEVE_HOME/errands/look/brief.md"; sed -e 's/{INTENT}/x/' -e 's/{SPEC}/y/' "$b" > "$b.f" && mv "$b.f" "$b"
OUT=$(REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" look --backend stub --harness stub --dry-run 2>&1)
has "1 it says which manor it is opening up"  "$OUT" "other holding(s) in manor 'product'"
has "1 the errand directory is still granted" "$OUT" "--add-dir $REEVE_HOME/errands/look"
has "1 and so is the sibling holding"         "$OUT" "--add-dir $SCRATCH/api"
nas "1 but never its own holding twice"       "$OUT" "--add-dir $SCRATCH/web"
nas "1 nor a repo from another manor"         "$OUT" "--add-dir $SCRATCH/unrelated"

echo "--- 2. a manor of one grants nothing extra ---"
"$ROOT/bin/reeve-brief" solo other --office scout >/dev/null 2>&1
b="$REEVE_HOME/errands/solo/brief.md"; sed -e 's/{INTENT}/x/' -e 's/{SPEC}/y/' "$b" > "$b.f" && mv "$b.f" "$b"
OUT=$(REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" solo --backend stub --harness stub --dry-run 2>&1)
nas "2 no grant is announced"                 "$OUT" "other holding(s) in manor"
eq  "2 exactly one directory is granted"      "$(printf '%s' "$OUT" | grep -o -- '--add-dir' | wc -l | tr -d ' ')" 1

echo "--- 3. the write half is taken back, in the errand's own settings ---"
"$ROOT/bin/reeve-brief" build web --office artificer >/dev/null 2>&1
b="$REEVE_HOME/errands/build/brief.md"; sed -e 's/{INTENT}/x/' -e 's/{SPEC}/y/' "$b" > "$b.f" && mv "$b.f" "$b"
OUT=$(REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" build --backend stub --harness stub 2>&1)
S="$REEVE_HOME/errands/build/settings.json"
eq  "3 the errand has its own settings file"  "$([ -f "$S" ] && echo yes || echo no)" yes
deny=$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['permissions'].get('deny',[])))" "$S" 2>/dev/null)
has "3 the sibling is denied for Edit"        "$deny" "Edit(//$(cd "$SCRATCH/api" && pwd -P | sed 's|^/||')/**)"
nas "3 and its own copy is NOT denied"        "$deny" "$(cd "$SCRATCH/web" && pwd -P)/**"
# Two slashes, not one. A single leading slash anchors at the settings file's
# own directory, so the rule would match nothing and the grant would be a
# straight read-write handout.
has "3 written in the absolute form"          "$deny" "Edit(//"
nas "3 never the settings-relative form"      "$deny" "Edit(/$(cd "$SCRATCH/api" && pwd -P | sed 's|^/||')"
# Only Edit and Read are ever consulted: a Write() or Glob() rule is accepted
# and silently never checked, so writing one would look like protection and be
# none.
nas "3 no rule the harness would ignore"      "$deny" "Write("
nas "3 nor a Glob one"                        "$deny" "Glob("
eq  "3 the office's own file is untouched"    "$(grep -c 'deny' "$STUB/offices/artificer.settings.json")" 0

echo "--- 4. a dry run still writes nothing ---"
"$ROOT/bin/reeve-brief" peek web --office scout >/dev/null 2>&1
b="$REEVE_HOME/errands/peek/brief.md"; sed -e 's/{INTENT}/x/' -e 's/{SPEC}/y/' "$b" > "$b.f" && mv "$b.f" "$b"
REEVE_ROOT="$STUB" "$ROOT/bin/reeve-dispatch" peek --backend stub --harness stub --dry-run >/dev/null 2>&1
eq  "4 no settings file was left behind"      "$([ -e "$REEVE_HOME/errands/peek/settings.json" ] && echo present || echo absent)" absent

printf '\npassed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
