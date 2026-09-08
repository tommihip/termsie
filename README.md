# Termsie

A native macOS terminal for running several things at once. One window holds many terminals that
float freely inside it, with a panel down the left listing every terminal you have saved — what it
is, where it runs, and whether it is open right now.

- **Native Swift + AppKit**, GPU rendering via Metal (SwiftTerm engine). No Electron, no web views.
- **Translucent and blurred**, like Terminal.app: the window frosts whatever is behind it and each
  terminal is translucent over that. The focused terminal turns slightly more opaque so what you
  are typing in stays crisp.
- **Real window chrome** on every terminal: rounded corners, a soft shadow, and red/yellow/green
  buttons that close it, roll it up to its header, and maximize it.
- **Environments.** Mark a terminal as production, staging, development or local and it takes on
  that colour: its background, header, badge and list row. A production shell never looks like a
  local one.
- **Free-floating terminals.** Drag any terminal by its header, resize from any edge or corner,
  overlap them however you like. Edges snap to the window and to each other; hold ⌘ while dragging
  to suppress snapping.
- **Arrange commands** when you want order back: tile into a grid, cascade, or throw the active
  terminal to a half of the window.
- **A terminal list on the left**, like a slide panel. Each row shows a live thumbnail of that
  terminal's screen, its name, its working directory, and a dot for open or closed.
- **Every terminal has saved settings**: a working folder and commands to run on open, such as
  activating a virtualenv. Close a terminal and its settings stay in the list; click it to bring
  it back.
- **Every terminal has its own command history**, so pressing Up in one shows only what you typed
  there. This needs no changes to your dotfiles.
- **Workspaces** save a whole window of terminals to a JSON file. **Session restore** brings back
  your terminals on relaunch. Plus native tabs, input broadcast, scrollback search, and a
  hot-reloading config file.

## Build

Requires Xcode 15+ command line tools (Swift 5.9+) and macOS 14+.

```bash
make app            # builds build/Termsie.app (release)
make run            # build and open it
make install        # copy to /Applications
make icon           # regenerate Resources/AppIcon.icns
```

`make app CONFIG=debug` builds a debug bundle. The first build fetches SwiftTerm.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New window / new tab | ⌘N / ⌘T |
| New terminal | ⌘D |
| New terminal, then tile everything | ⌃⌘D |
| Duplicate terminal | ⇧⌘D |
| Terminal settings | ⌘I |
| Set terminal name | ⌥⌘R |
| Close terminal / delete terminal | ⌘W / ⌘⌫ |
| Close window | ⇧⌘W |
| Toggle the terminal list | ⌃⌘S |
| Maximize terminal | ⇧⌘↩ |
| Collapse / expand terminal | green and yellow buttons, or the header menu |
| Tile grid / cascade | ⌥⌘= / ⌥⌘\ |
| Throw terminal to a half | ⌃⌥⌘← → ↑ ↓ |
| Bring to front / send to back | ⌥⌘F / ⌥⌘B |
| Focus terminal left / right / up / down | ⌥⌘← → ↑ ↓ |
| Next / previous terminal | ⌘] / ⌘[ |
| Jump to terminal 1–9 | ⌥⌘1 … ⌥⌘9 |
| Switch to tab 1–9 | ⌘1 … ⌘9 |
| Toggle terminal headers | ⇧⌘H |
| Broadcast input to all terminals | ⌥⌘I |
| Clear scrollback | ⌘K |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Bigger / smaller / default text | ⌘= / ⌘- / ⌘0 |
| Save workspace / open workspace file | ⇧⌘S / ⇧⌘O |
| Open settings file | ⌘, |

Mouse: drag a header to move a terminal, drag its edges or corners to resize, double-click the
header to maximize, right-click it for a menu including its environment. The three buttons at the
top left close the terminal, roll it up to its header, and maximize it. ⌥⌘-drag anywhere inside a
terminal also moves it, which is how you move one with headers hidden. In the list, click a row to
open or focus it, double-click for its settings, drag rows to reorder, and use **+ New Terminal**
at the bottom to add one.

Closing a terminal keeps it in the list. Deleting removes it for good. The window closes only when
its last terminal is deleted, so a window of saved-but-closed terminals is a normal state.

## Configuration

`~/.config/termsie/config.json` is created on first launch and reloaded whenever it changes.
Every key is optional.

```json
{
  "font": { "family": "Menlo", "size": 13 },
  "shell": null,
  "shellArgs": ["-l"],
  "scrollback": 10000,
  "renderer": "metal",
  "cursorStyle": "block",
  "bell": "visual",
  "optionAsMeta": true,
  "showPaneHeaders": true,
  "closePaneOnExit": "clean",
  "confirmClosingRunningProcess": true,
  "restoreSession": true,
  "snapToCells": true,
  "opacity": 0.88,
  "activeOpacityBoost": 0.07,
  "blurBackground": true,
  "cornerRadius": 10,
  "trafficLights": true,
  "environments": [
    { "id": "local",       "label": "Local",       "tint": null },
    { "id": "development", "label": "Development", "tint": "#61afef" },
    { "id": "staging",     "label": "Staging",     "tint": "#e5c07b" },
    { "id": "production",  "label": "Production",  "tint": "#e06c75", "strength": 0.26 }
  ],
  "shellIntegration": "auto",
  "history": {
    "isolate": true,
    "size": null,
    "saveSize": null,
    "mergeToGlobalOnExit": true,
    "respectShareHistory": true,
    "retentionDays": 30
  },
  "startupCommands": { "mode": "shim", "echo": true, "recordInHistory": false },
  "sidebar": { "visible": true, "width": 264, "rowHeight": 84, "thumbnailRefreshMs": 500 }
}
```

- `shell`: `null` uses `$SHELL` (falls back to `/bin/zsh`).
- `renderer`: `"metal"` or `"coregraphics"`.
- `cursorStyle`: `block`, `bar`, `underline`, or the blinking variants `blinkBlock`, `blinkBar`,
  `blinkUnderline`.
- `closePaneOnExit`: `always`, `clean` (only on exit status 0), or `never`.
- `snapToCells`: rounds a resize to whole character cells, so the emulator only reflows when the
  grid actually changes. Turn it off if a resize ever feels sticky.
- `shellIntegration`: `"off"` disables the history and startup-command machinery entirely, and
  terminals launch exactly as a plain shell would.
- `opacity`: how solid a terminal's background is. `activeOpacityBoost` is added to whichever
  terminal has focus; set it to `0` for uniform opacity. Set `opacity` to `1` and
  `blurBackground` to `false` for a fully opaque window.
- `environments`: your own list, in menu order. The first entry is the default for new terminals.
  A `tint` of `null` means no colour; `strength` is how far the background is pulled toward the
  tint. Give a terminal an environment from its header menu, its row in the list, or its settings.

Colors live under `colors`, including `sidebarBackground`, `sidebarSelection`, and the 16-entry
`ansi` palette.

## Workspaces

Workspaces live in `~/.config/termsie/workspaces/<name>.json` and appear under
**Workspaces ▸ Open Workspace**. **Save Workspace…** writes the current tab's terminals with their
folders, startup commands, and positions, and can optionally fold in whatever each terminal is
running right now.

```json
{
  "version": 2,
  "name": "fullstack",
  "layout": {
    "version": 2,
    "terminals": [
      { "id": "t-fullstack-api", "name": "api", "cwd": "~/src/api",
        "startupCommands": ["go run ./cmd/api"], "frame": [0, 0, 0.6, 0.5], "z": 0 },
      { "id": "t-fullstack-py", "name": "worker", "cwd": "~/src/worker",
        "startupCommands": ["source .venv/bin/activate", "python worker.py"],
        "frame": [0, 0.5, 0.6, 0.5], "z": 2 }
    ]
  }
}
```

`frame` is `[x, y, width, height]` as fractions of the window, measured from the top left, so a
workspace saved on a large display still opens sensibly on a laptop. `z` is the stacking order.
`openOnRestore: false` keeps a terminal in the list without starting it. `environment` names one of
the configured environments and tints the terminal. See `examples/workspace.json`.

Older workspace and session files that used the nested split-tree format still open; their panes
become floating terminals in the same positions. `examples/legacy-v1-workspace.json` is one.

Launch straight into a workspace or a directory:

```bash
open -a Termsie --args --workspace fullstack
open -a Termsie --args --cwd ~/src/example
```

## How the terminal list stays live

Thumbnails are drawn from each terminal's character buffer, not captured from the screen. That
matters because the terminals render through Metal, and the usual view-snapshot APIs cannot read a
Metal layer at all. Reading the buffer also means no screen-recording permission is ever needed.

Redrawing is gated so an idle window does no periodic work: a thumbnail is only considered when
its terminal produced output, only for rows actually on screen, and only when a per-row content
fingerprint has changed. The shared refresh timer stops itself after a few quiet ticks.

Each terminal's header and row also show what is running and where, by asking the kernel for the
shell's working directory and the terminal's foreground process group every 1.5 seconds. That is
two cheap syscalls, needs no shell hooks, and works for any shell.

## How per-terminal history works

Termsie generates a small startup directory per terminal and points `ZDOTDIR` at it. Those
generated files source your own `.zshenv`, `.zprofile`, `.zshrc` and `.zlogin` first, then pin
`HISTFILE` to that terminal's private file afterwards — which is what makes it survive setups like
oh-my-zsh that assign `HISTFILE` themselves. `ZDOTDIR` is handed back to its original value before
your shell reaches the prompt, so nested shells and tools are unaffected.

Startup commands run from that same shim, once, just before the first prompt. They are echoed dim
so their output is never unattributed, and they are kept out of your history. They are not typed
into the terminal, which matters: typing several commands at once would feed later lines into the
standard input of whatever the earlier one started.

Bash gets `HISTFILE` plus a one-shot prompt hook; fish gets its own session history; any other
shell gets `HISTFILE` alone. Anything unrecognized or ambiguous falls back to leaving your shell
completely untouched — a terminal with shared history is a missing feature, a terminal with a
broken `PATH` is a broken app. `"shellIntegration": "off"` disables all of it.

If you deliberately run `setopt share_history`, Termsie leaves your history alone.

## Layout

```
Sources/Termsie/
  App/        AppDelegate, MainMenu, Config (JSON + file watcher), DebugDriver
  Model/      TerminalDefinition (the saved terminal), TerminalRegistry (definitions ↔ live panes)
  Window/     TerminalWindowController — lifecycle, focus, menus, workspace and session plumbing
  Layout/     PaneCanvasView (floating terminals), PaneChrome (hit zones), Arrange (tile/cascade),
              LayoutTree (legacy v1 decode only)
  Terminal/   TerminalPane, TermsieTerminalView, PaneHeaderView, TrafficLightsView, FindBarView,
              ProcessInspector, ShellIntegration + ShimScripts (history and startup commands)
  Sidebar/    TerminalSidebarView, TerminalRowView, SidebarFooterView, ThumbnailRenderer,
              ThumbnailSource, TerminalSettingsPopover, SidebarContainerView, BadgeDrawing
  Session/    WorkspaceStore (v2 format), LegacyMigration (v1 split trees → terminals)
```

## Tests

```bash
./scripts/test-shim.sh   # the shell shim, before the app is ever launched
./scripts/test-app.sh    # the app, driven headlessly
```

`test-shim.sh` compares a native `zsh -li` against a shimmed one and requires the exported
environment to be identical apart from the history variables, then proves history isolation over
real pseudo-terminals with `expect`. `test-app.sh` drives the real app and checks thumbnail
correctness and cost, session migration, terminal lifecycle, startup commands, dragging and
snapping, translucency, collapse, environments, and that a terminal's name is the same in its
header and its list row. Both use throwaway fixture directories and never touch your real
configuration.

`Termsie --snapshot out.png --actions newTerminalAction,type:ls\n,tileGrid --quit` drives the app
from a script and saves a PNG of the window. `--emit-shim <dir>` writes the generated shell files
without launching the interface.
