import Foundation
import CTermsieHost
import TermsieCore

// What the shared front end asks of the platform underneath it. Each host (Host/Win32,
// Host/Linux) supplies the types declared here; everything outside Host/ is the same code on
// both.

/// A native window, as the opaque pointer the C layer and the dialogs take for an owner.
typealias WindowRef = UnsafeMutableRawPointer

/// A UTF-16 unit, the type the C contract speaks on every platform (WinSDK's WCHAR is the same
/// type, which this shadows harmlessly).
typealias WCHAR = UInt16

/// The window a `MainWindow` draws into and receives events from.
protocol HostWindow: AnyObject {
    /// For dialogs and alerts.
    var ref: WindowRef? { get }
    /// What `tw_renderer_create` takes.
    var renderTarget: UnsafeMutableRawPointer? { get }
    /// Client size in physical pixels.
    var clientPixelSize: (width: Int, height: Int) { get }
    var dpi: Float { get }
    /// Device-independent pixels per physical pixel, the inverse of the display scale.
    var scale: Double { get }
    var isVisible: Bool { get }
    var isFocused: Bool { get }
    var isFullScreen: Bool { get }
    var title: String { get set }
    /// The window's placement for the session, in screen pixels where the platform has them.
    var frame: [Double] { get }

    /// Creates the native window. `frame` is a saved placement, which a platform may ignore.
    func open(frame: [Double]?) -> Bool
    func show(activate: Bool)
    func destroy()
    /// Dark chrome, icon, and the blurred backdrop where there is one. Returns whether
    /// translucent pixels will show a backdrop.
    func applyChrome() -> Bool
    /// Draws a frame now or as soon as the platform allows.
    func requestPaint()
    func toggleFullScreen()
    /// Keeps mouse events coming while a button is held, even outside the window.
    func setCapture()
    func releaseCapture()
    /// Where composed text appears, in client pixels.
    func setIMEPosition(x: Int, y: Int, lineHeight: Int)
}

/// Modifier keys held during an event.
struct Modifiers: OptionSet, Hashable {
    let rawValue: Int
    static let shift = Modifiers(rawValue: 1)
    static let alt = Modifiers(rawValue: 2)
    static let control = Modifiers(rawValue: 4)

    /// The xterm modifier parameter: 1 + shift + 2·alt + 4·ctrl.
    var xtermParameter: Int { 1 + rawValue }
}

/// A key as the shortcut table and the terminal encoder see it, independent of the platform's
/// key codes. `char` is the key's unshifted meaning on a US layout, upper-cased: letters,
/// digits and the punctuation keys, which is what both Win32 virtual keys and GDK's unshifted
/// keyvals give.
enum Key: Hashable {
    case up, down, left, right, home, end, pageUp, pageDown, insert, delete
    case backspace, enter, escape, tab, space
    case f(Int)
    case char(Character)

    static func letter(_ s: String) -> Key { .char(Character(s.uppercased())) }

    var name: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "PgUp"
        case .pageDown: return "PgDn"
        case .insert: return "Ins"
        case .delete: return "Del"
        case .backspace: return "Backspace"
        case .enter: return "Enter"
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .space: return "Space"
        case .f(let n): return "F\(n)"
        case .char(let c): return String(c)
        }
    }
}

/// The shapes the pointer takes over the window.
enum CursorShape: Int {
    case arrow, ibeam, hand, sizeWE, sizeNS, sizeNWSE, sizeNESW, sizeAll, wait
}

extension ChromeZone {
    var cursorShape: CursorShape {
        switch self {
        case .move: return .sizeAll
        case .left, .right: return .sizeWE
        case .top, .bottom: return .sizeNS
        case .topLeft, .bottomRight: return .sizeNWSE
        case .topRight, .bottomLeft: return .sizeNESW
        }
    }
}

// MARK: - Strings across the C boundary

extension String {
    /// NUL-terminated UTF-16, for APIs that keep the pointer only for the call.
    var wide: [WCHAR] { Array(utf16) + [0] }

    init(wide pointer: UnsafePointer<WCHAR>?) {
        guard let pointer else { self = ""; return }
        var length = 0
        while pointer[length] != 0 { length += 1 }
        self = String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF16.self)
    }

    init(wideBuffer buffer: [WCHAR], count: Int? = nil) {
        let n = count ?? (buffer.firstIndex(of: 0) ?? buffer.count)
        self = String(decoding: buffer.prefix(n), as: UTF16.self)
    }
}

/// Calls `body` with a NUL-terminated UTF-16 copy of each string.
func withWide<R>(_ s: String, _ body: (UnsafePointer<WCHAR>) throws -> R) rethrows -> R {
    try s.withCString(encodedAs: UTF16.self) { try body($0) }
}

func withWide<R>(_ a: String, _ b: String, _ body: (UnsafePointer<WCHAR>, UnsafePointer<WCHAR>) throws -> R) rethrows -> R {
    try withWide(a) { pa in try withWide(b) { pb in try body(pa, pb) } }
}

func withOptionalWide<R>(_ s: String?, _ body: (UnsafePointer<WCHAR>?) throws -> R) rethrows -> R {
    guard let s else { return try body(nil) }
    return try withWide(s) { try body($0) }
}

/// A list of strings as the C layer takes it: NUL-separated, double-NUL terminated.
func wideList(_ items: [String]) -> [WCHAR] {
    var out: [WCHAR] = []
    for item in items {
        out.append(contentsOf: item.utf16)
        out.append(0)
    }
    out.append(0)
    return out
}

extension TWColor {
    init(_ c: RGBA, alpha: Double? = nil) {
        self.init(r: Float(c.r), g: Float(c.g), b: Float(c.b), a: Float(alpha ?? c.a))
    }

    init(hex: String, alpha: Double? = nil) {
        self.init(RGBA.hex(hex), alpha: alpha)
    }

    static let clear = TWColor(r: 0, g: 0, b: 0, a: 0)
    static let black = TWColor(r: 0, g: 0, b: 0, a: 1)
    static let white = TWColor(r: 1, g: 1, b: 1, a: 1)

    func withAlpha(_ a: Float) -> TWColor { TWColor(r: r, g: g, b: b, a: a) }
}

// MARK: - Monotonic time

enum Clock {
    /// Seconds since an arbitrary point, monotonic: CACurrentMediaTime's role on macOS.
    static var now: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

// MARK: - Main-thread timers

/// A one-shot, cancellable, re-armable delay on the UI thread: DispatchWorkItem's job.
final class Debouncer {
    private var token: MainQueue.Token = 0
    private var generation = 0

    func schedule(after seconds: Double, _ work: @escaping () -> Void) {
        cancel()
        generation += 1
        let mine = generation
        token = MainQueue.shared.after(seconds) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.token = 0
            work()
        }
    }

    func cancel() {
        generation += 1
        MainQueue.shared.cancel(token)
        token = 0
    }

    var isScheduled: Bool { token != 0 }
}

/// A repeating timer on the UI thread.
final class RepeatingTimer {
    private var token: MainQueue.Token = 0
    private let interval: Double
    private let work: () -> Void
    private var running = false

    init(interval: Double, _ work: @escaping () -> Void) {
        self.interval = interval
        self.work = work
    }

    func start() {
        guard !running else { return }
        running = true
        arm()
    }

    func stop() {
        running = false
        MainQueue.shared.cancel(token)
        token = 0
    }

    private func arm() {
        token = MainQueue.shared.after(interval) { [weak self] in
            guard let self, self.running else { return }
            self.work()
            self.arm()
        }
    }

    deinit { stop() }
}

// MARK: - Logging

/// Diagnostics go to a file, because a GUI process has no console.
enum Log {
    private static let lock = NSLock()
    private static var handle: FileHandle? = {
        let dir = Host.logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("termsie.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.intValue > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        handle?.write(Data(line.utf8))
        if let stream = DebugOutput.stream { stream.write(Data(line.utf8)) }
    }
}

/// Where scripted runs print their results: a file named by `--log`, since a GUI-subsystem
/// process's standard output goes nowhere unless it was redirected.
enum DebugOutput {
    static var stream: FileHandle?

    static func open(path: String) {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        stream = FileHandle(forWritingAtPath: path)
    }

    static func print(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let stream { stream.write(data) } else { FileHandle.standardOutput.write(data) }
    }
}

// MARK: - Command lines as text

/// Quoting and splitting of a command line written as one string, the way the Windows C
/// runtime (and `CommandLineToArgvW`) reads it: whitespace separates, quotes group, backslashes
/// escape a quote. The settings dialog's "shell arguments" field uses it on every platform.
enum CommandLineText {
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

    static func split(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var hasArg = false
        var backslashes = 0
        for ch in s {
            if ch == "\\" {
                backslashes += 1
                continue
            }
            if ch == "\"" {
                current += String(repeating: "\\", count: backslashes / 2)
                if backslashes % 2 == 1 {
                    current.append("\"")
                } else {
                    inQuotes.toggle()
                }
                backslashes = 0
                hasArg = true
                continue
            }
            current += String(repeating: "\\", count: backslashes)
            backslashes = 0
            if (ch == " " || ch == "\t") && !inQuotes {
                if hasArg || !current.isEmpty { args.append(current) }
                current = ""
                hasArg = false
            } else {
                current.append(ch)
                hasArg = true
            }
        }
        current += String(repeating: "\\", count: backslashes)
        if hasArg || !current.isEmpty { args.append(current) }
        return args
    }
}

// MARK: - Menus

/// A popup menu built through the C layer: the same calls make an HMENU and a GtkPopoverMenu.
final class NativeMenu {
    let handle: TWMenuHandle?
    private var owned = true

    init() { handle = tw_menu_create() }

    deinit { if owned, let handle { tw_menu_destroy(handle) } }

    func append(id: Int32, title: String, enabled: Bool = true, checked: Bool = false) {
        withWide(title) { tw_menu_append(handle, id, $0, enabled ? 1 : 0, checked ? 1 : 0) }
    }

    func appendSeparator() { tw_menu_append_separator(handle) }

    /// Hands `submenu` to this menu, which frees it.
    func append(submenu: NativeMenu, title: String) {
        submenu.owned = false
        withWide(title) { tw_menu_append_submenu(handle, $0, submenu.handle) }
    }

    /// Shows the menu at a point in the window's client pixels and returns the chosen id, 0
    /// for none.
    func track(in window: WindowRef?, x: Int, y: Int) -> Int32 {
        tw_track_menu(window, handle, Int32(x), Int32(y))
    }
}

// MARK: - Shell processes

/// The pseudo-terminal under a terminal: a pseudo console on Windows, a forkpty process on
/// Linux. Both deliver output and the exit on the UI thread.
protocol ShellProcess: AnyObject {
    var pid: Int { get }
    /// The pty master, for the foreground process group; -1 where there is none.
    var ptyFd: Int32 { get }
    var isRunning: Bool { get }
    /// Called on the UI thread with each batch of output.
    var onData: (([UInt8]) -> Void)? { get set }
    /// Called on the UI thread once, after the last output, with the process's exit code.
    var onExit: ((Int32) -> Void)? { get set }
    func start()
    func write(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    /// Ends the shell the way closing its window does, and everything it started a little later.
    func close()
}
