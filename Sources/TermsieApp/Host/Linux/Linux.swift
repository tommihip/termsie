import Foundation
import Glibc
import CTermsieHost
import TermsieCore

/// What the Linux host tells the shared front end about itself.
enum Host {
    /// The desktop's interface font, from GTK's settings.
    static let uiFontFamily: String = {
        var buffer = [WCHAR](repeating: 0, count: 256)
        let n = Int(tw_ui_font_family(&buffer, Int32(buffer.count)))
        let name = String(decoding: buffer.prefix(n), as: UTF16.self)
        return name.isEmpty ? "Sans" : name
    }()
    /// fontconfig's alias for the system's monospaced font.
    static let monoFontFamily = "monospace"
    static let secretStoreName = "the keyring (Secret Service)"
    static let shellNote = "Any shell works: bash, zsh, fish."
    static let blurNote = "Terminals are drawn opaque on Linux; blur behind a window is a compositor extension Termsie does not use."
    static let executableFilter = "*"
    static let shellFolder = "/usr/bin"

    /// Diagnostics go to $XDG_STATE_HOME/termsie/termsie.log (~/.local/state/termsie/).
    static var logDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let base = (env["XDG_STATE_HOME"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? (HomePath.home as NSString).appendingPathComponent(".local/state")
        return URL(fileURLWithPath: base).appendingPathComponent("termsie", isDirectory: true)
    }

    // ponytail: GTK's own double-click time and scroll step are not read; these are the defaults.
    static let doubleClickInterval = 0.4
    static let wheelScrollLines = 3
}

/// The GTK main loop, started and stopped by the shared `App`.
enum HostApp {
    static func start() {}
    static func run() -> Int32 { tw_main_run() }
    static func quit(_ code: Int32) { tw_main_quit(code) }
}

/// A shell in a pseudo-terminal, through SwiftTerm's forkpty process.
func spawnShell(executable: String, arguments: [String], environment: [String: String], directory: String?,
                cols: Int, rows: Int) throws -> ShellProcess {
    try LocalProcessShell(executable: executable, arguments: arguments, environment: environment, directory: directory,
                          cols: cols, rows: rows)
}

// MARK: - Main-thread work queue

/// Runs closures on the UI thread from any thread, and after a delay.
///
/// GTK's loop does not drain the main dispatch queue the way AppKit's run loop does, so work is
/// handed over as an idle source, and delays are GLib timeouts. TermsieCore's `MainScheduler` is
/// pointed here at launch, and Foundation's run loop is pumped a few times a second so its
/// timers and URLSession callbacks make progress too.
final class MainQueue {
    static let shared = MainQueue()
    typealias Token = UInt

    private let lock = NSLock()
    private var pending: [() -> Void] = []
    private var posted = false
    private var timers: [Token: () -> Void] = [:]

    func start() {
        MainScheduler.hook = { [weak self] delay, work in self?.after(delay, work) }
        pumpFoundation()
    }

    private func pumpFoundation() {
        after(0.25) { [weak self] in
            _ = RunLoop.main.run(mode: .default, before: Date())
            self?.pumpFoundation()
        }
    }

    var isMainThread: Bool { Thread.isMainThread }

    func async(_ work: @escaping () -> Void) {
        lock.lock()
        pending.append(work)
        let needsPost = !posted
        posted = true
        lock.unlock()
        if needsPost {
            tw_main_post({ ctx in Unmanaged<MainQueue>.fromOpaque(ctx!).takeUnretainedValue().drain() },
                         Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Runs `work` on the UI thread after `seconds`. Returns a token that `cancel` accepts.
    @discardableResult
    func after(_ seconds: Double, _ work: @escaping () -> Void) -> Token {
        guard seconds > 0 else {
            async(work)
            return 0
        }
        guard isMainThread else {
            async { [weak self] in self?.after(seconds, work) }
            return 0
        }
        // The id is only known once the timeout is scheduled; the callback reads it from the
        // box, which is freed by whoever gets there first: the callback or `cancel`.
        let box = UnsafeMutablePointer<Token>.allocate(capacity: 1)
        box.pointee = 0
        let id = Token(tw_main_after(UInt32(max(1, (seconds * 1000).rounded())), { ctx in
            let box = ctx!.assumingMemoryBound(to: Token.self)
            let id = box.pointee
            box.deallocate()
            let queue = MainQueue.shared
            if let work = queue.timers.removeValue(forKey: id) { work() }
        }, box))
        box.pointee = id
        timers[id] = work
        boxes[id] = box
        return id
    }

    private var boxes: [Token: UnsafeMutablePointer<Token>] = [:]

    func cancel(_ token: Token) {
        guard token != 0, timers.removeValue(forKey: token) != nil else { return }
        tw_main_cancel(UInt32(token))
        boxes.removeValue(forKey: token)?.deallocate()
    }

    private func drain() {
        lock.lock()
        let work = pending
        pending.removeAll()
        posted = false
        lock.unlock()
        for item in work { item() }
    }
}

// MARK: - Clipboard, shell, dialogs

enum Clipboard {
    static func set(_ text: String) {
        let units = Array(text.utf16)
        _ = units.withUnsafeBufferPointer { tw_clipboard_set_text(nil, $0.baseAddress, Int32($0.count)) }
    }

    static func get() -> String? {
        guard let raw = tw_clipboard_get_text(nil) else { return nil }
        defer { tw_free(raw) }
        return String(wide: raw)
    }

    /// PRIMARY: what was last selected, which middle-click pastes.
    static func setSelection(_ text: String) {
        let units = Array(text.utf16)
        _ = units.withUnsafeBufferPointer { tw_selection_set_text(nil, $0.baseAddress, Int32($0.count)) }
    }

    static func getSelection() -> String? {
        guard let raw = tw_selection_get_text(nil) else { return nil }
        defer { tw_free(raw) }
        return String(wide: raw)
    }
}

enum Shell {
    static func open(_ target: String) {
        _ = withWide(target) { tw_shell_open($0) }
    }

    static func reveal(folder: String, file: String? = nil) {
        _ = withWide(folder) { f in withOptionalWide(file) { tw_shell_reveal(f, $0) } }
    }

    static func beep() {
        tw_beep()
    }
}

enum Alert {
    enum Response { case first, second, third }

    private enum Buttons: Int32 { case ok = 0, okCancel = 1, yesNoCancel = 3, yesNo = 4 }
    private enum Icon: Int32 { case info = 0, question = 1, warning = 2, error = 3 }

    private static let ok: Int32 = 1, cancel: Int32 = 2, yes: Int32 = 6, no: Int32 = 7

    private static func show(_ title: String, _ message: String, owner: WindowRef?, buttons: Buttons, icon: Icon,
                             defaultSecond: Bool = false) -> Int32 {
        // A scripted run has nobody to answer: say what was asked and take the first button,
        // which for every question here is the one that goes ahead.
        if DebugDriver.isActive {
            let oneLine = message.split(whereSeparator: \.isNewline).joined(separator: " ")
            DebugOutput.print("alert: \(title) — \(oneLine)")
            switch buttons {
            case .okCancel: return ok
            case .yesNoCancel, .yesNo: return yes
            default: return ok
            }
        }
        return withWide(title, message) { t, m in tw_alert(owner, t, m, buttons.rawValue, icon.rawValue, defaultSecond ? 1 : 0) }
    }

    static func info(_ title: String, _ message: String, owner: WindowRef?) {
        _ = show(title, message, owner: owner, buttons: .ok, icon: .info)
    }

    static func error(_ title: String, _ message: String, owner: WindowRef?) {
        _ = show(title, message, owner: owner, buttons: .ok, icon: .error)
    }

    /// OK / Cancel. True for OK.
    static func confirm(_ title: String, _ message: String, owner: WindowRef?, warning: Bool = false) -> Bool {
        show(title, message, owner: owner, buttons: .okCancel, icon: warning ? .warning : .question) == ok
    }

    /// Yes / No / Cancel, as `.first`, `.second`, `.third`.
    static func yesNoCancel(_ title: String, _ message: String, owner: WindowRef?) -> Response {
        switch show(title, message, owner: owner, buttons: .yesNoCancel, icon: .question) {
        case yes: return .first
        case no: return .second
        default: return .third
        }
    }

    /// Yes / No. True for Yes.
    static func yesNo(_ title: String, _ message: String, owner: WindowRef?, defaultNo: Bool = false) -> Bool {
        show(title, message, owner: owner, buttons: .yesNo, icon: .question, defaultSecond: defaultNo) == yes
    }
}

enum FileDialog {
    static func open(owner: WindowRef?, title: String, filterName: String = "JSON files", filterSpec: String = "*.json",
                     folder: String? = nil) -> String? {
        run(owner: owner, save: false, pickFolder: false, title: title, filterName: filterName, filterSpec: filterSpec,
            defaultName: nil, defaultExtension: nil, folder: folder)
    }

    static func save(owner: WindowRef?, title: String, defaultName: String, filterName: String = "JSON files",
                     filterSpec: String = "*.json", defaultExtension: String = "json", folder: String? = nil) -> String? {
        run(owner: owner, save: true, pickFolder: false, title: title, filterName: filterName, filterSpec: filterSpec,
            defaultName: defaultName, defaultExtension: defaultExtension, folder: folder)
    }

    static func folder(owner: WindowRef?, title: String, start: String? = nil) -> String? {
        run(owner: owner, save: false, pickFolder: true, title: title, filterName: nil, filterSpec: nil,
            defaultName: nil, defaultExtension: nil, folder: start)
    }

    private static func run(owner: WindowRef?, save: Bool, pickFolder: Bool, title: String, filterName: String?,
                            filterSpec: String?, defaultName: String?, defaultExtension: String?, folder: String?) -> String? {
        var out = [WCHAR](repeating: 0, count: 4096)
        let ok: Int32 = withWide(title) { t in
            withOptionalWide(filterName) { fn in
                withOptionalWide(filterSpec) { fs in
                    withOptionalWide(defaultName) { dn in
                        withOptionalWide(defaultExtension) { de in
                            withOptionalWide(folder) { f in
                                tw_file_dialog(owner, save ? 1 : 0, pickFolder ? 1 : 0, t, fn, fs, dn, de, f, &out,
                                               Int32(out.count))
                            }
                        }
                    }
                }
            }
        }
        return ok != 0 ? String(wideBuffer: out) : nil
    }
}
