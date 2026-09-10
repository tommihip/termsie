#!/bin/zsh
# End-to-end checks driven through the headless DebugDriver harness.
# Every run uses a fixture XDG_CONFIG_HOME, so the user's real config is never touched.
set -u
BIN=${1:-build/Termsie.app/Contents/MacOS/Termsie}
ROOT=$(mktemp -d); trap "rm -rf $ROOT" EXIT
fail=0
ok()   { print "  ok   $1" }
bad()  { print "  FAIL $1"; fail=1 }
check(){ if [[ -n "$2" ]]; then ok "$1"; else bad "$1"; fi }

run() { # run <fixture> <actions> [extra args...]
  local fix=$1 actions=$2; shift 2
  XDG_CONFIG_HOME=$fix "$BIN" --snapshot $fix/shot.png --actions "$actions" --quit "$@" 2>&1
}

print "== thumbnails are derived from the buffer, not captured from pixels"
# The decisive test: with a pixel-capture implementation the Metal run would be blank, because
# cacheDisplay/CALayer.render cannot read a CAMetalLayer.
for renderer in metal coregraphics; do
  fix=$ROOT/$renderer; mkdir -p $fix/termsie
  print '{"renderer":"'$renderer'","sidebar":{"width":264}}' > $fix/termsie/config.json
  run $fix "type:printf 'AAAAAAAAAAAAAAAAAAAA\\n'\n,wait,wait,wait" --cwd $HOME >/dev/null
  /usr/bin/sips -c 200 264 --cropOffset 0 0 $fix/shot.png --out $fix/side.png >/dev/null 2>&1
done
if [[ -f $ROOT/metal/side.png && -f $ROOT/coregraphics/side.png ]]; then
  if cmp -s $ROOT/metal/side.png $ROOT/coregraphics/side.png; then
    ok "sidebar identical under metal and coregraphics"
  else
    # Compare byte size as a weaker signal; exact equality can differ by cursor blink phase.
    sm=$(stat -f%z $ROOT/metal/side.png); sc=$(stat -f%z $ROOT/coregraphics/side.png)
    d=$(( sm > sc ? sm - sc : sc - sm ))
    if (( d * 20 < sm )); then ok "sidebar near-identical under both renderers (${sm}B vs ${sc}B)"
    else bad "sidebar differs between renderers (${sm}B vs ${sc}B) — thumbnail may be pixel-captured"; fi
  fi
else bad "could not crop sidebar region"; fi

print "\n== thumbnail overhead is bounded"
fix=$ROOT/budget; mkdir -p $fix
out=$(run $fix "type:yes\n,wait,wait,wait,wait,wait,dumpThumb:1" --cwd $HOME)
n=$(print -r -- "$out" | grep -o 'renders=[0-9]*' | tail -1 | cut -d= -f2)
if [[ -n "$n" ]] && (( n <= 14 )); then ok "under a firehose: $n renders"; else bad "under a firehose: $n renders (expected <= 14)"; fi

fix=$ROOT/idle; mkdir -p $fix
out=$(run $fix "wait,wait,wait,wait,wait,wait,dumpThumb:1" --cwd $HOME)
n=$(print -r -- "$out" | grep -o 'renders=[0-9]*' | tail -1 | cut -d= -f2)
if [[ -n "$n" ]] && (( n <= 3 )); then ok "idle window: $n renders"; else bad "idle window: $n renders (expected <= 3)"; fi

print "\n== closing the last terminal keeps the window"
fix=$ROOT/lastclose; mkdir -p $fix
out=$(run $fix "closeTerminal:1,wait,dumpTerminals" --cwd $HOME)
check "window still open with a closed terminal" "$(print -r -- "$out" | grep 'defs=1 open=0')"
check "definition survived the close"            "$(print -r -- "$out" | grep 'DebugDriver state:.*=closed')"

print "\n== close and reopen keeps the same identity"
fix=$ROOT/reopen; mkdir -p $fix
out=$(run $fix "dumpTerminals,closeTerminal:1,wait,openTerminal:1,wait,dumpTerminals" --cwd $HOME)
ids=$(print -r -- "$out" | grep -o '"id":"[^"]*"' | sort -u | wc -l | tr -d ' ')
check "id is stable across close and reopen (unique ids: $ids)" "$([[ $ids == 1 ]] && echo yes)"

print "\n== a v1 split-tree session still opens"
fix=$ROOT/legacy; mkdir -p $fix/termsie
cat > $fix/termsie/session.json <<'JSON'
{"windows":[{"frame":[100,100,1200,800],"selectedTab":0,"tabs":[
 {"type":"split","orientation":"horizontal","sizes":[0.6,0.4],"children":[
   {"type":"pane","title":"api","cwd":"~","command":"echo api"},
   {"type":"split","orientation":"vertical","sizes":[0.5,0.5],"children":[
     {"type":"pane","title":"web","cwd":"~"},
     {"type":"pane","title":"db","cwd":"~"}]}]}]}]}
JSON
out=$(XDG_CONFIG_HOME=$fix "$BIN" --snapshot $fix/shot.png --actions "wait,dumpTerminals,frames" --quit 2>&1)
check "three terminals migrated"      "$(print -r -- "$out" | grep 'defs=3')"
check "names carried over"            "$(print -r -- "$out" | grep '"name":"api"')"
check "left pane keeps its 60% width" "$(print -r -- "$out" | grep '"frame":\[0,0,0.6,1\]')"
check "web occupies the top right"    "$(print -r -- "$out" | grep '"frame":\[0.6,0,0.4,0.5\]')"

print "\n== workspace startup commands run in order, without polluting history"
fix=$ROOT/ws; mkdir -p $fix/termsie/workspaces
cat > $fix/termsie/workspaces/dev.json <<JSON
{"version":2,"name":"dev","layout":{"version":2,"terminals":[
 {"id":"t-fixture-one","name":"api","cwd":"$HOME",
  "startupCommands":["export TERMSIE_TEST_A=1","echo first >> $fix/order","echo second >> $fix/order"],
  "frame":[0,0,1,1]}]}}
JSON
XDG_CONFIG_HOME=$fix "$BIN" --workspace dev --snapshot $fix/shot.png \
  --actions "wait,wait,wait,wait,type:echo typed-by-user\n,wait,wait" --quit >/dev/null 2>&1
if [[ -f $fix/order ]] && [[ "$(cat $fix/order)" == "first
second" ]]; then ok "commands ran in order"; else bad "commands did not run in order: $(cat $fix/order 2>/dev/null)"; fi
hist=$(find $fix/termsie/panes -name '.zsh_history' 2>/dev/null | head -1)
if [[ -n "$hist" ]]; then
  if grep -q 'typed-by-user' $hist; then ok "the user's own command is in history"; else bad "user command missing from history"; fi
  if grep -q 'echo first' $hist; then bad "startup command leaked into history"; else ok "startup commands stay out of history"; fi
else bad "no per-terminal history file was created"; fi

print "\n== dragging: free movement, and snapping to a neighbour"
fix=$ROOT/drag; mkdir -p $fix
# move: and resize: drive the same geometry path a real mouse drag uses.
out=$(run $fix "newTerminalAction,wait,tileGrid,wait,frames,move:-5x0,frames,move:-120x40,frames,resize:60x0,frames" --cwd $HOME)
frames=(${(f)"$(print -r -- "$out" | grep 'frame: #2' | grep -o 'frame={{[0-9-]*, [0-9-]*}, {[0-9-]*, [0-9-]*}}')"})
if [[ "${frames[1]}" == "${frames[2]}" ]]; then ok "a small nudge snaps back to the neighbour's edge"
else bad "small nudge did not snap (${frames[1]} -> ${frames[2]})"; fi
if [[ "${frames[2]}" != "${frames[3]}" ]]; then ok "a large drag moves freely"
else bad "large drag did not move"; fi
if [[ "${frames[3]}" != "${frames[4]}" ]]; then ok "resizing changes the size"
else bad "resize had no effect"; fi

print "\n== translucency and blur are actually configured"
fix=$ROOT/glass; mkdir -p $fix
out=$(run $fix "wait" --cwd $HOME)
check "window is non-opaque"                 "$(print -r -- "$out" | grep 'opaque=false')"
check "both blur layers are live"            "$(print -r -- "$out" | grep 'blur=2')"
check "terminal background is translucent"   "$(print -r -- "$out" | grep -E 'termAlpha=0\.[0-9]+')"
fix=$ROOT/noglass; mkdir -p $fix/termsie
print '{"blurBackground":false,"opacity":1.0,"activeOpacityBoost":0}' > $fix/termsie/config.json
out=$(XDG_CONFIG_HOME=$fix "$BIN" --snapshot $fix/shot.png --actions "wait" --quit --cwd $HOME 2>&1)
check "translucency can be turned off"       "$(print -r -- "$out" | grep 'opaque=true')"
check "opaque config disables the blur"      "$(print -r -- "$out" | grep 'blur=0')"

print "\n== one name, shown in both the header and the list"
fix=$ROOT/names; mkdir -p $fix
out=$(run $fix "newTerminalAction,wait,rename:1|database,wait,dumpNames" --cwd $HOME)
line=$(print -r -- "$out" | grep 'DebugDriver name' | head -1)
check "renaming reaches the header"          "$(print -r -- "$line" | grep 'header=\[database\]')"
check "renaming reaches the list row"        "$(print -r -- "$line" | grep 'row=\[database\]')"
mismatch=$(print -r -- "$out" | grep 'DebugDriver name' | sed -E 's/.*header=\[(.*)\] row=\[(.*)\]/\1|\2/' | awk -F'|' '$1 != $2' | head -1)
if [[ -z "$mismatch" ]]; then ok "every terminal's two names agree"; else bad "names differ: $mismatch"; fi

print "\n== the resize readout does not linger"
fix=$ROOT/readout; mkdir -p $fix
out=$(run $fix "wait,resize:70x50,readout" --cwd $HOME)
check "readout cleared after the gesture"    "$(print -r -- "$out" | grep 'readout: cleared')"

print "\n== collapse rolls a terminal up without losing its size"
fix=$ROOT/collapse; mkdir -p $fix
out=$(run $fix "wait,frames,toggleCollapse,wait,frames,toggleCollapse,wait,frames" --cwd $HOME)
heights=(${(f)"$(print -r -- "$out" | grep 'frame: #1' | grep -o 'frame={{[0-9-]*, [0-9-]*}, {[0-9-]*, [0-9-]*}}' | sed -E 's/.*, ([0-9-]+)\}\}/\1/')"})
if [[ -n "${heights[2]}" ]] && (( heights[2] <= 40 )); then ok "collapsed to its header (${heights[2]}pt)"
else bad "collapse did not shrink the terminal (${heights[2]:-none})"; fi
if [[ "${heights[1]}" == "${heights[3]}" ]]; then ok "expanding restores the exact height"
else bad "height changed across collapse (${heights[1]} -> ${heights[3]})"; fi

print "\n== environments tint a terminal and persist"
fix=$ROOT/envs; mkdir -p $fix
out=$(run $fix "wait,setEnv:1|production,wait,dumpTerminals" --cwd $HOME)
check "environment saved on the definition"  "$(print -r -- "$out" | grep '"environment":"production"')"

print "\n== fonts: a global setting each terminal may override"
fix=$ROOT/fonts; mkdir -p $fix
out=$(run $fix "newTerminalAction,wait,setFont:1|Monaco|18,wait,setGlobalFont:Andale Mono|15,wait,dumpFonts" --cwd $HOME)
check "global font applied to the plain terminal"   "$(print -r -- "$out" | grep 'actual=\[Andale Mono 15\]')"
check "overridden terminal keeps its own font"      "$(print -r -- "$out" | grep 'override=\[Monaco 18\] actual=\[Monaco 18\]')"
out=$(run $fix "wait,increaseFontSize,increaseFontSize,wait,dumpFonts" --cwd $HOME)
check "text size writes a size-only override"       "$(print -r -- "$out" | grep -E 'override=\[- 1[0-9]\]')"
out=$(run $fix "wait,setFont:1|Monaco|18,wait,resetFontSize,wait,dumpFonts" --cwd $HOME)
check "reset returns a terminal to the global font" "$(print -r -- "$out" | grep 'override=\[- -\]')"

print "\n== environments can be added, edited and removed"
fix=$ROOT/envmgr; mkdir -p $fix
out=$(run $fix "wait,addEnvironment:QA Sandbox|#98c379|0.3,wait,removeEnvironment:development,wait,dumpEnvironments,setEnv:1|qa-sandbox,wait,dumpTerminals" --cwd $HOME)
check "a custom environment is added"      "$(print -r -- "$out" | grep '\"id\":\"qa-sandbox\"')"
check "its tint and strength are kept"     "$(print -r -- "$out" | grep '\"strength\":0.3')"
check "a built-in one can be removed"      "$([[ -z "$(print -r -- "$out" | grep 'DebugDriver environments' | grep '\"id\":\"development\"')" ]] && echo yes)"
check "a terminal can use the custom one"  "$(print -r -- "$out" | grep '\"environment\":\"qa-sandbox\"')"
if [[ -f $fix/termsie/config.json ]] && grep -q 'qa-sandbox' $fix/termsie/config.json; then
  ok "the change is written to config.json"
else bad "config.json was not updated"; fi

print "\n== the window resize mode is a real choice"
fix=$ROOT/resizeon; mkdir -p $fix
out=$(run $fix "newTerminalAction,wait,tileGrid,frames,resizeWindow:900x600,wait,frames" --cwd $HOME)
sizes=(${(f)"$(print -r -- "$out" | grep 'frame: #2' | sed -E 's/.*frame=\{\{[0-9-]+, [0-9-]+\}, \{([0-9]+), ([0-9]+)\}\}.*/\1x\2/')"})
if [[ -n "${sizes[1]:-}" && -n "${sizes[2]:-}" && "${sizes[1]}" != "${sizes[2]}" ]]; then
  ok "scaling mode resizes terminals with the window (${sizes[1]} -> ${sizes[2]})"
else bad "terminals did not scale (${sizes[1]:-none} -> ${sizes[2]:-none})"; fi
fix=$ROOT/resizeoff; mkdir -p $fix/termsie
print '{"resizeTerminalsWithWindow":false}' > $fix/termsie/config.json
out=$(XDG_CONFIG_HOME=$fix "$BIN" --snapshot $fix/shot.png --cwd $HOME --quit       --actions "newTerminalAction,wait,tileGrid,frames,resizeWindow:900x600,wait,frames" 2>&1)
sizes=(${(f)"$(print -r -- "$out" | grep 'frame: #2' | sed -E 's/.*frame=\{\{[0-9-]+, [0-9-]+\}, \{([0-9]+), ([0-9]+)\}\}.*/\1x\2/')"})
if [[ -n "${sizes[1]:-}" && "${sizes[1]}" == "${sizes[2]:-}" ]]; then
  ok "hold-still mode leaves terminals untouched (${sizes[1]})"
else bad "terminals moved in hold-still mode (${sizes[1]:-none} -> ${sizes[2]:-none})"; fi

print "\n== resizing the window is not mistaken for terminal activity"
# Paired with a control, so this cannot pass vacuously: the badge must still appear for real output.
fix=$ROOT/badgectl; mkdir -p $fix
out=$(run $fix "newTerminalAction,wait,type:sleep 4; echo LATE
,wait,pane:1,wait,wait,wait,wait,wait,wait,dumpBadges" --cwd $HOME)
check "genuine output still raises the badge" "$(print -r -- "$out" | grep '#2 active=false badge=activity')"
fix=$ROOT/badgeresize; mkdir -p $fix
out=$(run $fix "newTerminalAction,wait,tileGrid,wait,wait,pane:1,wait,resizeWindow:900x600,wait,resizeWindow:1200x780,wait,wait,dumpBadges" --cwd $HOME)
check "resizing leaves inactive terminals clean" "$(print -r -- "$out" | grep '#2 active=false badge=none')"

print "\n== workspaces can be created, saved and reopened"
fix=$ROOT/ws; mkdir -p $fix
out=$(run $fix "wait,dumpWorkspace,newTerminalAction,wait,dumpWorkspace,saveWorkspaceNamed:alpha,wait,dumpWorkspace,newTerminalAction,wait,dumpWorkspace,newWorkspaceDiscarding,wait,dumpWorkspace,dumpTerminals" --cwd $HOME)
states=(${(f)"$(print -r -- "$out" | sed -nE 's/.*(name=\[[^]]*\] modified=[a-z]*).*/\1/p')"})
check "a fresh window starts unmodified"   "$([[ "${states[1]}" == "name=[-] modified=false" ]] && echo yes)"
check "adding a terminal marks it edited"  "$([[ "${states[2]}" == "name=[-] modified=true" ]] && echo yes)"
check "saving names it and clears edited"  "$([[ "${states[3]}" == "name=[alpha] modified=false" ]] && echo yes)"
check "further edits mark it again"        "$([[ "${states[4]}" == "name=[alpha] modified=true" ]] && echo yes)"
check "a new workspace is empty and clean" "$([[ "${states[5]}" == "name=[-] modified=false" ]] && echo yes)"
n=$(print -r -- "$out" | grep 'DebugDriver state:' | tail -1 | grep -o '=open' | wc -l | tr -d ' ')
check "and holds exactly one terminal"     "$([[ "$n" == "1" ]] && echo yes)"
out=$(XDG_CONFIG_HOME=$fix "$BIN" --workspace alpha --snapshot $fix/s2.png --actions "wait,wait,dumpWorkspace" --quit 2>&1)
check "reopening restores the name"        "$(print -r -- "$out" | grep 'name=\[alpha\] modified=false')"
# Clicking around must not count as an edit, or every workspace would always look dirty.
out=$(XDG_CONFIG_HOME=$fix "$BIN" --workspace alpha --snapshot $fix/s3.png --actions "wait,wait,pane:2,wait,pane:1,wait,dumpWorkspace" --quit 2>&1)
check "focusing terminals is not an edit"  "$(print -r -- "$out" | grep 'name=\[alpha\] modified=false')"

print "\n== the General settings tab drives the real config"
fix=$ROOT/general; mkdir -p $fix
out=$(run $fix "wait,openSettings,wait,readSetting:Resize terminals,clickSetting:Resize terminals,wait,readSetting:Resize terminals" --cwd $HOME)
check "the checkbox is found and bound"    "$(print -r -- "$out" | grep 'clickSetting: \[Resize terminals\] found=true')"
check "it starts showing the config value" "$(print -r -- "$out" | grep 'readSetting: \[Resize terminals\] shown=true')"
check "clicking it flips what is shown"    "$(print -r -- "$out" | grep 'readSetting: \[Resize terminals\] shown=false')"
if [[ -f $fix/termsie/config.json ]]; then
  wrote=$(python3 -c "import json;c=json.load(open('$fix/termsie/config.json'));print(c.get('resizeTerminalsWithWindow'), c.get('snapToCells'))")
  # The neighbouring key must be untouched, which is what catches a checkbox bound to the wrong one.
  if [[ "$wrote" == "False True" ]]; then ok "it writes that key and only that key"
  else bad "wrong keys written: $wrote"; fi
else bad "config.json was not written"; fi

# The whole chain: flipping the switch in Settings changes what a window resize does.
# A fresh fixture, because the check above already persisted a flipped value into $fix.
fix=$ROOT/general2; mkdir -p $fix
out=$(run $fix "newTerminalAction,wait,tileGrid,frames,openSettings,wait,clickSetting:Resize terminals,wait,resizeWindow:700x500,wait,frames" --cwd $HOME)
sizes=(${(f)"$(print -r -- "$out" | grep 'frame: #2' | sed -E 's/.*frame=\{\{[0-9-]+, [0-9-]+\}, \{([0-9]+), ([0-9]+)\}\}.*/\1x\2/')"})
if [[ -n "${sizes[1]:-}" && "${sizes[1]}" == "${sizes[2]:-}" ]]; then
  ok "toggling it takes effect immediately (${sizes[1]})"
else bad "toggle had no effect (${sizes[1]:-none} -> ${sizes[2]:-none})"; fi

print "\n== the terminal in front owns the pointer where terminals overlap"
# The front terminal's header is placed over the back terminal's text area *and* over its bottom
# resize edge — the two places the pointer used to fall through to the terminal behind.
fix=$ROOT/cursor; mkdir -p $fix/termsie/workspaces
python3 - <<'JSON' > $fix/termsie/workspaces/overlap.json
import json
print(json.dumps({"version":2,"name":"overlap","layout":{"version":2,"terminals":[
 {"id":"t-back","name":"back","frame":[0.05,0.05,0.7,0.6],"z":0},
 {"id":"t-front","name":"front","frame":[0.25,0.6125,0.6,0.35],"z":1}]}}))
JSON
probe="cursorAt:665x505,cursorAt:665x518,cursorAt:665x560,cursorAt:520x560,cursorAt:665x200,cursorAt:415x518,cursorAt:270x100,cursorAt:264x400"
out=$(XDG_CONFIG_HOME=$fix "$BIN" --workspace overlap --snapshot $fix/shot.png --quit \
      --actions "wait,wait,pane:2,wait,frames,$probe" 2>&1)
# Confirm the fixture really is the overlapping arrangement before trusting the probes.
check "the front terminal sits where expected" "$(print -r -- "$out" | grep 'frame: #2' | grep 'frame={{253, 490}, {610, 280}}')"
cursor_at() { print -r -- "$out" | sed -nE "s/.*cursor: at=$1 shape=([a-zA-Z]+) terminal=([0-9]+).*/\1 \2/p" }
check "header over the terminal behind is not a text cursor" "$([[ "$(cursor_at '665,505')" == "arrow 2" ]] && echo yes)"
check "header over the other's resize edge is not a resize cursor" "$([[ "$(cursor_at '665,518')" == "arrow 2" ]] && echo yes)"
check "the front terminal's own text is a text cursor"       "$([[ "$(cursor_at '665,560')" == "iBeam 2" ]] && echo yes)"
check "the front terminal's own edge resizes"                "$([[ "$(cursor_at '520,560')" == "resizeLeftRight 2" ]] && echo yes)"
check "the terminal behind still owns what it shows"         "$([[ "$(cursor_at '665,200')" == "iBeam 1" ]] && echo yes)"
check "its uncovered edge still resizes"                     "$([[ "$(cursor_at '415,518')" == "resizeUpDown 1" ]] && echo yes)"
check "bare canvas is a plain arrow"                         "$([[ "$(cursor_at '270,100')" == "arrow 0" ]] && echo yes)"
check "the sidebar divider still resizes"                    "$([[ "$(cursor_at '264,400')" == "resizeLeftRight 0" ]] && echo yes)"

print "\n== the sidebar survives heavy redrawing"
# Guards a crash that took ~15% of runs: NSFont.monospacedSystemFont is declared non-null but
# intermittently returned nil, and Swift carried that nil into CoreText, which aborted the process
# while measuring a sidebar label. Fonts are resolved once through UIFonts now.
if grep -rn 'NSFont\.systemFont\|NSFont\.monospacedSystemFont\|NSFont\.monospacedDigitSystemFont' \
     ../Sources/Termsie 2>/dev/null | grep -v 'UIFonts.swift' | grep -v 'FontCatalog.swift' > /dev/null 2>&1 ||
   grep -rn 'NSFont\.systemFont\|NSFont\.monospacedSystemFont\|NSFont\.monospacedDigitSystemFont' \
     Sources/Termsie 2>/dev/null | grep -v 'UIFonts.swift' | grep -v 'FontCatalog.swift' > /dev/null 2>&1; then
  bad "drawing code calls a system-font factory directly instead of going through UIFonts"
else
  ok "drawing code resolves fonts through UIFonts"
fi

fix=$ROOT/redraw; mkdir -p $fix/termsie/workspaces
python3 - <<'JSON' > $fix/termsie/workspaces/redraw.json
import json, os
proj = os.path.expanduser('~')
terms = [{"id": f"t-redraw-{i}", "name": f"terminal-with-a-fairly-long-name-{i}", "cwd": proj,
          "environment": ["production","staging","development",None][i % 4],
          "frame": [0.02 + (i % 4) * 0.2, 0.02 + (i // 4) * 0.3, 0.24, 0.28],
          "z": i, "openOnRestore": i % 3 != 2}
         for i in range(12)]
print(json.dumps({"version":2,"name":"redraw","layout":{"version":2,"terminals":terms}}))
JSON
churn="wait,wait,resizeWindow:700x500,wait,resizeWindow:1400x900,wait,pane:3,pane:7,pane:11,wait,closeTerminal:4,wait,openTerminal:4,wait,tileGrid,wait,cascade,wait"
redraw_crashes=0
for i in 1 2 3 4 5 6; do
  XDG_CONFIG_HOME=$fix "$BIN" --workspace redraw --snapshot $fix/shot.png --actions "$churn" --quit > $fix/run.log 2>&1 || redraw_crashes=$((redraw_crashes+1))
done
if (( redraw_crashes == 0 )); then ok "12 terminals, repeated resize and relayout: no crash in 6 runs"
else bad "$redraw_crashes of 6 redraw runs crashed"; fi

print "\n== the settings window opens"
fix=$ROOT/settings2; mkdir -p $fix
out=$(run $fix "wait,openSettings,wait,openEnvironmentSettings,wait" --cwd $HOME)
check "app survived opening settings" "$(print -r -- "$out" | grep 'DebugDriver: wrote')"

print "\n== the settings editor opens"
fix=$ROOT/settings; mkdir -p $fix
out=$(run $fix "wait,showTerminalSettings,wait" --cwd $HOME)
check "app survived opening the settings popover" "$(print -r -- "$out" | grep 'DebugDriver: wrote')"

print "\n== the copy tools read whole commands out of the buffer"
clip() { print -r -- "$1" | grep 'DebugDriver clipboard:' | sed -n "${2:-1}p" }

fix=$ROOT/copy-zsh; mkdir -p $fix/termsie
print '{}' > $fix/termsie/config.json
out=$(run $fix "wait,type:echo copied-by-termsie\n,wait,wait,dumpCopyState,copy:lastCommandOutput,dumpClipboard,copy:lastCommand,dumpClipboard" --cwd $HOME)
check "zsh reports its prompts and commands"   "$(print -r -- "$out" | grep 'copyState:.*marks=true')"
check "the command's prompt and output copied" "$(clip "$out" 1 | grep 'echo copied-by-termsie.*copied-by-termsie')"
check "the command alone copied"               "$(clip "$out" 2 | grep -F '[echo copied-by-termsie]')"

print "\n== a command that is still running is the one that gets copied"
fix=$ROOT/copy-running; mkdir -p $fix
out=$(run $fix "wait,type:echo done-already\n,wait,type:echo now-running; sleep 8\n,wait,wait,dumpCopyState,copy:lastCommandOutput,dumpClipboard" --cwd $HOME)
check "the shell says a command is running" "$(print -r -- "$out" | grep 'copyState:.*lifecycle=running')"
check "the running command is copied, not the finished one" \
      "$(clip "$out" 1 | grep 'now-running' )"

print "\n== copying everything stops at the last clear"
fix=$ROOT/copy-clear; mkdir -p $fix
out=$(run $fix "wait,type:echo BEFORETHECLEAR\n,wait,type:clear\n,wait,type:echo AFTERTHECLEAR\n,wait,wait,copy:wholeTerminal,dumpClipboard" --cwd $HOME)
check "content after the clear is copied"    "$(clip "$out" 1 | grep 'AFTERTHECLEAR')"
check "content before the clear is left out" "$(clip "$out" 1 | grep -v 'BEFORETHECLEAR')"

fix=$ROOT/copy-ctrl-l; mkdir -p $fix
ctrl_l=$(printf '\014')
out=$(run $fix "wait,type:echo BEFORECTRLL\n,wait,wait,type:${ctrl_l},wait,wait,type:echo AFTERCTRLL\n,wait,wait,copy:wholeTerminal,dumpClipboard" --cwd $HOME)
# Ctrl-L keeps the scrollback, unlike `clear`, so this is the case that needs the floor.
check "Ctrl-L also starts a fresh copy"       "$(clip "$out" 1 | grep 'AFTERCTRLL')"
check "what Ctrl-L scrolled away is left out" "$(clip "$out" 1 | grep -v 'BEFORECTRLL')"

print "\n== the copy tools still work in a shell that marks nothing"
fix=$ROOT/copy-bare; mkdir -p $fix/termsie
print '{"shellIntegration":"off"}' > $fix/termsie/config.json
out=$(run $fix "wait,type:echo unmarked-shell\n,wait,wait,dumpCopyState,copy:lastCommandOutput,dumpClipboard,copy:lastCommand,dumpClipboard" --cwd $HOME)
check "no marks are claimed"                "$(print -r -- "$out" | grep 'copyState:.*marks=false')"
check "the typed line still anchors a copy" "$(clip "$out" 1 | grep 'echo unmarked-shell.*unmarked-shell')"
check "and the command alone comes out"     "$(clip "$out" 2 | grep -F '[echo unmarked-shell]')"

print "\n== bash marks its prompts, and its prompt stays out of the command"
fix=$ROOT/copy-bash; mkdir -p $fix/termsie
print '{"shell":"/bin/bash","shellArgs":[]}' > $fix/termsie/config.json
out=$(run $fix "wait,type:echo from-bash\n,wait,wait,dumpCopyState,copy:lastCommand,dumpClipboard" --cwd $HOME)
check "bash reports prompts but not commands" "$(print -r -- "$out" | grep 'copyState:.*marks=true lifecycle=atPrompt lifecycleMarks=false')"
check "the bash prompt is not copied with the command" "$(clip "$out" 1 | grep -F '[echo from-bash]')"

print "\n== a selection survives output arriving under it"
# SwiftTerm drops the selection on every feed while mouse reporting is on; without Termsie's
# own anchoring, highlighted text vanishes the moment the next line lands.
fix=$ROOT/selection; mkdir -p $fix/termsie
print '{"scrollback":40}' > $fix/termsie/config.json
out=$(run $fix 'wait,type:for i in $(seq 1 100); do echo filler-$i; done\n,wait,wait,select:10x0x10x11,dumpSelection,type:for i in $(seq 200 240); do echo more-$i; done\n,wait,wait,dumpSelection' --cwd $HOME)
before=$(print -r -- "$out" | grep 'DebugDriver selection:' | sed -n 1p | sed -nE 's/.*text=\[(.*)\].*/\1/p')
after=$(print -r -- "$out" | grep 'DebugDriver selection:' | sed -n 2p | sed -nE 's/.*text=\[(.*)\].*/\1/p')
check "something was selected to begin with" "$([[ -n "$before" ]] && echo yes)"
check "the same text is still selected after 40 more lines scrolled past (was [$before], now [$after])" \
      "$([[ -n "$before" && "$before" == "$after" ]] && echo yes)"

print "\n== a selection trimmed out of the scrollback is dropped, not left pointing elsewhere"
fix=$ROOT/selection-trim; mkdir -p $fix/termsie
print '{"scrollback":2}' > $fix/termsie/config.json
out=$(run $fix 'wait,type:echo PINNEDMARKER\n,wait,wait,select:1x0x1x13,dumpSelection,type:for i in $(seq 1 200); do echo filler-$i; done\n,wait,wait,dumpSelection' --cwd $HOME)
check "the selection is gone once its text is" \
      "$(print -r -- "$out" | grep 'DebugDriver selection:' | sed -n 2p | grep 'active=false')"

print "\n== auto-copy on select is a real setting, wired to the real gesture"
fix=$ROOT/autocopy; mkdir -p $fix
out=$(run $fix "wait,type:echo AUTOCOPYTARGET\n,wait,wait,select:1x0x1x16,autoCopyNow,dumpCopyState,toggleAutoCopyOnSelect,dumpCopyState,autoCopyNow,dumpClipboard" --cwd $HOME)
check "off by default"                 "$(print -r -- "$out" | grep 'copyState:.*autoCopy=false')"
check "the menu item turns it on"      "$(print -r -- "$out" | grep 'copyState:.*autoCopy=true')"
check "nothing is copied while it is off" "$(print -r -- "$out" | grep 'autoCopy: copied=false')"
check "the selection is copied once it is on" "$(clip "$out" 1 | grep 'AUTOCOPYTARGET')"
check "the choice is written to config.json" "$(grep -s 'autoCopyOnSelect' $fix/termsie/config.json | grep true)"

print "\n== padding is a global setting each terminal may override"
fix=$ROOT/padding; mkdir -p $fix
out=$(run $fix "newTerminalAction,wait,setGlobalTextLayout:12|1|200,wait,setTextLayout:1|30|,wait,dumpTextLayout" --cwd $HOME)
check "the global padding reaches an unmodified terminal" \
      "$(print -r -- "$out" | grep 'textLayout:.*override=\[- -\] padding=12.0')"
check "an overriding terminal keeps its own padding" \
      "$(print -r -- "$out" | grep 'textLayout:.*override=\[30 -\] padding=30.0')"
# The point of padding is that the text box actually shrinks by it, on both sides.
widths=(${(f)"$(print -r -- "$out" | grep 'textLayout:' | sed -E 's/.*termWidth=([0-9]+) hostWidth=([0-9]+).*/\1 \2/')"})
narrowed=yes
for pair in $widths; do
  tw=${pair%% *}; hw=${pair##* }
  (( hw - tw >= 24 )) || narrowed=""
done
check "the terminal is inset by the padding on both sides ($widths)" "$narrowed"

print "\n== line wrapping is a global setting each terminal may override"
fix=$ROOT/wrap; mkdir -p $fix
out=$(run $fix "newTerminalAction,wait,setGlobalTextLayout:0|0|150,wait,setTextLayout:1||1,wait,dumpTextLayout" --cwd $HOME)
check "an unwrapped terminal takes the configured column count" \
      "$(print -r -- "$out" | grep 'textLayout:.*override=\[- -\] padding=0.0 wrap=false gridCols=150')"
check "a terminal can opt back into wrapping" \
      "$(print -r -- "$out" | grep 'textLayout:.*override=\[- true\].*wrap=true')"
# A wrapped terminal's grid must still follow its own width, not the unwrapped setting.
check "the wrapped terminal is not given the unwrapped width" \
      "$([[ -z "$(print -r -- "$out" | grep 'override=\[- true\].*gridCols=150')" ]] && echo yes)"
check "the choice is written to config.json" "$(grep -s '"lineWrap"' $fix/termsie/config.json | grep false)"

print "\n== the horizontal scrollbar appears only when text runs past the edge"
fix=$ROOT/hscroll; mkdir -p $fix/termsie
print '{"lineWrap":false,"unwrappedColumns":200}' > $fix/termsie/config.json
out=$(run $fix "newTerminalAction,tileGrid,wait,pane:2,dumpTextLayout,type:echo AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKKLLLLMMMMNNNNOOOOPPPPQQQQRRRRSSSSTTTT\n,wait,dumpTextLayout,scrollTerminal:9999,wait,dumpTextLayout" --cwd $HOME)
check "hidden while only a prompt is on screen" \
      "$(print -r -- "$out" | grep 'DebugDriver textLayout' | sed -n 2p | grep 'hscroll=false')"
check "shown once a long line lands"  "$(print -r -- "$out" | grep 'hscroll=true')"
check "scrolling moves the view"      "$(print -r -- "$out" | grep -E 'hscroll=true offset=[1-9][0-9]*')"
# Scrolling is bounded by the *content*, not by the 200-column grid, so a scroll to the far right
# still leaves the longest line's tail on screen rather than parking on blank columns.
offsets=(${(f)"$(print -r -- "$out" | grep -o 'offset=[0-9]*' | cut -d= -f2)"})
check "the offset stops at the end of the text (${offsets[-1]})" \
      "$([[ -n "${offsets[-1]:-}" ]] && (( offsets[-1] > 0 && offsets[-1] < 900 )) && echo yes)"

print "\n== the copy tools can be hidden without disarming their shortcuts"
fix=$ROOT/copytools; mkdir -p $fix
out=$(run $fix "openSettings,clickSetting:Show the copy tools,wait,type:echo TOOLSHIDDEN\n,wait,toggleAutoCopyOnSelect,dumpCopyState,readSetting:Copy a selection as soon,copy:wholeTerminal,dumpClipboard" --cwd $HOME)
check "the tools are hidden in config.json" "$(grep -s 'showTools' $fix/termsie/config.json | grep false)"
check "the auto-copy shortcut still works"  "$(print -r -- "$out" | grep 'copyState:.*autoCopy=true')"
check "and the general setting shows the same value" \
      "$(print -r -- "$out" | grep 'readSetting: \[Copy a selection as soon\] shown=true')"
check "a copy shortcut still copies"        "$(clip "$out" 1 | grep 'TOOLSHIDDEN')"

print ""
if (( fail )); then print "APP TESTS FAILED"; exit 1; else print "all app tests passed"; fi
