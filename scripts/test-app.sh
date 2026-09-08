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
out=$(run $fix "newTerminalAction,wait,rename:1xdatabase,wait,dumpNames" --cwd $HOME)
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
out=$(run $fix "wait,setEnv:1xproduction,wait,dumpTerminals" --cwd $HOME)
check "environment saved on the definition"  "$(print -r -- "$out" | grep '"environment":"production"')"

print "\n== the settings editor opens"
fix=$ROOT/settings; mkdir -p $fix
out=$(run $fix "wait,showTerminalSettings,wait" --cwd $HOME)
check "app survived opening the settings popover" "$(print -r -- "$out" | grep 'DebugDriver: wrote')"

print ""
if (( fail )); then print "APP TESTS FAILED"; exit 1; else print "all app tests passed"; fi
