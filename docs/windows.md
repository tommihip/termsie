# Termsie on Windows

Termsie runs on Windows 10 (version 1903 or later) and Windows 11, on x64 and ARM64. It is the
same app as on macOS: floating terminals in one window, the live terminal list, environments,
saved terminals and workspaces, per-terminal history, the copy tools and kept output. The
workspace and session files are the same format on both, so a workspace saved on a Mac opens on
Windows and the other way round.

## Install

- **Zip:** download `Termsie-<version>-windows-x64.zip` (or `-arm64`) from the
  [releases page](https://github.com/tommihip/termsie/releases), unpack it anywhere, and run
  `Termsie.exe`. Everything it needs is in the folder; nothing else is installed.
- **winget:** `winget install Termsie.Termsie`
- **MSIX:** `Termsie-<version>-windows-x64.msix` installs Termsie as a package, with a Start menu
  entry and a `termsie` command. Windows keeps a packaged copy up to date itself.

A zip copy updates itself: Termsie checks for a new release once a day, asks before installing,
and refuses any download that is not signed by the same publisher as the copy that is running.

## Shells

Termsie opens **PowerShell 7** (`pwsh`) when it is installed and **Windows PowerShell**
otherwise. Set `"shell"` in config.json, or Shell in Settings, to use another:

| Shell | `shell` | What Termsie adds |
| --- | --- | --- |
| PowerShell 7 / Windows PowerShell | `pwsh.exe` / `powershell.exe` | Own history per terminal, startup commands run before the first prompt, working folder in the header, command marks for the copy tools |
| Command Prompt | `cmd.exe` | Startup commands are typed in once the prompt appears |
| Git Bash | `C:\Program Files\Git\bin\bash.exe` with `"shellArgs": ["--login", "-i"]` | Own history, startup commands, prompt marks (the bash integration from macOS) |
| WSL | `wsl.exe`, optionally `"shellArgs": ["-d", "Ubuntu"]` | Environment variables reach the Linux shell through `WSLENV`; startup commands are typed in |

PowerShell's integration is a script Termsie generates (it never edits your profile). It runs
right after your profile through `-NoExit -Command`, loaded as a script block, so it works even
under Windows PowerShell's default execution policy, which blocks script files.

## Keyboard

macOS's ⌘ becomes **Ctrl+Shift**, as in Windows Terminal, so every plain Ctrl+letter still
reaches the shell: Ctrl+C interrupts, Ctrl+R searches history, Ctrl+D ends input. Where a Mac
shortcut uses two modifiers, Windows adds Alt.

| Action | Shortcut |
| --- | --- |
| New window / new tab | Ctrl+Shift+N / Ctrl+Shift+T |
| Next / previous tab | Ctrl+Tab / Ctrl+Shift+Tab, or Ctrl+PgDn / Ctrl+PgUp |
| New terminal | Ctrl+Shift+D |
| New terminal, then tile everything | Ctrl+Alt+Shift+D |
| Terminal settings | Ctrl+Shift+I |
| Workspace settings | Ctrl+Shift+, |
| Settings | Ctrl+, |
| Set terminal name | Ctrl+Shift+R |
| Close terminal / delete terminal | Ctrl+Shift+W / Ctrl+Shift+Del |
| Toggle the terminal list | Ctrl+Shift+B |
| Maximize terminal | Ctrl+Shift+Enter |
| Tile grid / cascade | Ctrl+Shift+G / Ctrl+Shift+\ |
| Throw terminal to a half | Ctrl+Alt+Shift+← → ↑ ↓ |
| Focus terminal left / right / up / down | Alt+← → ↑ ↓ |
| Next / previous terminal | Ctrl+Shift+] / Ctrl+Shift+[ |
| Jump to terminal 1–9 | Ctrl+Shift+1 … Ctrl+Shift+9 |
| Toggle terminal headers | Ctrl+Shift+H |
| Broadcast input to all terminals | Ctrl+Alt+Shift+I |
| Clear scrollback | Ctrl+Shift+K |
| Copy | Ctrl+Shift+C, or Ctrl+C while text is selected |
| Paste | Ctrl+Shift+V, Shift+Insert, or middle-click |
| Copy last command output | Ctrl+Alt+Shift+C |
| Copy last command | Ctrl+Alt+Shift+L |
| Copy whole terminal | Ctrl+Alt+Shift+A |
| Find / next / previous | Ctrl+Shift+F / F3 / Shift+F3 |
| Bigger / smaller / default text | Ctrl+= / Ctrl+- / Ctrl+0, or Ctrl+mouse wheel |
| Scroll back a page / forward a page | Shift+PgUp / Shift+PgDn |
| Save workspace / save as | Ctrl+Shift+S / Ctrl+Alt+Shift+S |
| Open workspace file | Ctrl+Shift+O |
| Full screen | F11 |

The menu behind the ☰ button at the top left has every command. Alt+key sends Esc then the key,
the convention terminal programs expect for Meta; Alt alone does not open a menu, so it never
takes the keyboard away from the shell. Ctrl+Alt+drag anywhere in a terminal moves it, which is
how you move one with headers hidden; holding Ctrl while resizing turns snapping off.

## Where things are kept

| What | Where |
| --- | --- |
| Settings | `%APPDATA%\termsie\config.json` (`$XDG_CONFIG_HOME\termsie` when that is set) |
| Workspaces | `%APPDATA%\termsie\workspaces\` |
| Last session | `%APPDATA%\termsie\session.json` |
| Per-terminal history and kept output | `%APPDATA%\termsie\panes\<terminal id>\` |
| Secret values | Windows Credential Manager, under `Termsie/com.termsie.app.env/…` |
| Diagnostics | `%LOCALAPPDATA%\Termsie\termsie.log` |

A generic credential holds up to 2,560 bytes, so a secret longer than that is refused with a
message rather than cut short.

## Translucency

With **Translucent** on (`blurBackground`, on by default), Windows 11 22H2 and later show the
acrylic backdrop behind the terminals at the configured opacity. Elsewhere terminals are drawn
opaque.

## Building from source

1. Install Visual Studio 2022 (Community or Build Tools) with the Windows 11 SDK and the C++
   tools for x64 (and ARM64 to build for ARM), and the Swift toolchain, as described at
   [swift.org/install/windows](https://www.swift.org/install/windows/):

   ```powershell
   winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64"
   winget install --id Swift.Toolchain -e --source winget
   ```

   Then turn on Developer Mode (Settings ▸ System ▸ For developers), which SwiftPM needs.

2. Build and stage a runnable folder in `dist\windows\x64\Termsie`:

   ```powershell
   ./scripts/build-windows.ps1
   ```

   It sets the `SWIFTTERM_BUILD_*` variables first (see `scripts/swiftterm-build-info.ps1`):
   SwiftTerm's build plugin otherwise crashes on Windows. For a plain `swift build`, dot-source
   that script in the same shell first.

3. Test:

   ```powershell
   swift test                      # the shared core
   ./scripts/test-windows.ps1      # the app, driven headlessly
   ```

`test-windows.ps1` starts the real app against throwaway config folders and checks the shell,
terminal lifecycle, layout, startup commands, environment variables and secrets, the copy tools,
kept output and session restore, history isolation, cmd's typed commands, the workspace JSON,
the list's width stages and thumbnail cost. Screenshots and logs go to `test-output\`.

## Releasing

`scripts/release-windows.ps1` builds each architecture with the current ConPTY bundled, signs
every binary with Authenticode, packs the zip and the MSIX, writes checksums, and with
`-Publish` uploads them to the GitHub release and writes winget manifests:

```powershell
./scripts/release-windows.ps1 -Version 0.9.0 -Arch x64,arm64 -CertificateThumbprint <sha1> -Publish
```

Signing takes either a certificate in the certificate store (`-CertificateThumbprint`) or Azure
Trusted Signing (`-TrustedSigning metadata.json`). `-SkipSign` makes an unsigned dry run; an
unsigned copy never updates itself.

ARM64 packages have to be built on an ARM64 machine: the x64 Swift toolchain can cross-compile
Termsie for ARM64 but carries no ARM64 runtime to ship with it. The **Windows release** workflow
(Actions ▸ Windows release ▸ Run workflow) does this for you: it builds, signs, packages and
tests each architecture on a runner of its own kind, then publishes both in one step when
"publish" is ticked. It signs with Azure Trusted Signing when the secrets listed at the top of
`.github/workflows/release-windows.yml` are set.

## How the Windows app is built

- **TermsieCore** is shared with macOS: the model, workspaces and sessions, config, shell
  integration (including the PowerShell script), command marks, text capture and kept output.
- **CTermsieWin** is a small C++ layer for what is awkward from Swift: Direct2D and DirectWrite
  on a DirectComposition swap chain (which is what lets the backdrop show through), the pseudo
  console, the Credential Manager, process listing, the clipboard, file dialogs, hashing and
  signature checks.
- **TermsieWindows** is the app: one Win32 window per Termsie window, drawn in a single Direct2D
  pass, with SwiftTerm as the emulator. Terminal text is drawn as DirectWrite glyph runs with every
  advance pinned to the cell grid; characters the font lacks fall back through DirectWrite.

The pseudo console prefers a `conpty.dll` shipped next to the executable (the release bundles
Microsoft's current one, the same Windows Terminal uses) over the copy in Windows, whose older
versions mishandle some sequences.
