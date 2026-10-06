# Releasing Termsie on Windows — investigation and plan

*Written 2026-10-06 against commit c397858 (0.8.0). The plan below was then carried out on the
`windows-port` branch; this first section records the outcome, and the rest is the plan as
written, with corrections marked.*

## 0. Outcome

All six phases are done on `windows-port`. CI builds and tests the shared core on Linux, macOS
and Windows, builds the macOS app and runs its shim test, and builds, drives and packages the
Windows app on every push. User-facing documentation is in [windows.md](windows.md).

| Phase | Result |
| --- | --- |
| 0. Spike | Passed on the GitHub Windows runner: Swift 6.4, a C++ target for Direct2D/DirectWrite on a DirectComposition swap chain, ConPTY running PowerShell, SwiftTerm drawing, PNG snapshots. Decision: Option A. |
| 1. Package split | `TermsieCore` (Foundation and SwiftTerm only) shared by both apps; the macOS app builds on it unchanged in behaviour; 51 core tests on three platforms. |
| 2. Terminal view | Cell-exact DirectWrite glyph runs with font fallback, colours, styles, wide characters, selection, scrollback, find, mouse reporting, IME positioning, clipboard. |
| 3. Application shell | Tabs, terminal list (thumbnails, width stages, reorder, copy tools), floating canvas (drag, resize, snap, tile, cascade, halves, maximize, collapse), menus, shortcuts, Terminal / Workspace / global Settings dialogs, Credential Manager secrets, config watching, sessions and workspaces. |
| 4. Shell integration | A generated PowerShell script (history, startup commands, OSC 133 marks, OSC 7 folder) for PowerShell 7 and 5.1, loaded so execution policy cannot block it; bash for Git Bash; typed fallback for cmd; `WSLENV` for WSL. `test-shim.ps1` checks it. |
| 5. Release engineering | `build-windows.ps1` (resources, runtimes, bundled ConPTY), `release-windows.ps1` (Authenticode by certificate or Azure Trusted Signing, zip, MSIX, checksums, GitHub upload, winget manifests), a manual release workflow, and a signature-pinned updater. |
| 6. Headless tests | `test-windows.ps1` drives the real app through a scripted driver: 29 checks over shell, lifecycle, startup commands, secrets, copy tools, kept output and sessions, history, cmd, workspace JSON, list stages and thumbnail cost. |

Both x64 and ARM64 build and pass the same checks in CI; ARM64 runs natively on GitHub's Windows
ARM runners, because the x64 toolchain has no ARM64 runtime to ship.

What is left for a person to do: obtain a code-signing identity (a certificate, or an Azure
Trusted Signing account) and set the release workflow's secrets; run the Windows release workflow
with "publish" for the first signed release and submit the winget manifests it produces; and
decide whether the ARM64 job, reported in CI but not yet required, becomes required.

Things learned on the way, worth knowing before changing the Windows code:

- **SwiftTerm 1.20.0 has no portable render snapshot** (2.2 below said it had; that is on its
  main branch, not in the release). The Windows view reads the buffer through `Terminal`'s
  public API instead.
- **SwiftTerm's build plugin crashes on Windows**: it starts its generator with an environment
  of four variables, so Foundation's `Process` cannot start Winsock. Setting those four variables
  (`scripts/swiftterm-build-info.ps1`) means it never runs git.
- **Clang modules and `windows.h`**: a header Swift imports must not rely on `windows.h`, whose
  declarations are not visible through it under modules. `CTermsieWin.h` uses opaque handles.
- **ConPTY clears the screen when it attaches** unless started with
  `PSEUDOCONSOLE_INHERIT_CURSOR`, which would wipe kept output. Termsie starts it that way.
- **Swift 6.4 imports `BOOL` as `Bool`**, so `TrackPopupMenu`'s command id is lost;
  `tw_track_menu` returns it as an integer.
- **The main dispatch queue is not drained by a Win32 message loop**; shared code schedules
  through `MainScheduler`, which the Windows app routes through its own message-only window.

## 1. The short version

There is no Windows build to "release". Termsie is a macOS application end to end:
AppKit windows, Metal text rendering, a `forkpty` shell, the macOS Keychain, Developer ID
signing, a `.dmg` and a Homebrew cask. Nothing in the repository compiles or runs on Windows
today, and the release script is macOS-only from the first line to the last.

Shipping on Windows is therefore a **port**, not a packaging exercise. The good news is that
the pieces that are hardest to write from scratch, the terminal emulator and the workspace /
session model, are already portable or nearly so. The pieces that must be rebuilt are the user
interface, the pseudo-terminal, secret storage, shell integration for PowerShell, and the
signing / packaging / updater pipeline.

Recommended path: keep Swift, split the package into a portable core and two platform front
ends, and build the Windows front end on Win32 + Direct2D/DirectWrite, gated by a two to
three week spike that proves the toolchain, ConPTY and rendering before anything else is
committed to. Realistic total effort for one engineer: roughly four to six months to a 0.x
Windows release with feature parity on the core experience.

## 2. What was found

### 2.1 The code

| Area | Lines | Windows status |
| --- | --- | --- |
| Whole app (45 files) | 12,516 | 34 files import AppKit, 1 ScreenCaptureKit, 2 Security (Keychain), 1 Darwin |
| Foundation-only files (9) | ~1,755 | Portable as-is: `TerminalDefinition`, `EnvironmentVariables`, `WorkspaceStore`, `WorkspaceDocument`, `LegacyMigration`, `LayoutTree`, `CommandMarks`, `ShellIntegration`, `ShimScripts` |
| Lightly coupled (AppKit for colours/fonts/notifications only) | ~900 | `Config`, `TerminalRegistry`, `OutputSnapshot`, `ThumbnailSource`, `PaneChrome`, `Arrange`: portable after swapping `NSColor`/`NSFont` for plain value types |
| UI, windowing, rendering, menus, settings | ~9,000 | Rewrite for Windows |
| `Updater` | 520 | Logic reusable; the dmg / `codesign` / Developer ID verification is not |
| `SecretStore` | 148 | Keychain → Windows Credential Manager |
| `ProcessInspector` | 86 | `proc_pidinfo` / `sysctl` → Win32 process APIs, or rely on OSC 7 |
| `WindowCapture`, `DebugDriver` | 530 | ScreenCaptureKit → `PrintWindow` / swap-chain readback |

### 2.2 SwiftTerm (the emulator)

Termsie pins SwiftTerm 1.20.0, the current latest tag. Its manifest already has
`#if os(Windows)` branches and excludes the `Apple/`, `Mac/` and `iOS/` directories on
Windows, so the **emulator core compiles on Windows**: parser, buffers, scrollback, search,
selection, OSC 133 semantic prompts, Kitty keyboard, Sixel/Kitty graphics decoders.
*(Correction: the portable hosting layer with `TerminalRenderSnapshot` exists only on SwiftTerm's
main branch, not in 1.20.0. The Windows view reads the buffer through the public `Terminal` API.)*

What SwiftTerm does **not** provide on Windows:

- A view. `MacTerminalView`, `AppleTerminalView` and the Metal renderer are Apple-only.
- A local process. `LocalProcess.swift` and `Pty.swift` are compiled out on Windows
  (`#if !os(Windows)`); they wrap `forkpty`. No ConPTY equivalent exists in SwiftTerm or, as
  far as a search shows, in any published Swift package.
- `HeadlessTerminal`, for the same reason.

### 2.3 Swift on Windows (October 2026)

- Toolchain: Swift 6.4.0 is current and installs with `winget install Swift.Toolchain`. It
  needs Visual Studio 2022 Community or Build Tools with the Windows 11 SDK 22621 and the
  VC++ x64 and ARM64 toolsets, plus Windows Developer Mode for SwiftPM. x64 and arm64 are
  both supported. swift.org formed a Windows workgroup in January 2026.
- This machine has none of that installed (no `swift`, no `cl.exe`, no Windows Kits).
- A built app must ship the Swift runtime DLLs next to the executable.

UI toolkit options, with repository activity checked today:

| Option | State | Fit for Termsie |
| --- | --- | --- |
| Win32 directly (via `WinSDK` module in the toolchain) + Direct2D/DirectWrite | Always available, stable, well documented | Best fit. Termsie needs a custom canvas with floating, overlapping, draggable panes and a GPU text renderer. That is a Win32 window with a D2D/D3D11 swap chain, not a widget tree. |
| `thebrowsercompany/swift-winrt` (WinRT/WinUI 3 projection) | Active (pushed 2026-10-02, v0.1.396 March 2026), but their Windows App SDK and Windows.Foundation binding repos were **archived Oct 2025** | Usable for WinRT APIs; WinUI 3 bindings are now a maintenance risk |
| `stackotter/swift-cross-ui` WinUIBackend | Active (pushed 2026-09-30, 1.7k stars) | Declarative widgets; fine for Settings windows, poor for the pane canvas and terminal view |
| `compnerd/swift-win32` | No code commits since Nov 2024 | Avoid |
| Windows Kit (new projection, forums.swift.org) | Author says "not ready for use" (July 2026) | Watch, do not depend on |

### 2.4 Release pipeline today

`scripts/release.sh` does: version bump → universal build with `lipo` → `.app` assembly →
`codesign` with Developer ID → `hdiutil` dmg → `notarytool` + `stapler` → `gh release create`
→ rewrite the Homebrew cask. `Updater.swift` reads the GitHub releases API, downloads the
`.dmg`, verifies the Developer ID team `44Y68253MG`, and swaps the app after quit. Every one of
those steps has a Windows analogue (below), none of them is reusable verbatim.

### 2.5 Repository situation

This checkout is `mazhar266/termsie`, a fork of `tommihip/termsie` with **zero commits of
divergence** and no tags or releases of its own. Upstream has four releases (0.5.0–0.8.0),
no open issues, and no issue or discussion mentioning Windows or Linux. A Windows port is a
large structural change (package split, new targets, CI); it is worth opening an upstream
issue early so the core split can land there and the Windows front end does not drift.

## 3. Options

**A. Swift port with a shared core (recommended).** Split into `TermsieCore` (Foundation
only), `TermsieMac` (today's app) and `TermsieWindows`. Reuse SwiftTerm's emulator and
portable snapshot API, write a ConPTY host and a Direct2D/DirectWrite view, build the shell in
Win32. Keeps one language, one model, one config format, one test philosophy, and the
"genuinely native, no web view" identity. Risk: the Swift-on-Windows GUI ecosystem is thin, so
most UI is hand-rolled Win32 and the team must be comfortable with that.

**B. Native rewrite in C# / WinUI 3.** Mature ConPTY samples, Win2D for rendering, Credential
Manager, MSIX and winget are all first class. But there is no public .NET VT emulator with
buffer access (Windows Terminal's core is C++ and not consumable; `Microsoft.Terminal.Wpf`
hides the buffer), so the emulator, OSC 133 scanner, copy tools and thumbnails are written
twice. Two codebases diverge from day one.

**C. Cross-platform rewrite (Rust: `alacritty_terminal` + `portable-pty` + wgpu, or
Electron/Tauri + xterm.js).** Fastest route to something on screen, especially the web
stack, but discards 12k lines and contradicts the product's stated reason to exist. Only
worth it if the goal is "Windows and Linux soon" and the macOS app is to be replaced too.

Option A is recommended, with the spike in Phase 0 as the explicit go/no-go. If the spike
fails on toolchain or rendering grounds, Option B is the fallback.

## 4. Plan (Option A)

Effort estimates are for one engineer, calendar weeks, and are deliberately wide.

### Phase 0 — Spike and go/no-go (2–3 weeks)

Goal: a bare Win32 window running `pwsh.exe` through ConPTY, drawn by SwiftTerm's emulator
via Direct2D, with working keyboard input and resize.

1. Set up this machine: VS 2022 components (Windows 11 SDK 22621, VC++ x64 + ARM64), Swift
   6.4 via winget, Developer Mode on.
2. Build SwiftTerm 1.20.0 on Windows (`swift build`) and run its test target. Note anything
   that fails; upstream fixes to SwiftTerm go in here.
3. Write `ConPTYProcess`: `CreatePipe` ×2, `CreatePseudoConsole`, `InitializeProcThreadAttributeList`
   with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`, `CreateProcessW`, overlapped reads on a
   dedicated thread feeding `Terminal.feed`, `ResizePseudoConsole`, exit code via
   `GetExitCodeProcess`. Mirror `LocalProcess`'s delegate shape so `TerminalPane` logic ports.
4. Write a minimal `D2DTerminalRenderer`: DirectWrite glyph runs per row from
   `TerminalRenderSnapshot`, background fills, cursor, dirty-row redraw.
5. Measure: input latency, redraw cost under `yes`, memory.
6. Decide. Document the result in this file.

### Phase 1 — Package split, no behaviour change on macOS (1–2 weeks)

- `Package.swift` → targets `TermsieCore`, `TermsieMac` (executable), `TermsieWindows`
  (executable, `.when(platforms: [.windows])`), and a `TermsieCoreTests` test target.
- Move the Foundation-only files into `TermsieCore`. Strip `NSColor`/`NSFont` out of
  `Config`, `TerminalRegistry`, `OutputSnapshot`, `ThumbnailSource`, `PaneChrome`, `Arrange`
  by introducing `RGBA` and `FontSpec` value types; the macOS target converts at the edge.
- Abstract the three platform services the core calls: `SecretStore` (protocol +
  Keychain impl), `ProcessInspector`, and the config file watcher.
- GitHub Actions: `macos-latest` builds and runs `test-app.sh`; `windows-latest` builds
  `TermsieCore` and its tests. Keep the mac release script working unchanged.

### Phase 2 — Windows terminal view (4–6 weeks)

- Promote the spike renderer: glyph atlas, bold/italic/underline/strikethrough, wide and
  combining characters, true colour, selection highlight, scrollback with a scrollbar,
  find bar, mouse reporting, IME composition (`WM_IME_*`), clipboard.
- Port `TermsieTerminalView` behaviours: input broadcast, "press any key to close",
  selection pinned to buffer lines while output arrives.
- Thumbnails: `ThumbnailRenderer` already draws from the character buffer; re-implement its
  drawing against D2D using the same snapshot.
- Renderer setting gains a Windows value; `metal` / `coregraphics` stay macOS-only.

### Phase 3 — Application shell (6–10 weeks)

- Main window: Win32 top-level with a D3D11/D2D swap chain hosting the pane canvas and the
  sidebar. Floating panes with drag by header, resize from any edge, snapping, z-order,
  tile / cascade / halves (reuse `Arrange`).
- Pane header, environment colouring, badges (reuse `BadgeDrawing` logic, port drawing).
- Sidebar list with thumbnails, cwd and foreground job, resizable with the three collapse
  stages; footer with New Terminal / Run All; copy tools.
- Menus and accelerators: Win32 menu bar, ⌘ → Ctrl, ⌥⌘ → Ctrl+Alt; a conflict pass against
  shell keys (Ctrl+C, Ctrl+D, Ctrl+T are shell input in a terminal; prefer Ctrl+Shift+… like
  Windows Terminal).
- Settings and Workspace Settings windows (form + JSON). Candidate for swift-cross-ui's
  WinUI backend if it saves time; otherwise Win32 dialogs.
- Secrets: Credential Manager (`CredWriteW` / `CredReadW` / `CredDeleteW`) keyed by the same
  opaque refs, so workspace files stay cross-platform.
- Config: `%APPDATA%\termsie\config.json` (honour `XDG_CONFIG_HOME` if set), watched via
  `ReadDirectoryChangesW`.
- Session, workspace documents, legacy migration: unchanged (core).

### Phase 4 — Shell integration (2–3 weeks)

- **PowerShell 7 and Windows PowerShell**: a generated profile the pane passes with
  `-NoExit -Command` (or `-NoProfile` plus a shim that dot-sources the user's real profile,
  mirroring the zsh `ZDOTDIR` trick), emitting OSC 133 A/B/C/D from `prompt` and PSReadLine's
  `CommandValidationHandler`, OSC 7 for cwd, and per-terminal history via
  `Set-PSReadLineOption -HistorySavePath`.
- **cmd.exe**: `histfileOnly`-style minimal mode; no marks.
- **Git Bash / MSYS2**: existing bash shim should work with path translation.
- **WSL**: launch `wsl.exe -d <distro>` with the existing zsh/bash shims written into a
  Linux-side state directory; cwd via OSC 7.
- `ProcessInspector` on Windows: prefer OSC 7 for cwd; foreground job by walking the
  ConPTY process tree (`CreateToolhelp32Snapshot`).
- Port `test-shim.sh` ideas to a `test-shim.ps1`.

### Phase 5 — Release engineering (2–3 weeks)

- `scripts/release-windows.ps1`: version bump (shared `AppInfo.version`), `swift build -c
  release` for x64 and arm64, stage `Termsie.exe` + Swift runtime DLLs + icon + manifest,
  **Authenticode sign** (Azure Trusted Signing, or an OV/EV certificate), produce
  `Termsie-<ver>-win-x64.zip`, `-arm64.zip` and an **MSIX** per arch, SHA-256s, upload to
  the same GitHub release the mac script creates, then open a PR to `microsoft/winget-pkgs`.
- Icon: generate `.ico` from `docs/icon.png` (extend `make-icon.swift` or a PowerShell step).
- `Updater` Windows backend: same GitHub feed, pick the asset for the running arch, verify the
  Authenticode signature and publisher via `WinVerifyTrust` (the analogue of the Developer ID
  team pin), stage, then swap after exit with a small helper process. MSIX installs update via
  `.appinstaller` instead and the in-app updater steps aside, as it does for Homebrew.
- GitHub Actions `windows-latest` job builds unsigned artifacts on every push; signing stays
  on a maintainer machine or a protected workflow with the signing secret.
- README: platform badge, Windows requirements (Windows 10 1809+ for ConPTY; recommend 11),
  install section, keyboard table with Windows shortcuts.

### Phase 6 — Headless tests on Windows (1–2 weeks, overlaps 3–5)

- `DebugDriver` on Windows: `--snapshot` via `PrintWindow` or a swap-chain readback;
  `--actions` unchanged.
- `scripts/test-app.ps1` covering the same list as `test-app.sh` where the feature exists.

## 5. Decisions needed from the maintainer

1. **Go with Option A** (Swift, shared core) and run the Phase 0 spike, or go straight to
   Option B?
2. **Upstream or fork?** Propose the Phase 1 split to `tommihip/termsie` so the core lives in
   one place.
3. **Distribution**: GitHub zip + winget only, or also MSIX / Microsoft Store?
4. **Signing identity**: Azure Trusted Signing (cheapest, needs an Azure tenant) versus a
   purchased certificate.
5. **Minimum Windows version**: 10 1809 (ConPTY minimum) or 11.

## 6. Immediate next steps on this machine

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64"
winget install --id Swift.Toolchain -e --source winget
```

Then enable Developer Mode (Settings ▸ System ▸ For developers), clone SwiftTerm, and run
`swift build` in it. That is the first task of Phase 0.

## 7. Sources

- Swift on Windows install: https://www.swift.org/install/windows/
- Swift 6.4 release coverage: https://www.theregister.com/devops/2026/09/17/swift-64-unifies-building-across-linux-macos-windows/5297006
- Windows Kit projection thread: https://forums.swift.org/t/windows-kit-a-new-swift-projection-for-windows-apis/88363
- swift-winrt: https://github.com/thebrowsercompany/swift-winrt
- swift-cross-ui (WinUIBackend): https://github.com/stackotter/swift-cross-ui
- swift-win32: https://github.com/compnerd/swift-win32
- SwiftTerm: https://github.com/migueldeicaza/SwiftTerm
- ConPTY introduction: https://devblogs.microsoft.com/commandline/windows-command-line-introducing-the-windows-pseudo-console-conpty/
- ConPTY sample: https://github.com/microsoft/terminal/tree/main/samples/ConPTY/EchoCon
