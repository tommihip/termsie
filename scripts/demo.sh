#!/usr/bin/env bash
#
# Records the demo loop used on the website, the README and social posts.
#
#   ./scripts/demo.sh [output-basename]     # default: docs/demo
#
# Builds the app, launches it against a throwaway config and a purpose-built
# workspace, records the window while a scripted sequence runs, then assembles
# a .gif and a .mp4. Your real ~/.config/termsie is never touched.
#
# Needs Screen Recording permission for the built binary: capture goes through
# ScreenCaptureKit, the only thing that can read the Metal-rendered terminals.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/docs/demo}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
swift build -c release >/dev/null
BIN="$(swift build -c release --show-bin-path)/Termsie"

mkdir -p "$WORK/termsie/workspaces"

cat > "$WORK/termsie/config.json" <<'JSON'
{
  "font": { "family": "Menlo", "size": 13 },
  "opacity": 0.9,
  "activeOpacityBoost": 0.07,
  "blurBackground": true,
  "sidebar": { "visible": true, "width": 264 },
  "startupCommands": { "echo": false },
  "environments": [
    { "id": "development", "label": "Development", "tint": "#61afef" },
    { "id": "staging",     "label": "Staging",     "tint": "#e5c07b" },
    { "id": "production",  "label": "Production",  "tint": "#e06c75", "strength": 0.26 }
  ]
}
JSON

# Startup commands print and exit rather than tailing, so every frame after the
# opening beat is stable and the loop has no drifting output in it.
cat > "$WORK/termsie/workspaces/demo.json" <<'JSON'
{
  "version": 2,
  "name": "demo",
  "layout": {
    "version": 2,
    "terminals": [
      { "id": "t-demo-api", "name": "api", "environment": "production", "z": 0,
        "frame": [0.02, 0.05, 0.52, 0.44],
        "startupCommands": [
          "printf '\\033[32m→\\033[0m listening on :8080   \\033[2mconnected to prod-db-01\\033[0m\\n'",
          "printf '\\033[33m[warn]\\033[0m 2 slow queries in the last minute\\n'",
          "printf '\\033[2m14:22:07\\033[0m GET  /v1/accounts      \\033[32m200\\033[0m  12ms\\n'",
          "printf '\\033[2m14:22:07\\033[0m POST /v1/sessions      \\033[32m201\\033[0m  31ms\\n'"
        ] },
      { "id": "t-demo-web", "name": "web", "environment": "development", "z": 1,
        "frame": [0.44, 0.02, 0.52, 0.46],
        "startupCommands": [
          "printf '\\033[36mvite\\033[0m v5.4.2  ready in 412 ms\\n'",
          "printf '  \\033[2mLocal:\\033[0m   http://localhost:5173/\\n'",
          "printf '\\033[2m14:22:09\\033[0m hmr update /src/routes/app.tsx\\n'",
          "printf '\\033[2m14:22:11\\033[0m hmr update /src/lib/query.ts\\n'"
        ] },
      { "id": "t-demo-worker", "name": "worker", "environment": "staging", "z": 2,
        "frame": [0.08, 0.42, 0.5, 0.44],
        "startupCommands": [
          "printf '\\033[35mworker\\033[0m picked up 3 jobs\\n'",
          "printf '  \\033[32m✓\\033[0m send-digest      \\033[2m118ms\\033[0m\\n'",
          "printf '  \\033[32m✓\\033[0m rebuild-index    \\033[2m402ms\\033[0m\\n'",
          "printf '  \\033[33m⟳\\033[0m sync-billing     \\033[2mretry 1/3\\033[0m\\n'"
        ] },
      { "id": "t-demo-db", "name": "db", "environment": "development", "z": 3,
        "frame": [0.46, 0.46, 0.5, 0.46],
        "startupCommands": [
          "printf 'psql (16.2)\\n'",
          "printf '\\033[2mtype \\\\? for help\\033[0m\\n'",
          "printf '\\n\\033[2mstaging=#\\033[0m select count(*) from events;\\n'",
          "printf ' count \\n-------\\n 48213\\n(1 row)\\n'"
        ] }
    ]
  }
}
JSON

# The sequence is built to loop: hold the overlapping composition long enough to
# read as the problem, drag one terminal, then tile everything into a grid and
# hold on that. Cutting back to the overlap is the loop's own punchline.
#
# An earlier version ended on maximise/restore. It was dropped: the zoom
# transition captures mid-flight and the half-faded panes read as a rendering
# glitch rather than an animation.
ACTIONS='wait,wait,wait,wait'
ACTIONS+=',move:130x-60,wait,wait'
ACTIONS+=',tileGrid,wait,wait,wait,wait'

echo "==> recording"
XDG_CONFIG_HOME="$WORK" "$BIN" \
  --workspace demo \
  --record "$WORK/frames" \
  --actions "$ACTIONS" \
  --fps 14 --record-width 1000 --step 0.8 --tail 1.4 --quit --cwd "$HOME" 2>&1 | grep -E "DebugDriver: (recorded|frame)" || true

echo "==> assembling"
mkdir -p "$(dirname "$OUT")"
swift "$ROOT/scripts/make-demo.swift" "$WORK/frames" "$OUT" 1000
