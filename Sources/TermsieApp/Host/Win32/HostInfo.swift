import Foundation
import WinSDK
import CTermsieHost
import TermsieCore

/// What the Windows host tells the shared front end about itself.
enum Host {
    static let uiFontFamily = "Segoe UI"
    static var monoFontFamily: String { FontCache.exists("Cascadia Mono") ? "Cascadia Mono" : "Consolas" }
    static let secretStoreName = "the Credential Manager"
    static let shellNote = "Any program works: pwsh, cmd, wsl.exe, Git Bash."
    static let blurNote = "The blurred backdrop needs Windows 11 22H2 or later; elsewhere terminals are opaque."
    static let executableFilter = "*.exe"
    static let shellFolder = "C:\\Windows\\System32"

    /// Diagnostics go to %LOCALAPPDATA%\Termsie\termsie.log.
    static var logDirectory: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base).appendingPathComponent("Termsie", isDirectory: true)
    }

    static var doubleClickInterval: Double { Double(GetDoubleClickTime()) / 1000 }

    static var wheelScrollLines: Int {
        var lines: UINT = 3
        SystemParametersInfoW(0x0068 /* SPI_GETWHEELSCROLLLINES */, 0, &lines, 0)
        return Int(max(1, lines))
    }
}

/// The message loop, started and stopped by the shared `App`.
enum HostApp {
    static func start() {
        MessageLoop.keyFilter = { msg in
            guard let host = Win32WindowHost.forHandle(msg.hwnd) else { return false }
            return host.filterKey(&msg)
        }
    }

    static func run() -> Int32 { MessageLoop.run() }

    static func quit(_ code: Int32) { MessageLoop.quit(code) }
}

/// A shell in a pseudo console.
func spawnShell(executable: String, arguments: [String], environment: [String: String], directory: String?,
                cols: Int, rows: Int) throws -> ShellProcess {
    try ConPty.spawn(executable: executable, arguments: arguments, environment: environment, directory: directory,
                     cols: cols, rows: rows)
}
