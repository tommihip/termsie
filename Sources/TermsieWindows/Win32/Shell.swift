import Foundation
import WinSDK
import CTermsieWin

enum Clipboard {
    static func set(_ text: String, owner: HWND?) {
        let units = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf16)
        _ = units.withUnsafeBufferPointer { tw_clipboard_set_text(raw(owner), $0.baseAddress, Int32($0.count)) }
    }

    static func get(owner: HWND?) -> String? {
        guard let raw = tw_clipboard_get_text(raw(owner)) else { return nil }
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
        MessageBeep(0xFFFF_FFFF)
    }
}

enum Alert {
    enum Response { case first, second, third }

    /// A standard message box. `buttons` picks the Windows set; the response maps its buttons in
    /// reading order.
    static func show(_ title: String, _ message: String, owner: HWND?, style: UINT = Win.MB_OK | Win.MB_ICONINFORMATION) -> Int32 {
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
        return withWide(message, title) { m, t in MessageBoxW(owner, m, t, style) }
    }

    static func info(_ title: String, _ message: String, owner: HWND?) {
        _ = show(title, message, owner: owner, style: Win.MB_OK | Win.MB_ICONINFORMATION)
    }

    static func error(_ title: String, _ message: String, owner: HWND?) {
        _ = show(title, message, owner: owner, style: Win.MB_OK | Win.MB_ICONERROR)
    }

    /// OK / Cancel. True for OK.
    static func confirm(_ title: String, _ message: String, owner: HWND?, warning: Bool = false) -> Bool {
        let icon = warning ? Win.MB_ICONWARNING : Win.MB_ICONQUESTION
        return show(title, message, owner: owner, style: Win.MB_OKCANCEL | icon) == Win.IDOK
    }

    /// Yes / No / Cancel, as `.first`, `.second`, `.third`.
    static func yesNoCancel(_ title: String, _ message: String, owner: HWND?) -> Response {
        switch show(title, message, owner: owner, style: Win.MB_YESNOCANCEL | Win.MB_ICONQUESTION) {
        case Win.IDYES: return .first
        case Win.IDNO: return .second
        default: return .third
        }
    }

    /// Yes / No. True for Yes.
    static func yesNo(_ title: String, _ message: String, owner: HWND?, defaultNo: Bool = false) -> Bool {
        var style = Win.MB_YESNO | Win.MB_ICONQUESTION
        if defaultNo { style |= Win.MB_DEFBUTTON2 }
        return show(title, message, owner: owner, style: style) == Win.IDYES
    }
}

enum FileDialog {
    static func open(owner: HWND?, title: String, filterName: String = "JSON files", filterSpec: String = "*.json",
                     folder: String? = nil) -> String? {
        run(owner: owner, save: false, pickFolder: false, title: title, filterName: filterName, filterSpec: filterSpec,
            defaultName: nil, defaultExtension: nil, folder: folder)
    }

    static func save(owner: HWND?, title: String, defaultName: String, filterName: String = "JSON files",
                     filterSpec: String = "*.json", defaultExtension: String = "json", folder: String? = nil) -> String? {
        run(owner: owner, save: true, pickFolder: false, title: title, filterName: filterName, filterSpec: filterSpec,
            defaultName: defaultName, defaultExtension: defaultExtension, folder: folder)
    }

    static func folder(owner: HWND?, title: String, start: String? = nil) -> String? {
        run(owner: owner, save: false, pickFolder: true, title: title, filterName: nil, filterSpec: nil,
            defaultName: nil, defaultExtension: nil, folder: start)
    }

    private static func run(owner: HWND?, save: Bool, pickFolder: Bool, title: String, filterName: String?,
                            filterSpec: String?, defaultName: String?, defaultExtension: String?, folder: String?) -> String? {
        var out = [WCHAR](repeating: 0, count: 4096)
        let ok: Int32 = withWide(title) { t in
            withOptionalWide(filterName) { fn in
                withOptionalWide(filterSpec) { fs in
                    withOptionalWide(defaultName) { dn in
                        withOptionalWide(defaultExtension) { de in
                            withOptionalWide(folder) { f in
                                tw_file_dialog(raw(owner), save ? 1 : 0, pickFolder ? 1 : 0, t, fn, fs, dn, de, f, &out,
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
