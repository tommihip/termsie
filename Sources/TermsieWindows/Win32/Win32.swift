import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

// The Win32 vocabulary the app uses. Many Windows headers define constants as macros that Swift
// imports with the wrong integer type or not at all (anything built from other macros or casts),
// so the ones used here are spelled out with the types the APIs take.

enum Win {
    // Window styles
    static let WS_OVERLAPPEDWINDOW: DWORD = 0x00CF_0000
    static let WS_POPUP: DWORD = 0x8000_0000
    static let WS_CHILD: DWORD = 0x4000_0000
    static let WS_VISIBLE: DWORD = 0x1000_0000
    static let WS_CLIPCHILDREN: DWORD = 0x0200_0000
    static let WS_CLIPSIBLINGS: DWORD = 0x0400_0000
    static let WS_CAPTION: DWORD = 0x00C0_0000
    static let WS_SYSMENU: DWORD = 0x0008_0000
    static let WS_THICKFRAME: DWORD = 0x0004_0000
    static let WS_MINIMIZEBOX: DWORD = 0x0002_0000
    static let WS_MAXIMIZEBOX: DWORD = 0x0001_0000
    static let WS_TABSTOP: DWORD = 0x0001_0000
    static let WS_GROUP: DWORD = 0x0002_0000
    static let WS_BORDER: DWORD = 0x0080_0000
    static let WS_VSCROLL: DWORD = 0x0020_0000
    static let WS_HSCROLL: DWORD = 0x0010_0000
    static let WS_DLGFRAME: DWORD = 0x0040_0000
    static let WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x0020_0000
    static let WS_EX_APPWINDOW: DWORD = 0x0004_0000
    static let WS_EX_CLIENTEDGE: DWORD = 0x0000_0200
    static let WS_EX_DLGMODALFRAME: DWORD = 0x0000_0001
    static let WS_EX_CONTROLPARENT: DWORD = 0x0001_0000
    static let WS_EX_TOOLWINDOW: DWORD = 0x0000_0080

    static let CW_USEDEFAULT: Int32 = Int32(bitPattern: 0x8000_0000)
    static let GWLP_USERDATA: Int32 = -21
    static let GWL_STYLE: Int32 = -16

    // Messages
    static let WM_CREATE: UINT = 0x0001
    static let WM_DESTROY: UINT = 0x0002
    static let WM_MOVE: UINT = 0x0003
    static let WM_SIZE: UINT = 0x0005
    static let WM_ACTIVATE: UINT = 0x0006
    static let WM_SETFOCUS: UINT = 0x0007
    static let WM_KILLFOCUS: UINT = 0x0008
    static let WM_ENABLE: UINT = 0x000A
    static let WM_SETTEXT: UINT = 0x000C
    static let WM_GETTEXT: UINT = 0x000D
    static let WM_GETTEXTLENGTH: UINT = 0x000E
    static let WM_PAINT: UINT = 0x000F
    static let WM_CLOSE: UINT = 0x0010
    static let WM_QUERYENDSESSION: UINT = 0x0011
    static let WM_QUIT: UINT = 0x0012
    static let WM_ERASEBKGND: UINT = 0x0014
    static let WM_ENDSESSION: UINT = 0x0016
    static let WM_SHOWWINDOW: UINT = 0x0018
    static let WM_ACTIVATEAPP: UINT = 0x001C
    static let WM_SETCURSOR: UINT = 0x0020
    static let WM_MOUSEACTIVATE: UINT = 0x0021
    static let WM_GETMINMAXINFO: UINT = 0x0024
    static let WM_SETFONT: UINT = 0x0030
    static let WM_WINDOWPOSCHANGED: UINT = 0x0047
    static let WM_NOTIFY: UINT = 0x004E
    static let WM_SETICON: UINT = 0x0080
    static let WM_NCCREATE: UINT = 0x0081
    static let WM_NCDESTROY: UINT = 0x0082
    static let WM_KEYDOWN: UINT = 0x0100
    static let WM_KEYUP: UINT = 0x0101
    static let WM_CHAR: UINT = 0x0102
    static let WM_SYSKEYDOWN: UINT = 0x0104
    static let WM_SYSKEYUP: UINT = 0x0105
    static let WM_SYSCHAR: UINT = 0x0106
    static let WM_UNICHAR: UINT = 0x0109
    static let WM_INITDIALOG: UINT = 0x0110
    static let WM_COMMAND: UINT = 0x0111
    static let WM_SYSCOMMAND: UINT = 0x0112
    static let WM_TIMER: UINT = 0x0113
    static let WM_HSCROLL: UINT = 0x0114
    static let WM_VSCROLL: UINT = 0x0115
    static let WM_INITMENUPOPUP: UINT = 0x0117
    static let WM_CTLCOLOREDIT: UINT = 0x0133
    static let WM_CTLCOLORLISTBOX: UINT = 0x0134
    static let WM_CTLCOLORBTN: UINT = 0x0135
    static let WM_CTLCOLORDLG: UINT = 0x0136
    static let WM_CTLCOLORSTATIC: UINT = 0x0138
    static let WM_MOUSEMOVE: UINT = 0x0200
    static let WM_LBUTTONDOWN: UINT = 0x0201
    static let WM_LBUTTONUP: UINT = 0x0202
    static let WM_LBUTTONDBLCLK: UINT = 0x0203
    static let WM_RBUTTONDOWN: UINT = 0x0204
    static let WM_RBUTTONUP: UINT = 0x0205
    static let WM_MBUTTONDOWN: UINT = 0x0207
    static let WM_MBUTTONUP: UINT = 0x0208
    static let WM_MOUSEWHEEL: UINT = 0x020A
    static let WM_MOUSEHWHEEL: UINT = 0x020E
    static let WM_CAPTURECHANGED: UINT = 0x0215
    static let WM_IME_STARTCOMPOSITION: UINT = 0x010D
    static let WM_IME_COMPOSITION: UINT = 0x010F
    static let WM_MOUSELEAVE: UINT = 0x02A3
    static let WM_DPICHANGED: UINT = 0x02E0
    static let WM_CLIPBOARDUPDATE: UINT = 0x031D
    static let WM_APP: UINT = 0x8000

    // Mouse
    static let MK_LBUTTON: WPARAM = 0x0001
    static let MK_RBUTTON: WPARAM = 0x0002
    static let MK_SHIFT: WPARAM = 0x0004
    static let MK_CONTROL: WPARAM = 0x0008
    static let MK_MBUTTON: WPARAM = 0x0010
    static let WHEEL_DELTA: Int32 = 120
    static let TME_LEAVE: DWORD = 0x0000_0002

    // Show / position
    static let SW_HIDE: Int32 = 0
    static let SW_SHOWNORMAL: Int32 = 1
    static let SW_SHOWMAXIMIZED: Int32 = 3
    static let SW_SHOW: Int32 = 5
    static let SW_MINIMIZE: Int32 = 6
    static let SW_RESTORE: Int32 = 9
    static let SWP_NOSIZE: UINT = 0x0001
    static let SWP_NOMOVE: UINT = 0x0002
    static let SWP_NOZORDER: UINT = 0x0004
    static let SWP_NOACTIVATE: UINT = 0x0010
    static let SWP_SHOWWINDOW: UINT = 0x0040
    static let SIZE_MINIMIZED: WPARAM = 1

    // Virtual keys
    static let VK_BACK: Int32 = 0x08
    static let VK_TAB: Int32 = 0x09
    static let VK_RETURN: Int32 = 0x0D
    static let VK_SHIFT: Int32 = 0x10
    static let VK_CONTROL: Int32 = 0x11
    static let VK_MENU: Int32 = 0x12
    static let VK_PAUSE: Int32 = 0x13
    static let VK_CAPITAL: Int32 = 0x14
    static let VK_ESCAPE: Int32 = 0x1B
    static let VK_SPACE: Int32 = 0x20
    static let VK_PRIOR: Int32 = 0x21
    static let VK_NEXT: Int32 = 0x22
    static let VK_END: Int32 = 0x23
    static let VK_HOME: Int32 = 0x24
    static let VK_LEFT: Int32 = 0x25
    static let VK_UP: Int32 = 0x26
    static let VK_RIGHT: Int32 = 0x27
    static let VK_DOWN: Int32 = 0x28
    static let VK_INSERT: Int32 = 0x2D
    static let VK_DELETE: Int32 = 0x2E
    static let VK_LWIN: Int32 = 0x5B
    static let VK_RWIN: Int32 = 0x5C
    static let VK_APPS: Int32 = 0x5D
    static let VK_NUMPAD0: Int32 = 0x60
    static let VK_MULTIPLY: Int32 = 0x6A
    static let VK_ADD: Int32 = 0x6B
    static let VK_SUBTRACT: Int32 = 0x6D
    static let VK_DECIMAL: Int32 = 0x6E
    static let VK_DIVIDE: Int32 = 0x6F
    static let VK_F1: Int32 = 0x70
    static let VK_F12: Int32 = 0x7B
    static let VK_F24: Int32 = 0x87
    static let VK_NUMLOCK: Int32 = 0x90
    static let VK_SCROLL: Int32 = 0x91
    static let VK_LSHIFT: Int32 = 0xA0
    static let VK_RMENU: Int32 = 0xA5
    static let VK_OEM_1: Int32 = 0xBA
    static let VK_OEM_PLUS: Int32 = 0xBB
    static let VK_OEM_COMMA: Int32 = 0xBC
    static let VK_OEM_MINUS: Int32 = 0xBD
    static let VK_OEM_PERIOD: Int32 = 0xBE
    static let VK_OEM_2: Int32 = 0xBF
    static let VK_OEM_3: Int32 = 0xC0
    static let VK_OEM_4: Int32 = 0xDB
    static let VK_OEM_5: Int32 = 0xDC
    static let VK_OEM_6: Int32 = 0xDD
    static let VK_OEM_7: Int32 = 0xDE

    // Menus
    static let MF_STRING: UINT = 0x0000
    static let MF_GRAYED: UINT = 0x0001
    static let MF_DISABLED: UINT = 0x0002
    static let MF_CHECKED: UINT = 0x0008
    static let MF_POPUP: UINT = 0x0010
    static let MF_SEPARATOR: UINT = 0x0800
    static let MF_BYCOMMAND: UINT = 0x0000
    static let MF_ENABLED: UINT = 0x0000
    static let MF_UNCHECKED: UINT = 0x0000
    static let TPM_RETURNCMD: UINT = 0x0100
    static let TPM_RIGHTBUTTON: UINT = 0x0002
    static let FVIRTKEY: BYTE = 0x01
    static let FSHIFT: BYTE = 0x04
    static let FCONTROL: BYTE = 0x08
    static let FALT: BYTE = 0x10

    // Message boxes
    static let MB_OK: UINT = 0x0000
    static let MB_OKCANCEL: UINT = 0x0001
    static let MB_YESNOCANCEL: UINT = 0x0003
    static let MB_YESNO: UINT = 0x0004
    static let MB_ICONERROR: UINT = 0x0010
    static let MB_ICONQUESTION: UINT = 0x0020
    static let MB_ICONWARNING: UINT = 0x0030
    static let MB_ICONINFORMATION: UINT = 0x0040
    static let MB_DEFBUTTON2: UINT = 0x0100
    static let IDOK: Int32 = 1
    static let IDCANCEL: Int32 = 2
    static let IDYES: Int32 = 6
    static let IDNO: Int32 = 7

    // Cursors (MAKEINTRESOURCE ids)
    static let IDC_ARROW = 32512
    static let IDC_IBEAM = 32513
    static let IDC_WAIT = 32514
    static let IDC_SIZENWSE = 32642
    static let IDC_SIZENESW = 32643
    static let IDC_SIZEWE = 32644
    static let IDC_SIZENS = 32645
    static let IDC_SIZEALL = 32646
    static let IDC_HAND = 32649

    // Message loop
    static let QS_ALLINPUT: DWORD = 0x04FF
    static let MWMO_INPUTAVAILABLE: DWORD = 0x0004
    static let PM_REMOVE: UINT = 0x0001
    static let INFINITE: DWORD = 0xFFFF_FFFF
    static let WAIT_TIMEOUT: DWORD = 258

    static let HTCLIENT: LRESULT = 1
    static let MA_ACTIVATE: LRESULT = 1
    static let COLOR_WINDOW: Int32 = 5
}

// MARK: - Small conversions

@inline(__always) func LOWORD<T: BinaryInteger>(_ v: T) -> UInt16 { UInt16(truncatingIfNeeded: Int(v) & 0xFFFF) }
@inline(__always) func HIWORD<T: BinaryInteger>(_ v: T) -> UInt16 { UInt16(truncatingIfNeeded: (Int(v) >> 16) & 0xFFFF) }
/// GET_X_LPARAM: the signed low word, which matters on multi-monitor setups left of the primary.
@inline(__always) func xParam(_ l: LPARAM) -> Int32 { Int32(Int16(bitPattern: LOWORD(l))) }
@inline(__always) func yParam(_ l: LPARAM) -> Int32 { Int32(Int16(bitPattern: HIWORD(l))) }
@inline(__always) func wheelDelta(_ w: WPARAM) -> Int32 { Int32(Int16(bitPattern: HIWORD(w))) }

/// A Win32 handle as the opaque pointer the C layer takes.
@inline(__always) func raw<T>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutableRawPointer? {
    p.map { UnsafeMutableRawPointer($0) }
}

func makeIntResource(_ id: Int) -> UnsafePointer<WCHAR>? {
    UnsafePointer<WCHAR>(bitPattern: id)
}

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

// MARK: - Keyboard state

enum Keys {
    static func isDown(_ vk: Int32) -> Bool { (GetKeyState(vk) & Int16(bitPattern: 0x8000)) != 0 }
    static var shift: Bool { isDown(Win.VK_SHIFT) }
    static var control: Bool { isDown(Win.VK_CONTROL) }
    static var alt: Bool { isDown(Win.VK_MENU) }
}

// MARK: - Cursors

enum CursorShape: Int {
    case arrow, ibeam, hand, sizeWE, sizeNS, sizeNWSE, sizeNESW, sizeAll, wait

    var resourceID: Int {
        switch self {
        case .arrow: return Win.IDC_ARROW
        case .ibeam: return Win.IDC_IBEAM
        case .hand: return Win.IDC_HAND
        case .sizeWE: return Win.IDC_SIZEWE
        case .sizeNS: return Win.IDC_SIZENS
        case .sizeNWSE: return Win.IDC_SIZENWSE
        case .sizeNESW: return Win.IDC_SIZENESW
        case .sizeAll: return Win.IDC_SIZEALL
        case .wait: return Win.IDC_WAIT
        }
    }

    private static var cache: [Int: HCURSOR] = [:]

    func apply() {
        let id = resourceID
        if Self.cache[id] == nil {
            Self.cache[id] = LoadCursorW(nil, makeIntResource(id))
        }
        SetCursor(Self.cache[id])
    }
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

// MARK: - Monotonic time

enum Clock {
    private static let frequency: Double = {
        var f = LARGE_INTEGER()
        QueryPerformanceFrequency(&f)
        return Double(f.QuadPart)
    }()

    /// Seconds since an arbitrary point, monotonic: CACurrentMediaTime's role on macOS.
    static var now: Double {
        var c = LARGE_INTEGER()
        QueryPerformanceCounter(&c)
        return Double(c.QuadPart) / frequency
    }
}

// MARK: - Logging

/// Diagnostics go to %LOCALAPPDATA%\Termsie\termsie.log, because a GUI process has no console.
enum Log {
    private static let lock = NSLock()
    private static var handle: FileHandle? = {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        let dir = URL(fileURLWithPath: base).appendingPathComponent("Termsie", isDirectory: true)
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
