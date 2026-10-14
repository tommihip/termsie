#!/usr/bin/env bash
#
# Drives the Linux app headlessly and checks what it does: the bash port of test-windows.ps1.
#
# Every run uses a throwaway XDG_CONFIG_HOME and XDG_STATE_HOME, so the user's real
# configuration, workspaces, session, keyring and log are never touched (secrets go to a JSON
# file through TERMSIE_SECRETS_FILE). Screenshots and logs land in the output folder, for a
# person to look at when a check fails.
#
#     ./scripts/test-linux.sh [path/to/Termsie] [output-folder]
#
# Without a display it runs itself under xvfb-run, which CI has.
set -u
BIN=${1:-.build/debug/Termsie}
OUT=${2:-test-output}
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  if command -v xvfb-run >/dev/null; then
    export GSK_RENDERER=cairo
    exec xvfb-run -a -s "-screen 0 1600x1000x24" "$0" "$BIN" "$OUT"
  fi
  echo "no display and no xvfb-run" >&2
  exit 2
fi
# Wayland lets a window claim the clipboard only after a real input event, which a scripted run
# never gives it; the X11 backend (XWayland on a Wayland desktop) has no such rule.
[ -n "${DISPLAY:-}" ] && export GDK_BACKEND=x11
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BIN="$(realpath "$BIN")"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
failures=0

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$(printf '%s' "$2" | head -c 600)"; failures=$((failures + 1)); }
# check LABEL FILE REGEX: the file holds a line matching the extended regex.
check() { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "$(cat "$2" 2>/dev/null)"; fi; }
# count FILE REGEX: how many lines match.
count() { grep -cE -- "$2" "$1" 2>/dev/null || true; }

# A fresh config folder: new_fixture NAME [config-json] [secrets-json]; workspaces are added
# with add_workspace FIXTURE NAME JSON.
new_fixture() {
  local fx="$OUT/$1-config"
  rm -rf "$fx"
  mkdir -p "$fx/termsie/workspaces"
  printf '%s' "${2:-{\}}" > "$fx/termsie/config.json"
  printf '%s' "${3:-{\}}" > "$fx/secrets.json"
  printf '%s' "$fx"
}
add_workspace() { printf '%s' "$3" > "$1/termsie/workspaces/$2.json"; }

# Runs the app against a fixture: run_termsie NAME FIXTURE ACTIONS [extra args...]. The log is
# at $OUT/NAME.log.
run_termsie() {
  local name=$1 fx=$2 actions=$3
  shift 3
  local log="$OUT/$name.log"
  rm -f "$log"
  XDG_CONFIG_HOME="$fx" XDG_STATE_HOME="$OUT/state" TERMSIE_SECRETS_FILE="$fx/secrets.json" \
    timeout 120 "$BIN" --actions "$actions" --snapshot "$OUT/$name.png" --log "$log" --quit "$@"
  local status=$?
  if [ $status -eq 124 ]; then bad "$name finished within 120 s"; fi
  [ -f "$log" ] || : > "$log"
}

# The shell takes a moment to draw its first prompt.
settle="sleep:3"

echo
echo "== a shell runs in a pseudo-terminal and its output is drawn"
fx=$(new_fixture basic)
run_termsie basic "$fx" "$settle,type:echo termsie-ok\\n,sleep:2,dumpScreen,dumpState,dumpProcess"
check "snapshot written" "$OUT/basic.log" "snapshot=ok"
[ -f "$OUT/basic.png" ] && ok "PNG exists" || bad "PNG exists"
check "the shell's output reached the screen" "$OUT/basic.log" "^termsie-ok\\s*$"
check "the default shell is the account's" "$OUT/basic.log" "shell=/.*(bash|zsh|fish)"
check "the shell is running" "$OUT/basic.log" "process pid=[0-9]+ running=true"

echo
echo "== terminals open, close into the list, and reopen"
fx=$(new_fixture lifecycle)
run_termsie lifecycle "$fx" "$settle,newTerminal,newTerminal,sleep:3,dumpTerminals,closeTerminal:2,dumpTerminals,openTerminal:2,sleep:2,dumpTerminals,tileGrid,dumpTerminals"
check "three terminals were open" "$OUT/lifecycle.log" "terminal 3 id=\\S+ open=true"
check "a closed terminal stays in the list" "$OUT/lifecycle.log" "terminal 2 id=\\S+ open=false"
[ "$(count "$OUT/lifecycle.log" 'terminal 2 id=\S+ open=true')" -ge 2 ] && ok "reopening brings it back" || bad "reopening brings it back" "$(cat "$OUT/lifecycle.log")"

echo
echo "== a workspace's startup commands run from the shell shim, and the folder is read back"
fx=$(new_fixture startup)
add_workspace "$fx" startup '{ "version": 2, "name": "startup", "layout": { "terminals": [
  { "id": "t-startup-1", "name": "first", "startupCommands": ["echo start\"\"up-ran"], "frame": [0, 0, 0.5, 1] },
  { "id": "t-startup-2", "name": "second", "startupCommands": ["cd /tmp"], "frame": [0.5, 0, 0.5, 1] } ] } }'
run_termsie startup "$fx" "openWorkspace:startup,sleep:8,dumpText:1,dumpTerminals"
check "the startup command ran" "$OUT/startup.log" "^startup-ran\\s*$"
check "the shell's folder is shown" "$OUT/startup.log" "name=second .*cwd=/tmp"

echo
echo "== environment variables and secrets reach the shell, secrets never the files"
fx=$(new_fixture envs '{}' '{ "s-test-ref": "hunter2" }')
add_workspace "$fx" envs '{ "version": 2, "name": "envs", "layout": {
  "settings": { "env": [ { "name": "WS_VAR", "value": "from-ws" } ] },
  "terminals": [ { "id": "t-env-1", "env": [ { "name": "PLAIN", "value": "p1" }, { "name": "TOKEN", "secret": true, "secretRef": "s-test-ref" } ] } ] } }'
run_termsie envs "$fx" "openWorkspace:envs,sleep:6,type:echo \$WS_VAR/\$PLAIN/\$TOKEN\\n,sleep:2,dumpScreen,saveWorkspaceNamed:envs-saved"
check "plain, workspace and secret variables are set" "$OUT/envs.log" "^from-ws/p1/hunter2\\s*$"
saved="$fx/termsie/workspaces/envs-saved.json"
if [ -f "$saved" ] && ! grep -q hunter2 "$saved" && grep -q s-test-ref "$saved"; then ok "the saved workspace holds the reference, not the value"; else bad "the saved workspace holds the reference, not the value" "$(cat "$saved" 2>/dev/null)"; fi

echo
echo "== copy tools: last command, its output, everything"
fx=$(new_fixture copy)
run_termsie copy "$fx" "$settle,type:echo copy-me\\n,sleep:2,dumpCopyState,copy:lastCommandOutput,dumpClipboard,copy:lastCommand,dumpClipboard,copy:wholeTerminal,dumpClipboard"
check "the shell marks its prompts (OSC 133)" "$OUT/copy.log" "copyState marks=true"
check "last command output includes the output" "$OUT/copy.log" "clipboard=.*copy-me.*copy-me"
check "last command is just the command" "$OUT/copy.log" "^clipboard=echo copy-me\\s*$"

echo
echo "== kept output survives quitting, and the session comes back"
fx=$(new_fixture kept)
run_termsie kept-1 "$fx" "$settle,type:echo kept-marker\\n,sleep:2,rename:keeper" --use-session
run_termsie kept-2 "$fx" "sleep:5,dumpTerminals,dumpScreen" --use-session
check "the session restored the terminal" "$OUT/kept-2.log" "name=keeper"
check "its output was kept" "$OUT/kept-2.log" "kept-marker"
check "with a rule saying when it was from" "$OUT/kept-2.log" "restored from"

echo
echo "== each terminal keeps its own shell history"
fx=$(new_fixture history)
run_termsie history "$fx" "$settle,type:echo history-probe\\n,sleep:2,dumpTerminals"
id=$(grep -oE 'terminal 1 id=\S+' "$OUT/history.log" | head -1 | sed 's/.*id=//')
sleep 2
hist=$(ls "$fx/termsie/panes/$id"/.*history* 2>/dev/null | head -1)
if [ -n "$hist" ] && grep -q history-probe "$hist"; then ok "the command went to this terminal's history file"; else bad "the command went to this terminal's history file" "$(ls -la "$fx/termsie/panes/$id" 2>&1)"; fi

echo
echo "== a shell without integration gets its startup commands typed in"
fx=$(new_fixture plain '{ "shell": "/bin/sh" }')
add_workspace "$fx" plain '{ "version": 2, "name": "plain", "layout": { "terminals": [ { "id": "t-sh-1", "startupCommands": ["echo typed-ok"] } ] } }'
run_termsie plain "$fx" "openWorkspace:plain,sleep:8,dumpText:1"
check "sh ran the command" "$OUT/plain.log" "^typed-ok\\s*$"

echo
echo "== the workspace JSON view applies and refuses"
good="$OUT/workspace-good.json"
cat > "$good" <<'EOF'
{ "workspace": { "fontSize": 15, "env": { "A": "1" } },
  "terminals": [ { "name": "alpha" }, { "name": "beta", "startupCommands": ["echo hi"] } ] }
EOF
bad_json="$OUT/workspace-bad.json"
echo '{ "terminals": [ { "startupCommand": "x" } ] }' > "$bad_json"
fx=$(new_fixture json)
run_termsie json "$fx" "$settle,applyWorkspaceJSON:$bad_json,applyWorkspaceJSON:$good,sleep:2,dumpTerminals,dumpFonts"
check "a misspelt key is refused with its name" "$OUT/json.log" "refused: .*startupCommand"
check "a valid document is applied" "$OUT/json.log" "applyJSON applied"
if grep -q "name=alpha" "$OUT/json.log" && grep -q "name=beta" "$OUT/json.log"; then ok "the terminals it lists exist"; else bad "the terminals it lists exist" "$(cat "$OUT/json.log")"; fi
check "the workspace font size applies" "$OUT/json.log" "size=15"

echo
echo "== the list gives way as it narrows"
fx=$(new_fixture sidebar)
run_termsie sidebar "$fx" "$settle,setSidebarWidth:264,dumpRow:1,setSidebarWidth:150,dumpRow:1,setSidebarWidth:60,dumpRow:1"
check "full width shows a thumbnail" "$OUT/sidebar.log" "row title=.* thumbnail=104x65"
check "narrower drops the thumbnail" "$OUT/sidebar.log" "thumbnail=none text=true"
check "narrowest leaves only the number" "$OUT/sidebar.log" "thumbnail=none text=false"

echo
echo "== thumbnails cost nothing while a terminal is idle"
fx=$(new_fixture thumbs)
run_termsie thumbs "$fx" "$settle,dumpThumb:1,sleep:4,dumpThumb:1"
counts=($(grep -oE 'thumb renders=[0-9]+' "$OUT/thumbs.log" | sed 's/.*=//'))
if [ "${#counts[@]}" -eq 2 ] && [ $((counts[1] - counts[0])) -le 1 ]; then ok "an idle terminal's thumbnail is not rebuilt"; else bad "an idle terminal's thumbnail is not rebuilt" "${counts[*]}"; fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
