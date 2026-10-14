# Termsie on Linux

Termsie runs on Linux with GTK 4, on x86_64 and aarch64, under Wayland and X11. It is the same
app as on macOS and Windows: floating terminals in one window, the live terminal list,
environments, saved terminals and workspaces, per-terminal history, the copy tools and kept
output. The workspace and session files are the same format everywhere, so a workspace saved on
a Mac opens on Linux and the other way round.

## Install

Download `Termsie-<version>-linux-x86_64.tar.gz` (or `-aarch64`) from the
[releases page](https://github.com/tommihip/termsie/releases) and unpack it into a prefix, which
gives you `bin/termsie` and the desktop entry:

```bash
tar -xzf Termsie-*-linux-x86_64.tar.gz
cp -r termsie/. ~/.local/        # or: sudo cp -r termsie/. /usr/local/
```

It needs GTK 4 (4.6 or later), libsecret and libcurl, which every current desktop distribution
has; the Swift runtime is built in.

Termsie checks for a new release once a day and offers to open its page; it never replaces
itself, and a copy under `/usr` or `/opt` is left to the package manager entirely.

## Shells

Termsie opens your account's shell (`$SHELL`, or the login shell from `/etc/passwd`), as a login
shell. Set `"shell"` in config.json, or Shell in Settings, to use another:

| Shell | What Termsie adds |
| --- | --- |
| zsh | Own history per terminal, startup commands run before the first prompt, working folder in the header, command marks for the copy tools |
| bash | Own history, startup commands, prompt marks, working folder |
| fish | Own history, startup commands, working folder |
| anything else (`sh`, `dash`, …) | Startup commands are typed in once the prompt appears; the working folder is read from `/proc` |

The integration is a set of generated files (a `ZDOTDIR`, a bash rc, a fish init command) that
never touch your dotfiles; `termsie --emit-shim <folder>` writes them out to look at.

## Keyboard

The shortcuts are the ones Windows Terminal and GNOME Terminal use: macOS's ⌘ becomes
**Ctrl+Shift**, so every plain Ctrl+letter still reaches the shell. The full table is in
[Termsie on Windows](windows.md#keyboard); the Linux build reads the same one. Alt+key sends Esc
then the key, the convention terminal programs expect for Meta. Ctrl+Alt+drag anywhere in a
terminal moves it; holding Ctrl while resizing turns snapping off.

A selection is also the primary selection: middle-click pastes it, as everywhere on Linux.

## Where things are kept

| What | Where |
| --- | --- |
| Settings | `~/.config/termsie/config.json` (`$XDG_CONFIG_HOME/termsie` when that is set) |
| Workspaces | `~/.config/termsie/workspaces/` |
| Last session | `~/.config/termsie/session.json` |
| Per-terminal history and kept output | `~/.config/termsie/panes/<terminal id>/` |
| Secret values | the Secret Service (GNOME Keyring, KWallet, KeePassXC) under `Termsie/com.termsie.app.env/…` |
| Diagnostics | `~/.local/state/termsie/termsie.log` (`$XDG_STATE_HOME/termsie`) |

Without a running Secret Service a secret cannot be stored, and Termsie says so rather than
writing it to a file.

## Wayland

A Wayland compositor does not let an application choose where its windows go, so Termsie
restores a window's size but not its position. Blur behind a translucent window is a compositor
extension Termsie does not use: terminals are drawn opaque, whatever `blurBackground` says. A
program writing to the clipboard through OSC 52 can only do so right after you have typed or
clicked in the window, which is the compositor's rule for every application.

## Building from source

1. Install Swift 6.4 ([swift.org/install/linux](https://www.swift.org/install/linux/)) and the
   development packages:

   ```bash
   sudo apt install libgtk-4-dev libsecret-1-dev      # Debian, Ubuntu
   sudo dnf install gtk4-devel libsecret-devel          # Fedora
   ```

2. Build and stage an installable tree in `dist/linux/<arch>/termsie`, packed as a tarball:

   ```bash
   ./scripts/build-linux.sh
   ```

   A plain `swift build` works too; the binary is then `.build/debug/Termsie`.

3. Test:

   ```bash
   swift test                       # the shared core
   ./scripts/test-shim.sh           # the zsh shim, against a native zsh
   ./scripts/test-linux.sh          # the app, driven headlessly
   ```

`test-linux.sh` starts the real app against throwaway config folders and checks the shell,
terminal lifecycle, layout, startup commands, environment variables and secrets, the copy tools,
kept output and session restore, history isolation, a shell without integration, the workspace
JSON, the list's width stages and thumbnail cost. It runs under `xvfb-run` when there is no
display, which is how CI runs it. Screenshots and logs go to `test-output/`.

## How the Linux app is built

- **TermsieCore** is shared with macOS and Windows: the model, workspaces and sessions, config,
  shell integration, command marks, text capture and kept output.
- **TermsieApp** is the front end shared with Windows: one window drawn in a single pass, with
  SwiftTerm as the emulator. Under it, `Host/Linux` is the GTK side: the window and its events,
  the main-loop bridge, dialogs, the forkpty shell (SwiftTerm's `LocalProcess`), and the
  foreground job and folder read from `/proc`.
- **CTermsieHost** is the C contract both hosts implement; `linux/` does it with GTK 4, Cairo,
  Pango (shaped text with every cluster pinned to its cell, fallback fonts through fontconfig),
  GIO and libsecret.
