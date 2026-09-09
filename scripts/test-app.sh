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

print "\n== the settings window opens"
fix=$ROOT/settings2; mkdir -p $fix
out=$(run $fix "wait,openSettings,wait,openEnvironmentSettings,wait" --cwd $HOME)
check "app survived opening settings" "$(print -r -- "$out" | grep 'DebugDriver: wrote')"

print "\n== the settings editor opens"
fix=$ROOT/settings; mkdir -p $fix
out=$(run $fix "wait,showTerminalSettings,wait" --cwd $HOME)
check "app survived opening the settings popover" "$(print -r -- "$out" | grep 'DebugDriver: wrote')"

print ""
if (( fail )); then print "APP TESTS FAILED"; exit 1; else print "all app tests passed"; fi
