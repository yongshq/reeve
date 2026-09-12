#!/usr/bin/env bash
# Briefs are built from heredocs. An UNQUOTED heredoc evaluates backticks and
# $(...) as commands, so a backtick in prose becomes a command substitution and
# the brief silently loses text while the shell reports "command not found".
# This happened once, to the line telling hands to stop after reporting done.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import sys, io, re, os, glob
root=sys.argv[1]; bad=0; checked=0
for p in sorted(glob.glob(os.path.join(root,'bin','*'))):
    if not os.path.isfile(p): continue
    try: lines=io.open(p,encoding='utf-8').read().splitlines()
    except Exception: continue
    checked+=1
    delim=None; quoted=False
    for i,l in enumerate(lines,1):
        if delim is None:
            m=re.match(r"\s*cat <<(-?)('?)([A-Za-z0-9_]+)\2\s*$", l)
            if m: delim=m.group(3); quoted=bool(m.group(2))
            continue
        if l.strip()==delim: delim=None; continue
        if quoted: continue
        if re.search(r"(?<!\\)`", l):
            print(f"FAIL  {os.path.basename(p)}:{i} bare backtick in unquoted heredoc <<{delim}")
            print(f"      {l.strip()[:90]}")
            bad+=1
print(f"checked {checked} script(s)")
print("ok    no bare backticks in unquoted heredocs" if not bad else f"{bad} problem(s)")
sys.exit(1 if bad else 0)
PY
