import Foundation
import WinSDK
import CTermsieHost

enum Clipboard {
    static func set(_ text: String) {
        let units = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf16)
        _ = units.withUnsafeBufferPointer { tw_clipboard_set_text(nil, $0.baseAddress, Int32($0.count)) }
    }

    static func get() -> String? {
        guard let raw = tw_clipboard_get_text(nil) else { return nil }
        defer { tw_free(raw) }
        return String(wide: raw)
    }

    /// Windows has no selection clipboard: a selection is copied only by the copy commands, and
    /// middle-click pastes the ordinary clipboard, as in Windows Terminal.
    static func setSelection(_ text: String) {}
    static func getSelection() -> String? { get() }
}

enum Shell {
    static func open(_ target: String) {
        _ = withWide(target) { tw_shell_open($0) }
    }

    static func reveal(folder: String, file: String? = nil) {
        _ = withWide(folder) { f in withOptionalWide(file) { tw_shell_reveal(f, $0) } }
    }

    static func beep() {
        MessageBeep(0xFFFF_FFFF)
    }
}

enum Alert {
    enum Response { case first, second, third }

    /// A standard message box. `buttons` picks the Windows set; the response maps its buttons in
    /// reading order.
    static func show(_ title: String, _ message: String, owner: WindowRef?, style: UINT = Win.MB_OK | Win.MB_ICONINFORMATION) -> Int32 {
        // A scripted run has nobody to answer: say what was asked and take the first button,
        // which for every question here is the one that goes ahead.
        if DebugDriver.isActive {
            let oneLine = message.split(whereSeparator: \.isNewline).joined(separator: " ")
            DebugOutput.print("alert: \(title) — \(oneLine)")
            switch style & 0x0F {
            case Win.MB_OKCANCEL: return Win.IDOK
            case Win.MB_YESNOCANCEL, Win.MB_YESNO: return Win.IDYES
            default: return Win.IDOK
            }
        }
        let hwnd = owner.map { HWND($0.assumingMemoryBound(to: HWND__.self)) }
        return withWide(message, title) { m, t in MessageBoxW(hwnd, m, t, style) }
    }

    static func info(_ title: String, _ message: String, owner: WindowRef?) {
        _ = show(title, message, owner: owner, style: Win.MB_OK | Win.MB_ICONINFORMATION)
    }

    static func error(_ title: String, _ message: String, owner: WindowRef?) {
        _ = show(title, message, owner: owner, style: Win.MB_OK | Win.MB_ICONERROR)
    }

    /// OK / Cancel. True for OK.
    static func confirm(_ title: String, _ message: String, owner: WindowRef?, warning: Bool = false) -> Bool {
        let icon = warning ? Win.MB_ICONWARNING : Win.MB_ICONQUESTION
        return show(title, message, owner: owner, style: Win.MB_OKCANCEL | icon) == Win.IDOK
    }

    /// Yes / No / Cancel, as `.first`, `.second`, `.third`.
    static func yesNoCancel(_ title: String, _ message: String, owner: WindowRef?) -> Response {
        switch show(title, message, owner: owner, style: Win.MB_YESNOCANCEL | Win.MB_ICONQUESTION) {
        case Win.IDYES: return .first
        case Win.IDNO: return .second
        default: return .third
        }
    }

    /// Yes / No. True for Yes.
    static func yesNo(_ title: String, _ message: String, owner: WindowRef?, defaultNo: Bool = false) -> Bool {
        var style = Win.MB_YESNO | Win.MB_ICONQUESTION
        if defaultNo { style |= Win.MB_DEFBUTTON2 }
        return show(title, message, owner: owner, style: style) == Win.IDYES
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
