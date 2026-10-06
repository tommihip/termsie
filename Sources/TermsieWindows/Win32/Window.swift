import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// A Swift object behind an HWND. Subclasses override `handle` and return nil for anything they
/// leave to `DefWindowProc`.
///
/// The object keeps itself alive while its window exists: `create` retains it, WM_NCDESTROY
/// releases it, so a window never outlives the code that answers its messages.
class Window {
    private(set) var hwnd: HWND?
    private var selfRetain: Unmanaged<Window>?

    private static var registeredClasses = Set<String>()

    static let procedure: WNDPROC = { hwnd, msg, wParam, lParam in
        if msg == Win.WM_NCCREATE {
            if let cs = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam)), let param = cs.pointee.lpCreateParams {
                SetWindowLongPtrW(hwnd, Win.GWLP_USERDATA, LONG_PTR(Int(bitPattern: param)))
                Unmanaged<Window>.fromOpaque(param).takeUnretainedValue().hwnd = hwnd
            }
        }
        let raw = GetWindowLongPtrW(hwnd, Win.GWLP_USERDATA)
        if raw != 0, let pointer = UnsafeRawPointer(bitPattern: Int(raw)) {
            let window = Unmanaged<Window>.fromOpaque(pointer).takeUnretainedValue()
            if msg == Win.WM_NCDESTROY {
                SetWindowLongPtrW(hwnd, Win.GWLP_USERDATA, 0)
                window.didDestroy()
                window.hwnd = nil
                let retained = window.selfRetain
                window.selfRetain = nil
                retained?.release()
                return DefWindowProcW(hwnd, msg, wParam, lParam)
            }
            if let result = window.handle(msg, wParam, lParam) { return result }
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }

    /// Registers `name` once per process. Double-clicks are delivered; the background is left
    /// alone, since every Termsie window paints all of its client area itself.
    static func registerClass(_ name: String, style: UINT = 0x0008 /* CS_DBLCLKS */, background: HBRUSH? = nil) {
        guard !registeredClasses.contains(name) else { return }
        registeredClasses.insert(name)
        withWide(name) { className in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.style = style
            wc.lpfnWndProc = Window.procedure
            wc.hInstance = GetModuleHandleW(nil)
            wc.hCursor = LoadCursorW(nil, makeIntResource(Win.IDC_ARROW))
            wc.hbrBackground = background
            wc.lpszClassName = className
            wc.hIcon = LoadIconW(GetModuleHandleW(nil), makeIntResource(1))
            if RegisterClassExW(&wc) == 0 {
                Log.write("RegisterClassExW(\(name)) failed: \(GetLastError())")
            }
        }
    }

    @discardableResult
    func create(className: String, title: String, style: DWORD, exStyle: DWORD = 0,
                x: Int32 = Win.CW_USEDEFAULT, y: Int32 = Win.CW_USEDEFAULT,
                width: Int32 = Win.CW_USEDEFAULT, height: Int32 = Win.CW_USEDEFAULT,
                parent: HWND? = nil, menu: HMENU? = nil) -> Bool {
        let retained = Unmanaged.passRetained(self as Window)
        selfRetain = retained
        let handle: HWND? = withWide(className, title) { cls, text in
            CreateWindowExW(exStyle, cls, text, style, x, y, width, height, parent, menu,
                            GetModuleHandleW(nil), retained.toOpaque())
        }
        if handle == nil {
            Log.write("CreateWindowExW(\(className)) failed: \(GetLastError())")
            selfRetain = nil
            retained.release()
            return false
        }
        return true
    }

    /// Answers a message, or returns nil to let Windows' default handling run.
    func handle(_ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? { nil }

    /// The HWND is going away. Release anything tied to it.
    func didDestroy() {}

    func destroy() {
        if let hwnd { DestroyWindow(hwnd) }
    }

    func invalidate() {
        if let hwnd { InvalidateRect(hwnd, nil, false) }
    }

    var title: String {
        get {
            guard let hwnd else { return "" }
            let length = Int(GetWindowTextLengthW(hwnd))
            var buffer = [WCHAR](repeating: 0, count: length + 1)
            GetWindowTextW(hwnd, &buffer, Int32(buffer.count))
            return String(wideBuffer: buffer)
        }
        set {
            guard let hwnd else { return }
            withWide(newValue) { _ = SetWindowTextW(hwnd, $0) }
        }
    }

    /// Client size in physical pixels.
    var clientPixelSize: (width: Int, height: Int) {
        guard let hwnd else { return (0, 0) }
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        return (Int(rc.right - rc.left), Int(rc.bottom - rc.top))
    }

    var dpi: Float {
        guard let hwnd else { return 96 }
        let d = GetDpiForWindow(hwnd)
        return d > 0 ? Float(d) : 96
    }

    /// Device-independent pixels per physical pixel, the inverse of the display scale.
    var scale: Double { Double(dpi) / 96 }

    var isVisible: Bool {
        guard let hwnd else { return false }
        return IsWindowVisible(hwnd) && !IsIconic(hwnd)
    }
}

// MARK: - Main-thread work queue

/// Runs closures on the UI thread from any thread, and after a delay.
///
/// A Win32 message loop does not drain the main dispatch queue the way AppKit's run loop does,
/// so work is handed over as a posted message to a message-only window, and delays are window
/// timers. TermsieCore's `MainScheduler` is pointed here at launch.
final class MainQueue: Window {
    static let shared = MainQueue()

    private static let WM_RUN = Win.WM_APP + 1
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    private var posted = false
    private var timers: [UINT_PTR: () -> Void] = [:]
    private var nextTimer: UINT_PTR = 1000
    let mainThreadID = GetCurrentThreadId()

    func start() {
        Window.registerClass("TermsieMainQueue")
        // HWND_MESSAGE: a window that only exists to receive messages.
        create(className: "TermsieMainQueue", title: "", style: 0, x: 0, y: 0, width: 0, height: 0,
               parent: HWND(bitPattern: -3))
        MainScheduler.hook = { [weak self] delay, work in self?.after(delay, work) }
    }

    var isMainThread: Bool { GetCurrentThreadId() == mainThreadID }

    func async(_ work: @escaping () -> Void) {
        lock.lock()
        pending.append(work)
        let needsPost = !posted
        posted = true
        lock.unlock()
        if needsPost, let hwnd { PostMessageW(hwnd, MainQueue.WM_RUN, 0, 0) }
    }

    /// Runs `work` on the UI thread after `seconds`. Returns a token that `cancel` accepts.
    @discardableResult
    func after(_ seconds: Double, _ work: @escaping () -> Void) -> UINT_PTR {
        guard seconds > 0 else {
            async(work)
            return 0
        }
        guard isMainThread else {
            async { [weak self] in self?.after(seconds, work) }
            return 0
        }
        nextTimer += 1
        let id = nextTimer
        timers[id] = work
        SetTimer(hwnd, id, UINT(max(1, (seconds * 1000).rounded())), nil)
        return id
    }

    func cancel(_ token: UINT_PTR) {
        guard token != 0, timers.removeValue(forKey: token) != nil else { return }
        KillTimer(hwnd, token)
    }

    private func drain() {
        lock.lock()
        let work = pending
        pending.removeAll()
        posted = false
        lock.unlock()
        for item in work { item() }
    }

    override func handle(_ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch msg {
        case MainQueue.WM_RUN:
            drain()
            return 0
        case Win.WM_TIMER:
            let id = UINT_PTR(wParam)
            KillTimer(hwnd, id)
            if let work = timers.removeValue(forKey: id) { work() }
            return 0
        default:
            return nil
        }
    }
}

/// A one-shot, cancellable, re-armable delay on the UI thread: DispatchWorkItem's job.
final class Debouncer {
    private var token: UINT_PTR = 0
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
    private var token: UINT_PTR = 0
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

// MARK: - Message loop

enum MessageLoop {
    /// Dialog windows that want Tab and Enter handled the standard way.
    static var dialogs: [HWND] = []
    /// Asked first with every key message; returning true swallows it.
    static var keyFilter: ((inout MSG) -> Bool)?

    static func run() -> Int32 {
        var msg = MSG()
        while true {
            // Waking at least four times a second lets Foundation's run loop (and the main dispatch
            // queue some libraries post to) make progress even when no window message arrives.
            _ = MsgWaitForMultipleObjectsEx(0, nil, 250, Win.QS_ALLINPUT, Win.MWMO_INPUTAVAILABLE)
            while PeekMessageW(&msg, nil, 0, 0, Win.PM_REMOVE) {
                if msg.message == Win.WM_QUIT { return Int32(truncatingIfNeeded: msg.wParam) }
                if isKeyMessage(msg.message), let filter = keyFilter, filter(&msg) { continue }
                if let dialog = dialogs.first(where: { IsDialogMessageW($0, &msg) }) {
                    _ = dialog
                    continue
                }
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
            _ = RunLoop.main.run(mode: .default, before: Date())
        }
    }

    private static func isKeyMessage(_ m: UINT) -> Bool {
        m == Win.WM_KEYDOWN || m == Win.WM_SYSKEYDOWN || m == Win.WM_CHAR || m == Win.WM_SYSCHAR
            || m == Win.WM_KEYUP || m == Win.WM_SYSKEYUP
    }

    static func quit(_ code: Int32 = 0) {
        PostQuitMessage(code)
    }
}
