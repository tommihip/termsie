Termsie 0.7.0 — universal, signed with a Developer ID and notarised by Apple.

## What's new

- **Auto-update.** Termsie now checks GitHub for new releases and can download,
  verify and install them from inside the app.
- **Close-workspace warning when creating a new one.** Creating a new workspace now
  asks before closing the one that is currently open.
- **Running-command warning on workspace close.** Closing a workspace warns you if
  any of its terminals still has a command running.

## Fixes

- A terminal with a startup command that was interrupted with a break (Ctrl-C)
  would not always run its startup command again. It now does reliably.

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
