Termsie 0.9.0 — universal, signed with a Developer ID and notarised by Apple.

## What's new

- **SSH terminals.** A terminal can now be a connection to a server instead of a local
  shell: **Shell ▸ New SSH Terminal…** (⇧⌘N), or **Connect over SSH…** in any terminal's
  settings. It runs your own `ssh`, so `~/.ssh/config`, the SSH agent, `known_hosts` and
  ProxyJump all work as they always have.
- **Saved logins, kept in the Keychain.** An SSH terminal can remember its password, its
  key's passphrase, or the private key itself. They are typed for you when `ssh` asks and
  are never shown, written to a workspace file or put in your history. A stored password
  that turns out to be wrong is tried once, and then you are asked in the terminal.
- **Startup commands and folders on the server.** An SSH terminal's startup commands run on
  the server before its shell starts, and its working folder is a folder there. Close it
  and click it in the list to reconnect.
- **You can see that a copy worked.** Every copy — ⌘C, the copy tools, their shortcuts and
  auto-copy on select — now shows a short note on the terminal saying what was copied, how
  many lines, and how it begins. If there was nothing to copy, it says so and why, rather
  than leaving you to guess. ⌘C with nothing selected no longer empties the clipboard. The
  note can be turned off in Settings ▸ General.
- **Option keys type what your keyboard says.** On Finnish, Swedish, German and similar
  layouts, ⌥2 now types `@` (and `[ ] { } | \ ~` work too) instead of being taken as Meta.
  Option still works as Meta for word movement wherever the layout has no character there,
  including on a US keyboard.

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
