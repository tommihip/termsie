Termsie 0.8.0 — universal, signed with a Developer ID and notarised by Apple.

## What's new

- **Environment variables per terminal and per workspace.** Each terminal can have its
  own environment variables, and a workspace can set variables for all of its terminals.
  If both set the same name, the terminal's value wins. They are set when the shell
  starts, whether or not the startup commands run, so they never appear on screen or in
  your shell history.
- **Secrets stay out of your files.** Mark a variable as secret and its value is kept in
  your macOS Keychain, not in the workspace file or the saved session. Once saved, the
  value is never shown again. A secret you remove is deleted from the Keychain once
  nothing refers to it. If a workspace is opened on a Mac that doesn't have the secret,
  the terminal says which one is missing.
- **Workspace Settings panel** (Workspaces ▸ Workspace Settings…, ⌥⌘,). One place to set
  up every terminal in a workspace: name, folder, environment, startup commands, font,
  wrapping, padding and environment variables. Terminals can be added and removed here
  too. It has two views of the same settings:
  - **Form** — fields for the workspace defaults and for each terminal.
  - **JSON** — the whole workspace as one document, for editing by hand or by an AI
    tool. Mistakes such as a misspelt key are reported instead of silently ignored.

  Changes take effect when you press Apply, and Revert throws them away.
- **Workspace-wide font and layout.** A workspace can set its own font, size, line
  wrapping and padding. Terminals use it unless they set their own, and anything left
  unset follows the global settings.
- **Quicker way in from a terminal.** The terminal settings popover has a new button that
  opens the Workspace Settings panel on that terminal.
- **Output that survives closing.** A terminal now keeps the end of its output when it
  closes and shows it again when it reopens — after closing the terminal, its workspace, or
  Termsie itself. Colours are kept. How much is kept is a setting (1000 lines by default,
  0 for none) in Settings ▸ General, and each workspace can set its own in Workspace
  Settings. Reopening a saved workspace now also brings back each terminal's own command
  history, which it previously started afresh.
- **Run startup commands on demand.** Each terminal in the list has a ▶ button that runs
  its startup commands, opening it first if it is closed. **Run All**, beside New Terminal,
  runs them for every terminal in the workspace. Both are in the Shell menu too.
- **A resizable terminal list.** Drag its edge narrower and the thumbnails shrink, then give
  way to just the names, and finally to just the numbers. Wider than the default, the
  thumbnails stay the same size and the names get the room.
- **The "run startup commands?" question comes after the workspace opens,** as a sheet on
  its window, so you can see what you are opening. It no longer lists the commands.

**Install:** download the `.dmg` below and drag Termsie to your Applications folder, or

```bash
brew install --cask tommihip/tap/termsie
```

Requires macOS 14 Sonoma or later. Runs on Apple silicon and Intel.

## What Termsie is

One window for everything you're running. Floating terminals you can drag, resize
and overlap, a sidebar that shows a live thumbnail of each one and what it is doing,
and an environment tag that colours a terminal so production is never mistaken for
local. Saved terminals, workspaces, per-terminal command history without touching
your dotfiles, and native Swift/AppKit rendering through Metal.

Full feature list and the reasoning behind the more interesting parts are in the
[README](https://github.com/tommihip/termsie#readme), and there is a website at
[termsie.com](https://termsie.com).

## Status

Termsie is young. It is used daily by its author, but it has not been through many
hands yet, so expect rough edges and possible breaking changes to the config format
before 1.0. Bug reports with a crash log or the steps that produced the problem are
extremely welcome.
