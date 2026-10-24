Termsie 0.9.1 — universal, signed with a Developer ID and notarised by Apple.

## What's fixed

- **Sharp text on Retina displays with line wrapping off.** A terminal with wrapping off is
  as wide as all of its columns, and with a large *Columns when lines are not wrapped*
  setting that could be more than the graphics card can draw at 2×, so text on a MacBook's
  built-in display turned into an unreadable blur while external 1× displays looked fine.
  Such a terminal now gets as many columns as can be drawn sharply — about 1000 at 13 pt on
  a Retina display, twice that on a 1× one — and adjusts when the window moves between
  displays.

## What's new

- **New SSH terminals from the terminal list.** The **New Terminal** button at the bottom of
  the list now opens a small menu: **New Terminal** or **New SSH Terminal…**. ⌘D and ⇧⌘N work
  as before.

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
