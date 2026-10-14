import Foundation
import Glibc
import SwiftTerm
import TermsieCore

/// A shell in a pseudo-terminal, through SwiftTerm's `LocalProcess` (forkpty).
///
/// The process reads on a private queue, so it never has to wait for GTK's loop, and every
/// delivery hops to the UI thread. `LocalProcess` has its own backpressure: it stops reading
/// while too much output is waiting to be shown.
final class LocalProcessShell: ShellProcess, LocalProcessDelegate {
    private var process: LocalProcess!
    private let queue = DispatchQueue(label: "termsie.pty")
    private let executable: String
    private let arguments: [String]
    private let environment: [String]
    private let directory: String?
    private var cols: Int
    private var rows: Int
    private(set) var isRunning = false
    private var closed = false
    var onData: (([UInt8]) -> Void)?
    var onExit: ((Int32) -> Void)?

    struct SpawnError: Error, CustomStringConvertible {
        let executable: String
        var description: String { "could not start \(executable) (not found or not executable)" }
    }

    init(executable: String, arguments: [String], environment: [String: String], directory: String?, cols: Int, rows: Int) throws {
        guard let path = LocalProcessShell.resolve(executable, environment: environment) else {
            throw SpawnError(executable: executable)
        }
        self.executable = path
        self.arguments = arguments
        self.environment = environment.map { "\($0.key)=\($0.value)" }
        self.directory = directory
        self.cols = cols
        self.rows = rows
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    /// An absolute path, or the first match on PATH.
    private static func resolve(_ executable: String, environment: [String: String]) -> String? {
        let fm = FileManager.default
        if executable.contains("/") {
            return fm.isExecutableFile(atPath: executable) ? executable : nil
        }
        let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(executable)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    var pid: Int { Int(process.shellPid) }
    var ptyFd: Int32 { process.childfd }

    func start() {
        isRunning = true
        // A shell that saw argv[0] start with "-" treats itself as a login shell, which is what
        // `-l` asks for; the shim scripts expect the ordinary name.
        process.startProcess(executable: executable, args: arguments, environment: environment, execName: nil,
                             currentDirectory: directory)
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, !closed else { return }
        process.send(data: bytes[...])
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        guard process.childfd >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    /// Ends the shell the way closing its window does: a hang-up, then a kill for anything still
    /// alive a few seconds later.
    func close() {
        guard !closed else { return }
        closed = true
        let pid = process.shellPid
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        MainQueue.shared.after(4) { [weak self] in
            guard let self, self.isRunning else { return }
            Log.write("shell \(pid) still running after close; ending it")
            kill(pid, SIGKILL)
        }
    }

    // MARK: LocalProcessDelegate (on the private queue)

    func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        MainQueue.shared.async { [weak self] in self?.onData?(bytes) }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainQueue.shared.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.onExit?(exitCode ?? -1)
        }
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
    }
}
