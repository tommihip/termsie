import Foundation
import WinSDK
import CTermsieWin

/// A shell running in a Windows pseudo console.
///
/// Output is read on a background thread into an inbox the UI thread empties; when the UI falls
/// behind (`yes`, `cat` of a large file) the reader waits rather than letting the inbox grow
/// without bound, which is the same backpressure a Unix pty gives by filling its kernel buffer.
///
/// The child exiting does not end the output stream by itself: the pseudo console outlives its
/// clients. A watcher thread waits for the process, closes the console, and the reader then sees
/// the end of the stream after the last bytes, so the exit is reported only once everything the
/// shell printed has been shown.
final class ConPty {
    struct SpawnError: Error, CustomStringConvertible {
        let code: DWORD
        let commandLine: String
        var description: String {
            "could not start \(commandLine) (\(ConPty.describe(code)))"
        }
    }

    private let handle: OpaquePointer
    let pid: DWORD
    /// Called on the UI thread with each batch of output.
    var onData: (([UInt8]) -> Void)?
    /// Called on the UI thread once, after the last output, with the process's exit code.
    var onExit: ((DWORD) -> Void)?

    private let inboxLock = NSCondition()
    private var inbox: [UInt8] = []
    private var deliveryPosted = false
    private static let inboxLimit = 4 << 20

    private let writeLock = NSLock()
    private var closed = false
    private var exitCode: DWORD?
    private var streamEnded = false
    private var exitReported = false
    private var freed = false
    /// A close started by `close()` runs on its own thread; the handle is freed only after it.
    private var closeInFlight = false

    private init(handle: OpaquePointer) {
        self.handle = handle
        pid = tw_pty_pid(handle)
    }

    static func spawn(executable: String, arguments: [String], environment: [String: String],
                      directory: String?, cols: Int, rows: Int) throws -> ConPty {
        let commandLine = WindowsCommandLine.build(executable: executable, arguments: arguments)
        let block = EnvironmentBlock.build(environment)
        var error: DWORD = 0
        let pty: OpaquePointer? = withWide(commandLine) { cmd in
            withOptionalWide(directory) { cwd in
                block.withUnsafeBufferPointer { env in
                    tw_pty_spawn(cmd, cwd, env.baseAddress, Int16(clamping: cols), Int16(clamping: rows), &error)
                }
            }
        }
        guard let pty else { throw SpawnError(code: error, commandLine: commandLine) }
        return ConPty(handle: pty)
    }

    func start() {
        let reader = Thread { [self] in readLoop() }
        reader.name = "Termsie pty reader \(pid)"
        reader.stackSize = 1 << 20
        reader.start()
        let watcher = Thread { [self] in watchLoop() }
        watcher.name = "Termsie pty watcher \(pid)"
        watcher.stackSize = 256 << 10
        watcher.start()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = buffer.withUnsafeMutableBytes { tw_pty_read(handle, $0.baseAddress, DWORD($0.count)) }
            if n <= 0 { break }
            inboxLock.lock()
            while inbox.count > ConPty.inboxLimit && !closed { inboxLock.wait() }
            inbox.append(contentsOf: buffer[0..<Int(n)])
            let post = !deliveryPosted
            deliveryPosted = true
            inboxLock.unlock()
            if post { MainQueue.shared.async { [weak self] in self?.deliver() } }
        }
        MainQueue.shared.async { [self] in
            deliver()
            streamEnded = true
            finishIfDone()
        }
    }

    private func watchLoop() {
        var code: DWORD = 0
        _ = tw_pty_wait(handle, Win.INFINITE, &code)
        // The shell is gone; closing the console flushes what it wrote and ends the stream.
        writeLock.lock()
        closed = true
        writeLock.unlock()
        inboxLock.lock()
        inboxLock.broadcast()
        inboxLock.unlock()
        tw_pty_close(handle)
        MainQueue.shared.async { [self] in
            exitCode = code
            finishIfDone()
        }
    }

    private func deliver() {
        inboxLock.lock()
        let bytes = inbox
        inbox.removeAll(keepingCapacity: true)
        deliveryPosted = false
        inboxLock.broadcast()
        inboxLock.unlock()
        if !bytes.isEmpty { onData?(bytes) }
    }

    private func finishIfDone() {
        guard streamEnded, let code = exitCode, !exitReported else { return }
        exitReported = true
        onExit?(code)
        freeIfIdle()
    }

    private func freeIfIdle() {
        guard exitReported, !closeInFlight, !freed else { return }
        freed = true
        tw_pty_free(handle)
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        _ = bytes.withUnsafeBytes { tw_pty_write(handle, $0.baseAddress, DWORD($0.count)) }
    }

    func write<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        write(Array(bytes))
    }

    func resize(cols: Int, rows: Int) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        tw_pty_resize(handle, Int16(clamping: cols), Int16(clamping: rows))
    }

    var isRunning: Bool { exitCode == nil && !closed }

    /// Ends the shell the way closing a console window does: every program attached to it is
    /// told to close, and anything still alive a few seconds later is ended.
    func close() {
        writeLock.lock()
        let wasClosed = closed
        closed = true
        writeLock.unlock()
        guard !wasClosed else { return }
        let h = handle
        closeInFlight = true
        Thread.detachNewThread { [self] in
            tw_pty_close(h)
            MainQueue.shared.async { [self] in
                closeInFlight = false
                freeIfIdle()
            }
        }
        let pid = self.pid
        MainQueue.shared.after(4) { [weak self] in
            guard let self, self.exitCode == nil, !self.freed else { return }
            Log.write("shell \(pid) still running after close; ending it")
            tw_pty_terminate(self.handle)
        }
    }

    static func describe(_ code: DWORD) -> String {
        switch code {
        case 2: return "file not found"
        case 3: return "folder not found"
        case 5: return "access denied"
        case 267: return "not a folder"
        case 50: return "pseudo consoles need Windows 10 version 1809 or later"
        default: return "error \(code)"
        }
    }
}

/// Windows command lines are one string the child splits itself; this produces the quoting
/// `CommandLineToArgvW` and the C runtime undo.
enum WindowsCommandLine {
    static func build(executable: String, arguments: [String]) -> String {
        ([quote(executable)] + arguments.map(quote)).joined(separator: " ")
    }

    static func quote(_ arg: String) -> String {
        if !arg.isEmpty && !arg.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\u{0B}" || $0 == "\"" }) {
            return arg
        }
        var out = "\""
        var backslashes = 0
        for ch in arg {
            if ch == "\\" {
                backslashes += 1
                continue
            }
            if ch == "\"" {
                out += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
            } else {
                out += String(repeating: "\\", count: backslashes)
                out.append(ch)
            }
            backslashes = 0
        }
        out += String(repeating: "\\", count: backslashes * 2) + "\""
        return out
    }
}

/// The environment a child is created with: `NAME=value` strings, NUL-separated, double-NUL
/// terminated, sorted the way Windows sorts them. Names are case-insensitive on Windows, so a
/// later `Path` replaces an earlier `PATH` instead of standing beside it.
enum EnvironmentBlock {
    static func build(_ env: [String: String]) -> [WCHAR] {
        var byKey: [String: (String, String)] = [:]
        for (name, value) in env where !name.isEmpty {
            byKey[name.uppercased()] = (name, value)
        }
        let sorted = byKey.sorted { $0.key < $1.key }.map(\.value)
        var block: [WCHAR] = []
        for (name, value) in sorted {
            block.append(contentsOf: "\(name)=\(value)".utf16)
            block.append(0)
        }
        block.append(0)
        if sorted.isEmpty { block.append(0) }
        return block
    }

    /// Looks up a name the way Windows does, ignoring case.
    static func value(_ name: String, in env: [String: String]) -> String? {
        if let v = env[name] { return v }
        let upper = name.uppercased()
        return env.first { $0.key.uppercased() == upper }?.value
    }
}
