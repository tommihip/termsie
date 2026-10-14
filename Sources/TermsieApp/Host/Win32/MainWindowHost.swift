import Foundation
import WinSDK
import CTermsieHost
import TermsieCore

/// The HWND under a `MainWindow`: turns window messages into the controller's calls, and does
/// the few things only Win32 can (showing, full screen, capture, the input method's position).
final class Win32WindowHost: Window, HostWindow {
    unowned let controller: MainWindow
    private var assembler = SurrogateAssembler()
    private var isFullScreenNow = false
    private var savedPlacement = WINDOWPLACEMENT()
    private var savedStyle: LONG_PTR = 0
    private var trackingMouse = false

    private static var all: [ObjectIdentifier: Win32WindowHost] = [:]

    init(controller: MainWindow) {
        self.controller = controller
        super.init()
    }

    /// The host whose window (or child window) is `h`, for routing key messages.
    static func forHandle(_ h: HWND?) -> Win32WindowHost? {
        guard var h else { return nil }
        while true {
            if let w = all.values.first(where: { $0.hwnd == h }) { return w }
            guard let parent = GetParent(h) else { return nil }
            h = parent
        }
    }

    // MARK: HostWindow

    var ref: WindowRef? { raw(hwnd) }
    var renderTarget: UnsafeMutableRawPointer? { raw(hwnd) }
    var isFocused: Bool { hwnd != nil && GetForegroundWindow() == hwnd }
    var isFullScreen: Bool { isFullScreenNow }

    func open(frame: [Double]?) -> Bool {
        Window.registerClass("TermsieWindow")
        var x = Win.CW_USEDEFAULT, y = Win.CW_USEDEFAULT, w: Int32 = 1280, h: Int32 = 820
        if let f = frame, f.count == 4, f[2] >= 400, f[3] >= 300 {
            x = Int32(f[0]); y = Int32(f[1]); w = Int32(f[2]); h = Int32(f[3])
        }
        guard create(className: "TermsieWindow", title: AppInfo.name,
                     style: Win.WS_OVERLAPPEDWINDOW | Win.WS_CLIPCHILDREN,
                     exStyle: Win.WS_EX_NOREDIRECTIONBITMAP | Win.WS_EX_APPWINDOW,
                     x: x, y: y, width: w, height: h) else { return false }
        Win32WindowHost.all[ObjectIdentifier(self)] = self
        if frame != nil { ensureOnScreen() }
        return true
    }

    private func ensureOnScreen() {
        guard let hwnd else { return }
        var rc = RECT()
        GetWindowRect(hwnd, &rc)
        let monitor = MonitorFromRect(&rc, DWORD(MONITOR_DEFAULTTONULL))
        if monitor == nil {
            SetWindowPos(hwnd, nil, 80, 80, 0, 0, Win.SWP_NOSIZE | Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
        }
    }

    func applyChrome() -> Bool {
        let config = ConfigStore.shared.config
        let backdrop = tw_window_set_appearance(raw(hwnd), 1, config.blurBackground ? 1 : 0) != 0
        let ico = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("Termsie.ico").path
        _ = withWide(ico) { tw_window_set_icon(raw(hwnd), $0) }
        return backdrop
    }

    func show(activate: Bool) {
        ShowWindow(hwnd, activate ? Win.SW_SHOW : 8 /* SW_SHOWNA */)
        UpdateWindow(hwnd)
    }

    func requestPaint() {
        controller.paint()
    }

    func toggleFullScreen() {
        guard let hwnd else { return }
        if !isFullScreenNow {
            savedStyle = GetWindowLongPtrW(hwnd, Win.GWL_STYLE)
            savedPlacement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
            GetWindowPlacement(hwnd, &savedPlacement)
            var info = MONITORINFO()
            info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            GetMonitorInfoW(MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST)), &info)
            SetWindowLongPtrW(hwnd, Win.GWL_STYLE, savedStyle & ~LONG_PTR(Win.WS_OVERLAPPEDWINDOW))
            let m = info.rcMonitor
            SetWindowPos(hwnd, HWND(bitPattern: 0), m.left, m.top, m.right - m.left, m.bottom - m.top,
                         0x0020 /* SWP_FRAMECHANGED */ | Win.SWP_NOZORDER)
            isFullScreenNow = true
        } else {
            SetWindowLongPtrW(hwnd, Win.GWL_STYLE, savedStyle)
            SetWindowPlacement(hwnd, &savedPlacement)
            SetWindowPos(hwnd, nil, 0, 0, 0, 0, Win.SWP_NOMOVE | Win.SWP_NOSIZE | Win.SWP_NOZORDER | 0x0020)
            isFullScreenNow = false
        }
    }

    var frame: [Double] {
        var rc = RECT()
        if let hwnd {
            var placement = WINDOWPLACEMENT()
            placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
            if GetWindowPlacement(hwnd, &placement) { rc = placement.rcNormalPosition } else { GetWindowRect(hwnd, &rc) }
        }
        return [Double(rc.left), Double(rc.top), Double(rc.right - rc.left), Double(rc.bottom - rc.top)]
    }

    func setCapture() { SetCapture(hwnd) }
    func releaseCapture() { ReleaseCapture() }

    func setIMEPosition(x: Int, y: Int, lineHeight: Int) {
        tw_ime_set_position(raw(hwnd), Int32(x), Int32(y), Int32(lineHeight))
    }

    override func didDestroy() {
        Win32WindowHost.all.removeValue(forKey: ObjectIdentifier(self))
        controller.windowDestroyed()
    }

    // MARK: Geometry helpers

    private func dip(_ l: LPARAM) -> CGPoint {
        CGPoint(x: CGFloat(xParam(l)) / CGFloat(scale), y: CGFloat(yParam(l)) / CGFloat(scale))
    }

    private func dipFromScreen(_ l: LPARAM) -> CGPoint {
        var pt = POINT(x: LONG(xParam(l)), y: LONG(yParam(l)))
        ScreenToClient(hwnd, &pt)
        return CGPoint(x: CGFloat(pt.x) / CGFloat(scale), y: CGFloat(pt.y) / CGFloat(scale))
    }

    // MARK: Keyboard

    /// Sees every key message for this window before it is translated. Returns true when the
    /// message was used up: a shortcut, a find-field edit, or keys sent straight to the shell.
    func filterKey(_ msg: inout MSG) -> Bool {
        guard msg.message == Win.WM_KEYDOWN || msg.message == Win.WM_SYSKEYDOWN else { return false }
        let vk = Int32(truncatingIfNeeded: msg.wParam)
        // Modifier keys alone, Alt+F4 and Alt+Space keep their system meaning.
        if [Win.VK_SHIFT, Win.VK_CONTROL, Win.VK_MENU, Win.VK_LWIN, Win.VK_RWIN, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5].contains(vk) {
            return false
        }
        let m = Modifiers.current
        if m.contains(.alt) && !m.contains(.control) && (vk == Win.VK_F1 + 3 || vk == Win.VK_SPACE) { return false }
        guard let key = key(fromVirtualKey: vk) else { return false }
        return controller.keyDown(key, modifiers: m)
    }

    private func character(_ unit: UInt16, system: Bool) {
        // Backspace and DEL were sent from the key itself, with the right meaning.
        if unit == 0x08 || unit == 0x7f { return }
        guard let text = assembler.add(unit) else { return }
        controller.insertText(text, meta: system)
    }

    // MARK: Messages

    override func handle(_ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch msg {
        case Win.WM_PAINT:
            var ps = PAINTSTRUCT()
            BeginPaint(hwnd, &ps)
            EndPaint(hwnd, &ps)
            controller.paint()
            return 0
        case Win.WM_ERASEBKGND:
            return 1
        case Win.WM_SIZE:
            if wParam != Win.SIZE_MINIMIZED { controller.windowResized() } else { controller.windowMoved() }
            return 0
        case Win.WM_MOVE:
            controller.windowMoved()
            return nil
        case Win.WM_GETMINMAXINFO:
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) {
                info.pointee.ptMinTrackSize = POINT(x: LONG(520 * scale), y: LONG(300 * scale))
            }
            return 0
        case Win.WM_DPICHANGED:
            if let rect = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
                SetWindowPos(hwnd, nil, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
                             Win.SWP_NOZORDER | Win.SWP_NOACTIVATE)
            }
            controller.dpiChanged()
            return 0
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONDBLCLK:
            SetFocus(hwnd)
            controller.mouseDown(dip(lParam), button: 0, isDouble: msg == Win.WM_LBUTTONDBLCLK, modifiers: .current)
            return 0
        case Win.WM_RBUTTONDOWN:
            SetFocus(hwnd)
            controller.mouseDown(dip(lParam), button: 2, isDouble: false, modifiers: .current)
            return 0
        case Win.WM_MBUTTONDOWN:
            SetFocus(hwnd)
            controller.mouseDown(dip(lParam), button: 1, isDouble: false, modifiers: .current)
            return 0
        case Win.WM_LBUTTONUP:
            controller.mouseUp(dip(lParam), button: 0, modifiers: .current)
            return 0
        case Win.WM_RBUTTONUP, Win.WM_MBUTTONUP:
            controller.mouseUp(dip(lParam), button: msg == Win.WM_RBUTTONUP ? 2 : 1, modifiers: .current)
            return 0
        case Win.WM_MOUSEMOVE:
            if !trackingMouse, let hwnd {
                var tme = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: Win.TME_LEAVE,
                                          hwndTrack: hwnd, dwHoverTime: 0)
                TrackMouseEvent(&tme)
                trackingMouse = true
            }
            controller.mouseMoved(dip(lParam), modifiers: .current)
            return 0
        case Win.WM_MOUSELEAVE:
            trackingMouse = false
            controller.mouseLeft()
            return 0
        case Win.WM_CAPTURECHANGED:
            controller.captureLost()
            return 0
        case Win.WM_MOUSEWHEEL:
            controller.wheel(dipFromScreen(lParam), steps: Double(wheelDelta(wParam)) / Double(Win.WHEEL_DELTA),
                             horizontal: false, modifiers: .current)
            return 0
        case Win.WM_MOUSEHWHEEL:
            // Windows reports a rightward tilt as positive; the controller takes left as positive.
            controller.wheel(dipFromScreen(lParam), steps: -Double(wheelDelta(wParam)) / Double(Win.WHEEL_DELTA),
                             horizontal: true, modifiers: .current)
            return 0
        case Win.WM_SETCURSOR:
            guard LOWORD(lParam) == UInt16(Win.HTCLIENT) else { return nil }
            var pt = POINT()
            GetCursorPos(&pt)
            ScreenToClient(hwnd, &pt)
            let p = CGPoint(x: CGFloat(pt.x) / CGFloat(scale), y: CGFloat(pt.y) / CGFloat(scale))
            controller.cursorShape(at: p, modifiers: .current).apply()
            return 1
        case Win.WM_CHAR:
            character(UInt16(truncatingIfNeeded: wParam), system: false)
            return 0
        case Win.WM_SYSCHAR:
            // Alt+key: the xterm meta convention, ESC then the key.
            character(UInt16(truncatingIfNeeded: wParam), system: true)
            return 0
        case Win.WM_SYSCOMMAND:
            // A lone Alt (or F10) would open the window menu and steal the keyboard from the shell.
            if (wParam & 0xFFF0) == 0xF100 /* SC_KEYMENU */ && lParam == 0 { return 0 }
            return nil
        case Win.WM_SETFOCUS, Win.WM_KILLFOCUS, Win.WM_ACTIVATE:
            controller.focusChanged()
            return nil
        case Win.WM_CLOSE:
            controller.requestClose()
            return 0
        case Win.WM_QUERYENDSESSION:
            App.shared.saveSession()
            return 1
        case Win.WM_ENDSESSION:
            if wParam != 0 { App.shared.prepareForExit() }
            return 0
        default:
            return nil
        }
    }
}

func makeHostWindow(for controller: MainWindow) -> HostWindow {
    Win32WindowHost(controller: controller)
}
