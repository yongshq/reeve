#!/usr/bin/env bash
# The shared household browser: one headless Chrome every hand's browser tools
# attach to, because each fresh Chrome launch on macOS restarts the Dock. What
# has to hold:
#
#   1. the mode and the port are read strictly, and 9222 is never accepted
#   2. the shared config attaches by --browserUrl and launches nothing
#   3. start proves the browser its own before handing out its url, reuses a
#      live one, restarts a dead one, and refuses a port something else holds
#   4. it is stopped only once no errand uses it, a dispatch in flight included,
#      and a session that is dead or missing is no user
#   5. the watch's tend restarts it when it died under a user, and only then
#   6. every start begins with an empty default context, and keeps the rest
#      of the profile, whose loss would cost a Dock restart
#
# Chrome is a stand-in: a small python server that answers /json/version on the
# port it is given, exec'd so it keeps the pid it was started with, as Chrome
# does. Nothing here launches a browser or touches the network.
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
FOREIGN=''
cleanup() {
  [ -n "$FOREIGN" ] && kill "$FOREIGN" 2>/dev/null
  REEVE_HOME="$SCRATCH/home" "$ROOT/bin/reeve-browser" stop >/dev/null 2>&1
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
export REEVE_HOME="$SCRATCH/home"
mkdir -p "$REEVE_HOME/config" "$REEVE_HOME/state"
lib() { "$BASH" -c '. "$1/bin/reeve-lib.sh"; shift; "$@"' _ "$ROOT" "$@"; }

# --- 1. mode and port ---------------------------------------------------------
case $(uname -s) in Darwin) want=shared ;; *) want=isolated ;; esac
eq  "1 the default mode follows the platform"   "$(lib browser_mode)" "$want"
for m in shared isolated; do
  printf '%s\n' "$m" > "$REEVE_HOME/config/browser-mode"
  eq "1 config/browser-mode $m is read"         "$(lib browser_mode)" "$m"
done
printf 'sharde\n' > "$REEVE_HOME/config/browser-mode"
out=$(lib browser_mode); rc=$?
eq  "1 a typo is refused"                        "$rc" 1
has "1 and named"                                "$out" "config/browser-mode says sharde"
rm -f "$REEVE_HOME/config/browser-mode"

eq  "1 the default port"                         "$(lib browser_port)" 9333
for p in 9222 80 70000 abc; do
  printf '%s\n' "$p" > "$REEVE_HOME/config/browser-port"
  out=$(lib browser_port); rc=$?
  eq "1 port $p is refused" "$rc" 1
done
has "1 9222 is refused by name"                  "$(echo 9222 > "$REEVE_HOME/config/browser-port"; lib browser_port)" \
    "the port a person's own browser debugs on"
rm -f "$REEVE_HOME/config/browser-port"

# --- 2. the shared config ---------------------------------------------------
cfg="$SCRATCH/browser.json"
lib browser_config_write "$cfg" "/Apps/Chrome \"x\".app/chrome" http://127.0.0.1:9333
body=$(cat "$cfg")
has "2 it attaches to the shared browser"        "$body" '"--browserUrl", "http://127.0.0.1:9333"'
has "2 the package is still pinned, cache first" "$body" '"--prefer-offline", "-y", "chrome-devtools-mcp@'
for never in --isolated --headless --executablePath wsEndpoint autoConnect 9222 userDataDir; do
  nas "2 it launches nothing and attaches nowhere else: $never" "$body" "$never"
done
has "2 no usage reporting"                       "$body" '"--no-usage-statistics"'
if command -v python3 >/dev/null 2>&1; then
  got=$(python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["mcpServers"]["reeve-browser"]["args"]
print(a[a.index("--browserUrl") + 1])' "$cfg" 2>&1)
  eq "2 valid JSON"                              "$got" http://127.0.0.1:9333
fi

# --- 3 and 4 need a stand-in Chrome -----------------------------------------
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 \
   || { ! command -v lsof >/dev/null 2>&1 && ! command -v ss >/dev/null 2>&1; }; then
  ok "3 lifecycle (skipped: needs python3, curl, and lsof or ss)"
  echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; exit
fi

fake="$SCRATCH/fake chrome/chrome"
mkdir -p "$(dirname "$fake")"
cat > "$SCRATCH/fake chrome/devtools.py" <<'PY'
import http.server, json, sys
port = next(int(a.split("=", 1)[1]) for a in sys.argv if a.startswith("--remote-debugging-port="))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"Browser": "Fake/1",
                           "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/browser/x" % port}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$SCRATCH/fake chrome/devtools.py" > "$fake"
chmod +x "$fake"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
printf '%s\n' "$port" > "$REEVE_HOME/config/browser-port"
printf '%s\n' "$fake" > "$REEVE_HOME/config/browser-chrome"
B="$ROOT/bin/reeve-browser"
pid_of() { cat "$REEVE_HOME/state/browser/pid" 2>/dev/null; }

out=$("$B" status)
has "3 stopped before anything asked for it"     "$out" "state     stopped"
url=$(lib browser_shared_ensure "$fake"); rc=$?
eq  "3 ensure starts it"                         "$rc" 0
eq  "3 and prints its url"                       "$url" "http://127.0.0.1:$port"
pid1=$(pid_of)
has "3 on the household profile"                 "$(ps -ww -o command= -p "$pid1")" \
    "--user-data-dir=$REEVE_HOME/state/browser/profile"
has "3 headless, on the configured port"         "$(ps -ww -o command= -p "$pid1")" \
    "--headless=new --remote-debugging-port=$port"
has "3 status says running"                      "$("$B" status)" "state     running, pid $pid1"
lib browser_shared_ensure "$fake" >/dev/null
eq  "3 a live one is reused, not relaunched"     "$(pid_of)" "$pid1"

kill -9 "$pid1"; sleep 0.5
url=$(lib browser_shared_ensure "$fake"); rc=$?
eq  "3 a dead one is restarted"                  "$rc" 0
pid2=$(pid_of)
[ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && ok "3 as a new process" || bad "3 as a new process" "$pid1 $pid2"

# A pid file naming a live process that is not ours is never trusted or signalled.
"$B" stop >/dev/null
sleep 30 & other=$!
printf '%s\n' "$other" > "$REEVE_HOME/state/browser/pid"
lib browser_shared_pid >/dev/null && bad "3 a reused pid is not ours" || ok "3 a reused pid is not ours"
"$B" stop >/dev/null
kill -0 "$other" 2>/dev/null && ok "3 and stop never signals it" || bad "3 and stop never signals it"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

# Something else on the port: refused, never attached to, nothing launched.
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 & FOREIGN=$!
n=0; while [ "$n" -lt 40 ] && ! curl -s -o /dev/null "http://127.0.0.1:$port/"; do sleep 0.1; n=$((n+1)); done
out=$(lib browser_shared_ensure "$fake"); rc=$?
eq  "3 a port someone else holds is refused"    "$rc" 1
has "3 and says so"                              "$out" "already answers, and not as the household browser"
eq  "3 with nothing launched"                    "$(pid_of)" ""
kill "$FOREIGN" 2>/dev/null; wait "$FOREIGN" 2>/dev/null; FOREIGN=''

# A Chrome that dies at once is reported, quickly, rather than waited on.
dud="$SCRATCH/dud"; printf '#!/bin/sh\nexit 1\n' > "$dud"; chmod +x "$dud"
t0=$(date +%s)
out=$(lib browser_shared_ensure "$dud"); rc=$?
eq  "3 a Chrome that will not start is refused" "$rc" 1
has "3 naming its log"                           "$out" "did not come up on port $port"
[ $(( $(date +%s) - t0 )) -lt 10 ] && ok "3 without waiting out the bound" \
  || bad "3 without waiting out the bound" "took $(( $(date +%s) - t0 ))s"

# --- 4. stopped only once nobody uses it ------------------------------------
# A stub backend, in a scratch code root, whose agent_state for stub:<name> is
# whatever $STATES/<name> says, alive when it says nothing.
export REEVE_ROOT="$SCRATCH/root" STATES="$SCRATCH/states"
mkdir -p "$REEVE_ROOT/backends" "$STATES"
cat > "$REEVE_ROOT/backends/stub.sh" <<'STUB'
reeve_backend_stub_available()   { return 0; }
reeve_backend_stub_describe()    { echo stub; }
reeve_backend_stub_agent_state() { cat "$STATES/${1#stub:}" 2>/dev/null || echo alive; }
reeve_backend_stub_attention_state() { echo unknown; }
reeve_backend_stub_capture()     { echo; }
reeve_backend_stub_wait_change() { return 2; }
STUB
lib browser_shared_ensure "$fake" >/dev/null
rec() { # rec <id> <key=value>...
  local id=$1; shift
  printf '%s\n' backend=stub "$@" > "$REEVE_HOME/state/$id.meta"
}
rec busy browserMode=shared target=stub:1
rec other browserMode=isolated target=stub:2
rec gone browserMode=shared target= tornDown=2026-10-25T00:00:00
eq  "4 users: only a shared errand holding a session" "$(lib browser_shared_users)" busy
for st in dead missing; do
  echo "$st" > "$STATES/1"
  eq "4 a session reading $st is no user"        "$(lib browser_shared_users)" ""
done
echo unreadable > "$STATES/1"
eq  "4 one that cannot be read still is"         "$(lib browser_shared_users)" busy
echo dead > "$STATES/1"
rec busy browserMode=shared target=stub:1 "browserSince=$(date +%s)"
eq  "4 a session just recorded counts before it reads alive" "$(lib browser_shared_users)" busy
echo missing > "$STATES/1"
eq  "4 unless it is already gone"                "$(lib browser_shared_users)" ""
echo dead > "$STATES/1"
rec busy browserMode=shared target=stub:1 "browserSince=$(( $(date +%s) - 600 ))"
eq  "4 and not for ever"                         "$(lib browser_shared_users)" ""
out=$(lib browser_shared_release)
has "4 so a crashed hand's record does not keep it up" "$out" "stopped the shared browser"
rm -f "$STATES/1"
lib browser_shared_ensure "$fake" >/dev/null
rec busy browserMode=shared target=stub:1
lib browser_shared_release >/dev/null
has "4 kept while one uses it"                   "$("$B" status)" "state     running"
rec busy browserMode=shared target=
rec starting browserMode=shared browserHeld=$$
eq  "4 a dispatch in flight holds it"            "$(lib browser_shared_users)" starting
lib browser_shared_release >/dev/null
has "4 and keeps it running"                     "$("$B" status)" "state     running"
rec starting browserMode=shared browserHeld=999999
out=$(lib browser_shared_release)
has "4 stopped once nobody uses it"              "$out" "stopped the shared browser"
has "4 and status agrees"                        "$("$B" status)" "state     stopped"
lib browser_shared_release >/dev/null; eq "4 a second release is quiet" "$?" 0

# reeve-browser stop names who loses it.
lib browser_shared_ensure "$fake" >/dev/null
rec busy browserMode=shared target=stub:1
out=$("$B" stop 2>&1)
has "4 stop by hand stops it"                    "$out" "stopped the shared browser"
has "4 and names the errands that lose it"       "$out" "errands still using it lose their browser tools: busy"

# --- 5. the tend: restarted under a user, and only then ---------------------
out=$(lib browser_shared_tend 2>&1)
eq  "5 a stop by hand stands"                    "$(pid_of)" ""
has "5 and status says so"                       "$("$B" status)" "stopped by hand"
lib browser_shared_ensure "$fake" >/dev/null
pid1=$(pid_of)
out=$(lib browser_shared_tend 2>&1)
eq  "5 a live one is left alone"                 "$(pid_of)" "$pid1"
eq  "5 quietly"                                  "$out" ""
kill -9 "$pid1"; sleep 0.5
out=$(lib browser_shared_tend 2>&1)
pid2=$(pid_of)
[ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && ok "5 one that died under a user is restarted" \
  || bad "5 one that died under a user is restarted" "$pid1 $pid2"
has "5 and it says for whom"                     "$out" "restarted the shared browser at http://127.0.0.1:$port for: busy"
has "5 it answers again"                         "$("$B" status)" "state     running, pid $pid2"
echo missing > "$STATES/1"
kill -9 "$pid2"; sleep 0.5
out=$(lib browser_shared_tend 2>&1)
eq  "5 with no user left it stays down"          "$(pid_of)" "$pid2"
nas "5 and nothing is started"                   "$("$B" status)" "state     running"
rm -f "$STATES/1"
cp "$REEVE_HOME/state/browser/chrome" "$SCRATCH/chrome.kept"
printf '%s\n' "$dud" > "$REEVE_HOME/state/browser/chrome"
out=$(lib browser_shared_tend 2>&1)
has "5 a restart that fails says so"             "$out" "would not restart, next try in"
out=$(lib browser_shared_tend 2>&1)
eq  "5 and is not retried every poll"            "$out" ""
cp "$SCRATCH/chrome.kept" "$REEVE_HOME/state/browser/chrome"
rm -f "$REEVE_HOME/state/browser/tend-failed"

# The watch tends it on its poll; a --no-reap watch, which changes nothing,
# does not.
lib browser_shared_ensure "$fake" >/dev/null
mkdir -p "$REEVE_HOME/errands/busy"
printf 'working: looking at a page\n' > "$REEVE_HOME/errands/busy/status"
pid1=$(pid_of); kill -9 "$pid1"; sleep 0.5
"$ROOT/bin/reeve-sentry" --once --no-reap >/dev/null 2>&1
eq  "5 a --no-reap watch leaves it down"         "$(pid_of)" "$pid1"
out=$("$ROOT/bin/reeve-sentry" --once 2>&1 >/dev/null)
pid2=$(pid_of)
[ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && ok "5 a watch restarts it on its poll" \
  || bad "5 a watch restarts it on its poll" "$pid1 $pid2: $out"
has "5 and says so on stderr"                    "$out" "restarted the shared browser"

# --- 6. an empty default context at every start ------------------------------
"$B" stop >/dev/null 2>&1
lib browser_shared_ensure "$fake" >/dev/null
prof="$REEVE_HOME/state/browser/profile"
mkdir -p "$prof/Default"
printf 'left by a page\n' > "$prof/Default/Cookies"
printf 'browser state\n' > "$prof/Local State"
lib browser_shared_ensure "$fake" >/dev/null
eq  "6 a running browser keeps its storage"      "$(cat "$prof/Default/Cookies" 2>/dev/null)" "left by a page"
"$B" stop >/dev/null 2>&1
lib browser_shared_ensure "$fake" >/dev/null
eq  "6 a new start finds no page storage" \
    "$([ -e "$prof/Default" ] && echo present || echo absent)" absent
eq  "6 and keeps the rest of the profile"        "$(cat "$prof/Local State" 2>/dev/null)" "browser state"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
