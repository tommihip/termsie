# Releasing Termsie on Linux — investigation and plan

*Written 2026-10-13 against the `windows-port` branch (16f0a7f, 0.8.0), on Pop!_OS 24.04 under
GNOME on Wayland. Companion to [windows-release-plan.md](windows-release-plan.md), which this
plan builds on. Phases 0 to 4 and most of 5 and 6 were then carried out on the `linux-port`
branch the next day; section 0 records the outcome, and the rest is the plan as written.*

## 0. Outcome

Option A, as recommended, done on `linux-port` in one pass: the Windows front end was hoisted
into `Sources/TermsieApp` with `Host/Win32` and `Host/Linux` underneath, the C layer became one
`CTermsieHost` target with `windows/` and `linux/` sources behind a single header, and the GTK 4
host went in on top. User-facing documentation is in [linux.md](linux.md).

| Phase | Result |
| --- | --- |
| 0. Spike | Folded into the real code: Pango shapes each run and every cluster is pinned to its cells; a GtkDrawingArea's draw callback is the only place a frame is drawn, and the host queues redraws. |
| 1. Hoist | `Key`, `Modifiers`, `WindowRef`, `HostWindow`, `ShellProcess`, `NativeMenu` and `CommandLineText` are the seams; `MainWindow` no longer subclasses the Win32 window, `Win32WindowHost` does. The Windows side compiles only in CI, which has not run yet. |
| 2. Linux host | GTK window and events, input method, main-loop bridge (with Foundation pumped), Cairo/Pango renderer, fonts through fontconfig, PRIMARY selection, menus as popovers, GIO config watcher, snapshots as PNGs. |
| 3. Dialogs | `FormWindow` on GTK widgets with the same API; `GtkMessageDialog` and `GtkFileChooserNative`, so GTK 4.6 is enough. |
| 4. Shell | SwiftTerm's `LocalProcess` is the shell; the foreground job and folder come from `tcgetpgrp` and `/proc`; secrets in libsecret; the default shell is the account's. |
| 5. Release | `build-linux.sh` stages `bin/`, `share/applications`, `share/icons`, `share/metainfo` with the Swift runtime linked in and packs a tarball; the updater only opens the release page. No `.deb`, release workflow or signing yet. |
| 6. Tests | `test-linux.sh`: 29 checks, the Windows list with `sh` in place of cmd; all pass on this machine under XWayland. CI runs it under `xvfb-run`. |

Still to do: run CI to prove the Windows build survived the hoist; the `.deb` and the
`release-linux.yml` workflow with an aarch64 runner; blur or plain translucency; and a look at
the first real users' fonts, since `monospace` resolves differently on every distribution.

## 1. The short version

The Windows port did most of the Linux port's work already. Of the Windows app's ~9,000 lines of
Swift, about 5,500 never touch Win32: the floating-pane canvas, the terminal list and thumbnails,
the tab controller, the terminal painter, the session logic, the settings forms and the headless
driver all draw through a small `Renderer` wrapper and a flat C interface (`tw_*`). On Linux, that
same code runs on top of a GTK 4 window drawn with Cairo and Pango, and the pseudo-terminal comes
free: SwiftTerm's `LocalProcess` (`forkpty`) compiles on Linux, exactly as the macOS app uses it.

What has to be written: a GTK host (window, events, input method, clipboard, menus, cursor,
main-loop bridge) and a C layer that implements the existing `tw_*` drawing, font, dialog and
secret functions with Cairo, Pango, GTK and libsecret. What has to be refactored: the Windows
front end's Win32 bits hoisted out of the files that are otherwise portable, so one front end
serves both. What has to be decided: how old a distribution to support, and how to ship.

Recommended path: hoist the shared front end first (Windows stays green throughout), then build
the GTK host behind the same C contract, gated by a one to two week spike on this machine that
proves Cairo text rendering at the cell grid and the GTK/Foundation main-loop bridge. Realistic
effort for one engineer: ten to fifteen weeks to a 0.x Linux release, roughly half the Windows
port, because the front end is reused rather than written.

## 2. What was found

### 2.1 The code

Measured by counting Win32 references (`HWND`, `WM_*`, `VK_*`, `Win.*`, `Keys.*`) and `tw_*`
calls per file in `Sources/TermsieWindows`:

| File | Lines | Win32 refs | Linux status |
| --- | --- | --- | --- |
| `UI/Pane.swift` | 974 | 7 (`owner: HWND?` ×2, `Keys.shift/alt/control`) | Portable: pass modifiers with the event, an opaque window handle for the clipboard |
| `UI/TabController.swift` | 923 | 0 | Portable as-is |
| `UI/Sidebar.swift` | 512 | 0 | Portable as-is |
| `UI/MainWindow.swift` | 1,076 | 49 + 7 `tw_` | Half window procedure, half canvas interaction (hit testing, drag, snap, menus); the second half hoists |
| `UI/Commands.swift` | 318 | 47 | `Command` and `MenuBuilder.structure` portable; `Shortcut`/`Keymap`/`build` are VK codes and `HMENU` |
| `UI/TextField.swift` | 162 | 10 (`VK_*`) | Portable once keys are a neutral enum |
| `UI/Theme.swift`, `UI/TerminalRegistry.swift` | 333 | 0 | Portable as-is |
| `Terminal/TerminalPainter.swift` | 302 | 0 | Portable as-is |
| `Terminal/TerminalSession.swift` | 468 | 1 | Portable; the ~60 lines that spawn and read `ConPty` go behind a four-method protocol |
| `Terminal/ConPty.swift`, `Terminal/ProcessTree.swift` | 385 | n/a | Not needed on Linux: `LocalProcess` and `/proc` |
| `Terminal/KeyEncoder.swift` | 105 | 22 | The escape-sequence table is portable; the key codes are not |
| `Render/Renderer.swift` | 199 | `UINT`, `WCHAR` | Portable with two typealiases |
| `Dialogs/FormWindow.swift` | 500 | 34 | The `Field`/`Kind`/`ButtonSpec` model is declarative; the Win32 control code is the host part |
| `Dialogs/*Settings*.swift` | 783 | 1–4 each | Portable over the `FormWindow` API |
| `App/App.swift`, `App/DebugDriver.swift` | 694 | 3 + `ConfigWatcher` | Portable; `ConfigWatcher` (44 lines) is host |
| `App/Updater.swift` | 319 | 8 | Logic reusable; signature pinning and the swap are Windows-only |
| `App/CredentialSecretBackend.swift` | 43 | 4 `tw_` | Rewrite: libsecret (same size) |
| `Win32/Win32.swift`, `Win32/Window.swift`, `Win32/Shell.swift`, `main.swift` | 862 | all | Host: rewrite for GTK |
| `CTermsieWin` (C++) | 1,442 | all | `Renderer.cpp` 593 → Cairo/Pango; `System.cpp` 432 → GTK/libsecret/`/proc`; `Pty.cpp` 207 → not needed |

The seams are few and small: strings cross the C boundary as UTF-16 (`wchar_t`), windows are
`HWND?`, keys are virtual-key codes, modifier state is read from the keyboard (`Keys.*`), the
clipboard read and the popup menu are synchronous, and `MainQueue` is a message-only window.
Each has a one-type or one-signature fix (section 4, Phase 1).

`TermsieCore` already handles Linux: `~/.config/termsie` via XDG, `$SHELL`, POSIX file privacy,
the zsh, bash and fish shims, and `JSONShape` for swift-corelibs-foundation. CI has tested it in
a `swift:6.4` container on every push since the package split. Two core details need a Linux
value: the default shell falls back to `/bin/zsh`, which most distributions do not install
(use the passwd entry, then `/bin/bash`), and the log file location.

### 2.2 SwiftTerm (the emulator) on Linux

The pinned 1.20.0 (`5d14406`) excludes `Apple/`, `Mac/` and `iOS/` on Linux and compiles
`LocalProcess.swift`, `Pty.swift` and `HeadlessTerminal.swift` (`#if !os(iOS) && !os(Windows)`).
`LocalProcess` gives `startProcess(executable:args:environment:execName:currentDirectory:)`,
`send(data:)`, `terminate()`, `shellPid` and `childfd`, with `dataReceived` and
`processTerminated` on a delegate. That is the Windows `ConPty` surface, so no pseudo-terminal
code is written for Linux at all. Two things to know:

- `LocalProcess` posts data on `DispatchQueue.main` by default. GTK's loop does not drain that
  queue, so give it a private serial queue and hop to `MainScheduler` (the same bridge the
  Windows app already needs).
- `childfd` is the pty master, which is what `tcgetpgrp` wants for the foreground job, exactly
  as the macOS `ProcessInspector` does it.

The SwiftTerm build plugin that crashes on Windows runs fine on Linux; the core CI job proves it.

### 2.3 Swift on Linux (October 2026)

- Toolchain: Swift 6.4 via `swiftly` ([swift.org/install/linux](https://www.swift.org/install/linux/)),
  or the `swift:6.4` Docker images (`-jammy`, `-noble`, `-bookworm`, `-trixie`, `-resolute` and
  RHEL variants exist). This machine has none installed.
- `swift build --static-swift-stdlib` links the Swift runtime and Foundation into the binary, so
  nothing Swift-specific ships beside it. `FoundationNetworking` (the update check) still needs
  the system `libcurl`. glibc is linked dynamically, so a binary runs on distributions whose glibc
  is at least the build machine's: build on the oldest supported one.
- Calling GTK, Cairo, Pango and libsecret from Swift: a C target that includes their headers,
  behind the same flat `tw_*` interface as `CTermsieWin`, with SwiftPM `systemLibrary` targets
  (`pkgConfig: "gtk4"`, `"libsecret-1"`) supplying the flags. GObject signals and varargs are
  awkward from Swift and short in C, which is the same reasoning as on Windows.

UI toolkit options:

| Option | Fit for Termsie |
| --- | --- |
| GTK 4 window + `GtkDrawingArea` drawn with Cairo/Pango, GTK widgets only for dialogs | Best fit. Termsie's window is one custom-drawn surface; GTK supplies what Win32 did: a window on Wayland and X11, HiDPI, key and pointer events, `GtkIMContext`, `GdkClipboard`, `GtkPopoverMenu`, file and message dialogs, `GFileMonitor`, cursors. Cairo/Pango is what every Linux terminal with a Cairo renderer (GNOME Terminal via VTE) draws with, and Pango does font fallback through fontconfig. |
| GTK 4 with a GPU surface (`GtkGLArea`, Vulkan) | Faster at huge sizes; much more code. Not needed until measured. |
| Qt | No usable Swift binding. |
| `swift-cross-ui` (GTK backend) | Declarative widgets; wrong shape for the canvas and terminal view, as on Windows. |
| Raw Wayland/X11 + own text stack | Reinvents GTK's input method, clipboard and HiDPI handling for no gain. |

Platform facts that shape the port:

- **Wayland does not let an application position its windows** or read where they are, so the
  saved window `frame` restores size only and `ensureOnScreen` is a no-op there. The floating
  panes are inside the window, so snapping and layout are unaffected. X11 still honours
  positions; GTK handles both backends from the same code.
- **Blur** behind translucent windows is compositor-specific (KDE has a protocol, GNOME has
  none). Translucent pixels are possible on both, blur is not. Draw opaque; `blurBackground`
  has no effect on Linux. Plain translucency can be added later if asked for.
- **Clipboard reads are asynchronous** on Wayland (`gdk_clipboard_read_text_async`). Linux users
  also expect a selection to land in PRIMARY and middle-click to paste it; GTK exposes both
  clipboards.
- **Scaling** is the GTK scale factor, fractional on Wayland with GTK ≥ 4.12. Cairo coordinates
  are logical pixels, which is what the renderer calls DIPs; cell metrics still snap to device
  pixels.
- **GTK API baseline.** `GtkFileDialog` and `GtkAlertDialog` need GTK 4.10 (Ubuntu 24.04 has
  4.14, 22.04 has 4.6, Debian 12 has 4.8). `GtkFileChooserNative` and `GtkMessageDialog` exist
  from 4.0 and are deprecated but present in 4.10+. Using the older pair keeps 22.04 and Debian
  12 in reach; see decision 2.
- **Keyboard conventions** match the Windows port already: GNOME Terminal and Konsole use
  Ctrl+Shift+letter for application shortcuts so that Ctrl+C, Ctrl+D and Ctrl+R reach the shell.
  The Windows shortcut table ports unchanged. Ctrl+letter has to be turned into a control
  character by the key encoder on Linux (`WM_CHAR` did that on Windows).
- **Fonts.** No Consolas or Segoe UI. The terminal default is fontconfig's `monospace` alias and
  the interface font comes from the GTK `gtk-font-name` setting. `pango_font_map_list_families`
  with `pango_font_family_is_monospace` is `tw_font_families`.
- **Secrets.** libsecret talks to the Secret Service (GNOME Keyring, KWallet ≥ 5.97, KeePassXC).
  Without a running service the store fails, which `SecretStore` already reports as "not found".
  CI has no service and uses `TERMSIE_SECRETS_FILE`, as the Windows tests do.
- **Headless CI.** GTK 4 runs under `xvfb-run` (X11 backend) with `GSK_RENDERER=cairo`; the
  snapshot is a Cairo image surface written with `cairo_surface_write_to_png`.
- **ARM.** GitHub offers `ubuntu-24.04-arm` and `ubuntu-22.04-arm` runners, so aarch64 builds
  natively like the Windows ARM64 job.

### 2.4 Release pipeline today

Nothing in `release.sh` or `release-windows.ps1` applies. The Linux analogues: `.desktop` entry,
hicolor icons and AppStream metainfo instead of an `Info.plist` or MSIX manifest; a tarball and a
`.deb` instead of a dmg or zip; `SHA256SUMS` (optionally signed with the maintainer's GPG or
minisign key) instead of Authenticode or notarisation; distribution packages and, later, Flatpak
instead of an in-app updater. There is no OS trust anchor to pin a self-update to, so the
in-app updater on Linux checks the feed and opens the release page, the path the MSIX and
Homebrew installs already take.

## 3. Options

**A. Hoist the Windows front end into a shared raster front end and add a GTK host
(recommended).** `Sources/TermsieWindows` becomes `Sources/TermsieApp` with `Host/Win32/` and
`Host/Linux/` subdirectories, each excluded on the other platform, and the `tw_*` C contract gets
a second implementation, `CTermsieLinux`. One front end, one set of behaviours and tests for
Windows and Linux; the macOS AppKit app stays as it is. Risk: the refactor touches the Windows
code, so it must be done with Windows CI green at every step.

**B. A third front end in GTK widgets.** Native-looking lists and dialogs, but the canvas and
terminal view are custom-drawn either way, so most of the 5,500 reusable lines would be written
a third time with a different event model, and three front ends drift. Only worth it if GTK
widgets for the sidebar are a product requirement.

**C. Electron/Tauri or a Rust rewrite.** Rejected for the same reasons as on Windows.

Option A, gated by the Phase 0 spike.

## 4. Plan (Option A)

Effort estimates are for one engineer, calendar weeks, deliberately wide.

### Phase 0 — Spike and go/no-go (1–2 weeks, on this machine)

Goal: a GTK 4 window running `$SHELL` through SwiftTerm's `LocalProcess`, drawn with Cairo and
Pango through the existing `tw_*` drawing calls, with keyboard input, resize and a PNG snapshot.

1. Install the toolchain (section 6). Build `TermsieCore` and run `swift test` here.
2. `CTermsieLinux`: `tw_renderer_*`, `tw_fill_rect`, `tw_draw_cells`, `tw_draw_text`,
   `tw_font_*`, `tw_snapshot_*` on a `GtkDrawingArea`. `tw_draw_cells` shapes the run with
   `pango_itemize`/`pango_shape` and overrides each cluster's advance to `cells × cellWidth`
   before `pango_cairo_show_glyph_string`, which is the DirectWrite trick of pinning every
   glyph to the grid so fallback fonts cannot drift it.
3. A `LocalProcess` on a private queue feeding `Terminal.feed` through a GLib idle source.
4. Keys: `GtkEventControllerKey` through a `GtkIMMulticontext`; committed text to the terminal,
   non-text keys through `KeyEncoder`'s table.
5. Measure: redraw cost under `yes` at 200×50, input latency, fallback glyphs (CJK, emoji, Nerd
   Font symbols), 150% and 200% scaling on Wayland and X11.
6. Decide, and record the result at the top of this file.

### Phase 1 — Hoist the shared front end, Windows unchanged in behaviour (1–2 weeks)

Each item is one seam from section 2.1; together they let the Linux target compile with its host
stubbed. Windows CI runs on every push and must stay green.

- `Package.swift`: `Sources/TermsieWindows` → `Sources/TermsieApp`, excluding `Host/Linux` on
  Windows and `Host/Win32` on Linux. The C target is named `CTermsieHost` on both platforms and
  points at `Sources/CTermsieWin` or `Sources/CTermsieLinux`, so every Swift file imports one
  module name. `CTermsieWin.h` becomes the shared contract header: `TWChar` is `wchar_t` on
  Windows and `uint16_t` on Linux (GLib's `g_utf16_to_utf8` converts), handles stay opaque.
- Drop `import WinSDK` from the portable files; `WCHAR`, `UINT` become typealiases in the host.
- `Key`: a neutral enum (arrows, Home/End, paging, Insert/Delete, Backspace, Enter, Escape, Tab,
  F1–F12, a character) replacing `VK_*` in `KeyEncoder`, `TextField`, `Shortcut`, `DebugDriver`.
  Each host maps its codes to it at the event boundary.
- Modifiers travel with the event: `Pane.mouseDown(…, modifiers:)` instead of `Keys.shift`.
- `WindowHandle`: an opaque value replacing `HWND?` in `Pane`, `TerminalSession`, `TextField`,
  `Clipboard`, `Alert`, `FileDialog`.
- `Clipboard.get` takes a completion; the Windows host calls it synchronously.
- `MainWindow.runMenu`/`popup` take a completion; `tw_track_menu` stays synchronous on Windows,
  the GTK host resolves it from the action callback.
- `ShellProcess`: a protocol with `spawn`, `write`, `resize`, `terminate`, `onData`, `onExit`.
  `ConPty` adopts it; Linux wraps `LocalProcess`.
- `MainQueue`, `Debouncer`, `RepeatingTimer`: keep the API, move it to the shared side over three
  host primitives (`tw_main_post`, `tw_main_after`, `tw_main_cancel`).
- `MainWindow`: split the canvas interaction (hover, drag, resize, snap, menus, key routing) from
  the window procedure. The interaction half moves to a `WindowController` the host feeds events.
- Host constants: interface font family, default terminal font, log directory.
- `ProcessInspector.commandLine` (interpreter stripping and quoting) moves from the macOS app to
  `TermsieCore` so Linux reuses it.
- Core: the non-Windows default shell becomes the passwd entry, then `/bin/bash`.

### Phase 2 — Linux host (3–5 weeks)

- `Host/Linux/GtkWindow.swift`: one `GtkWindow` per Termsie window holding a `GtkDrawingArea`;
  `GtkEventControllerKey`, `GtkGestureClick`, `GtkEventControllerMotion`,
  `GtkEventControllerScroll`; `gtk_widget_set_cursor_from_name` for `CursorShape`; full screen;
  title; the size-only frame restore on Wayland.
- `MainQueue` over `g_idle_add`/`g_timeout_add`, plus a 250 ms tick that runs
  `RunLoop.main.run(mode:before:)` so Foundation's main queue and `URLSession` callbacks make
  progress, the Windows loop's trick.
- Input method: `GtkIMMulticontext` on the drawing area; `commit` feeds the terminal or the
  focused `TextField`; `gtk_im_context_set_cursor_location` is `tw_ime_set_position`.
- Keys: GDK keyvals to `Key`; `gdk_keyval_to_unicode` for text not handled by the IM context;
  Ctrl+letter to control characters; Alt+key to ESC-prefixed, as on Windows.
- Clipboard: CLIPBOARD for copy and paste, PRIMARY for the selection as it is made and for
  middle-click; the existing "copy selection the moment you make it" setting keeps CLIPBOARD.
- Menus: `MenuBuilder.Item` to a `GMenu`/`GSimpleActionGroup`, shown as a `GtkPopoverMenu`.
- Renderer: the full `tw_*` drawing set on Cairo (rounded rectangles, clips, shadow as stacked
  outlines, ellipse), fonts via `PangoFontDescription`, metrics via `pango_font_get_metrics`
  rounded to device pixels, family listing and existence via the font map; snapshot via an
  image surface. `backdropActive` is false.
- Config watching: `GFileMonitor` on the config directory, debounced as today.
- `DebugDriver` unchanged apart from the key names.

### Phase 3 — Dialogs (1–2 weeks)

- `FormWindow` on GTK: the C layer builds a transient modal `GtkWindow` with a `GtkGrid` from the
  `Field` list (`GtkEntry`, `GtkTextView` in a `GtkScrolledWindow`, `GtkCheckButton`,
  `GtkDropDown`, an editable combo, labels, headings, buttons), with the accessory button and
  page switching. `runModal` runs a nested `GMainLoop` until a button, which keeps the Swift
  subclasses (Settings, Terminal Settings, Workspace Settings, prompts) untouched; `showModeless`
  just presents.
- `Alert`: `GtkMessageDialog` (or `GtkAlertDialog` on the newer baseline) with the same
  first/second/third mapping and the scripted-run shortcut.
- `FileDialog`: `GtkFileChooserNative` (or `GtkFileDialog`), which on GNOME goes through the
  portal so it works inside a sandbox too.

### Phase 4 — Shell integration and processes (1 week)

- Shells: zsh, bash and fish shims are core and POSIX; verify each on Linux with the real
  distribution packages. `test-shim.sh` runs as-is given `zsh` and `expect`.
- `ProcessInspector` for Linux, modelled on the macOS one: `readlink /proc/<pid>/cwd`,
  `tcgetpgrp(childfd)`, `/proc/<pid>/comm`, `/proc/<pid>/cmdline` split on NUL. About fifty
  lines; the formatting is shared after Phase 1.
- Secrets: `SecretBackend` on libsecret with a schema named `com.termsie.app.env` and a `ref`
  attribute; `secret_password_store_sync`, `_lookup_sync`, `_clear_sync`. Document the Secret
  Service requirement and the failure message when there is none.
- Log at `$XDG_STATE_HOME/termsie/termsie.log` (`~/.local/state/termsie/`).

### Phase 5 — Release engineering (2 weeks)

- `scripts/build-linux.sh`: `swift build -c release --static-swift-stdlib`, then stage
  `dist/linux/<arch>/termsie/` as an installable tree: `bin/termsie`,
  `share/applications/com.termsie.app.desktop`, `share/icons/hicolor/<size>/apps/com.termsie.app.png`
  (from `docs/icon.png`; add `Resources/Linux/`), `share/metainfo/com.termsie.app.metainfo.xml`,
  `LICENSE`.
- `scripts/release-linux.sh`: `Termsie-<version>-linux-x86_64.tar.gz` and `-aarch64`, a `.deb`
  per architecture with `dpkg-deb` (`Depends: libgtk-4-1, libsecret-1-0, libcurl4`),
  `SHA256SUMS-linux.txt`, a detached signature when a key is configured, and with `--publish`
  an upload to the same GitHub release the other scripts use. Version from `AppInfo.version`.
- `.github/workflows/release-linux.yml`: a matrix of `ubuntu-latest` and `ubuntu-24.04-arm`
  (or the 22.04 pair) in the `swift:6.4-<baseline>` container, installing `libgtk-4-dev` and
  `libsecret-1-dev`, building, running the headless tests, packaging, and a single publish job,
  the shape of `release-windows.yml`.
- `Updater` on Linux: check the feed on the same schedule, offer "Open Release Page"; no download,
  no swap. The in-app check is off when the binary lives under `/usr` or `/opt` (a package
  manager owns it), the Homebrew/MSIX rule.
- CI: the `core-linux` job grows into a `linux` job that also builds the app, runs
  `test-shim.sh` and drives the app under `xvfb-run`, and uploads the unsigned tarball.
- Docs: `docs/linux.md` (install, shells, keyboard, where things are kept, Wayland notes,
  building, releasing), README platform badge, requirements and install section.
- Later, on demand: Flatpak (needs a Swift toolchain inside the build sandbox; evaluate once the
  tarball exists), AppImage, an AUR package, `.rpm`.

### Phase 6 — Headless tests on Linux (1 week, overlaps 2–5)

- `scripts/test-linux.sh`: a bash port of `test-windows.ps1` with the same fixtures, actions and
  checks, against `bash` and `zsh`; run under `xvfb-run -a` with `GSK_RENDERER=cairo`.
- The driver flags (`--actions`, `--snapshot`, `--log`, `--quit`, `--emit-shim`) are shared, so
  the checks are the Windows list minus PowerShell and cmd, plus PRIMARY-selection paste.

## 5. Decisions needed from the maintainer

1. **Option A**: hoist the Windows front end into a shared raster front end and add a GTK host,
   gated by the Phase 0 spike?
2. **Baseline**: Ubuntu 22.04 / Debian 12 (glibc 2.35, GTK 4.6, the deprecated-but-present
   dialog APIs, widest reach) or Ubuntu 24.04+ (glibc 2.39, GTK 4.10+ dialogs)? The
   recommendation is 22.04 until it leaves standard support in April 2027.
3. **Distribution**: tarball and `.deb` first, with Flatpak, AppImage, AUR and `.rpm` on demand?
4. **Updates**: no in-app download on Linux, only a check that opens the release page?
5. **Upstream**: the Phase 1 hoist is the natural moment to propose the shared front end to
   `tommihip/termsie`, since it changes the Windows layout too.
6. **Wayland**: accept that window position is not restored there (size is)?

## 6. Immediate next steps on this machine

Pop!_OS 24.04 has Cairo 1.18, Pango 1.52, fontconfig and HarfBuzz, but GTK 3 only, no
libsecret headers and no Swift:

```bash
sudo apt install libgtk-4-dev libsecret-1-dev xvfb zsh expect
# Swift 6.4 through swiftly, as described at https://www.swift.org/install/linux/
swift build --target TermsieCore && swift test     # the core, here, before anything new
```

Then Phase 0: `Sources/CTermsieLinux` with the drawing subset of `CTermsieWin.h`, and a
throwaway `main.swift` that opens a GTK window, starts `$SHELL` through `LocalProcess` and draws
the buffer.

## 7. Sources

- Swift on Linux install: https://www.swift.org/install/linux/
- Swift Docker images (`6.4-jammy`, `6.4-noble`, …): https://hub.docker.com/_/swift
- SwiftTerm `LocalProcess` and `Pty` (compiled on Linux): https://github.com/migueldeicaza/SwiftTerm/tree/1.20.0/Sources/SwiftTerm
- GTK 4: `GtkDrawingArea`, `GtkIMContext`, `GdkClipboard`, `GtkPopoverMenu`,
  `GtkFileChooserNative`, `GtkFileDialog`: https://docs.gtk.org/gtk4/
- Pango shaping and glyph strings: https://docs.gtk.org/Pango/
- libsecret: https://gnome.pages.gitlab.gnome.org/libsecret/
- Wayland xdg-shell (no client-side window positioning): https://wayland.app/protocols/xdg-shell
- Desktop entry and icon theme specifications: https://specifications.freedesktop.org/
- AppStream metainfo: https://www.freedesktop.org/software/appstream/docs/
- GitHub Linux ARM runners: https://github.com/actions/runner-images
- Windows port record, whose structure this follows: [windows-release-plan.md](windows-release-plan.md)
