import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// A window of standard Win32 controls laid out as a labelled column: the settings dialogs.
///
/// Built from descriptions rather than resource templates, so each dialog is a list of fields
/// and the code that reads them back. It can run modally (`runModal`) or stay open beside the
/// main window (`showModeless`).
class FormWindow: Window {
    enum Kind {
        case text(String)
        case multiline(String, lines: Int, monospace: Bool)
        case check(Bool)
        case choice([String], selected: Int)
        /// An editable combo box: a free-text field with suggestions.
        case combo([String], text: String)
        case note(String)
        case heading(String)
        case button(String)
    }

    struct Field {
        var key: String
        var label: String
        var kind: Kind
        /// A small button at the right of the field, such as "Browse…".
        var accessory: String?
        /// 0 is always shown. Fields on pages 1, 2… share the same space and `showPage` picks one.
        var page: Int

        init(_ key: String, _ label: String, _ kind: Kind, accessory: String? = nil, page: Int = 0) {
            self.key = key; self.label = label; self.kind = kind; self.accessory = accessory; self.page = page
        }
    }

    struct ButtonSpec {
        var id: Int32
        var title: String
        var isDefault = false
    }

    // Control styles and messages.
    private static let ES_AUTOHSCROLL: DWORD = 0x0080
    private static let ES_MULTILINE: DWORD = 0x0004
    private static let ES_WANTRETURN: DWORD = 0x1000
    private static let ES_AUTOVSCROLL: DWORD = 0x0040
    private static let ES_READONLY: DWORD = 0x0800
    private static let BS_PUSHBUTTON: DWORD = 0x0000
    private static let BS_DEFPUSHBUTTON: DWORD = 0x0001
    private static let BS_AUTOCHECKBOX: DWORD = 0x0003
    private static let CBS_DROPDOWN: DWORD = 0x0002
    private static let CBS_DROPDOWNLIST: DWORD = 0x0003
    private static let CBS_AUTOHSCROLL: DWORD = 0x0040
    private static let SS_LEFT: DWORD = 0x0000
    static let BM_GETCHECK: UINT = 0x00F0
    static let BM_SETCHECK: UINT = 0x00F1
    static let CB_ADDSTRING: UINT = 0x0143
    static let CB_GETCURSEL: UINT = 0x0147
    static let CB_SETCURSEL: UINT = 0x014E
    static let CB_RESETCONTENT: UINT = 0x014B
    static let EM_SETSEL: UINT = 0x00B1
    static let BN_CLICKED: UInt16 = 0
    static let CBN_SELCHANGE: UInt16 = 1

    private(set) var controls: [String: HWND] = [:]
    private(set) var labels: [String: HWND] = [:]
    private var accessories: [Int32: String] = [:]
    private var accessoryHandles: [String: HWND] = [:]
    private var pageOf: [String: Int] = [:]
    private var fieldButtons: [Int32: String] = [:]
    private var nextID: Int32 = 1000
    private var font: HFONT?
    private var monoFont: HFONT?
    private var modalDone = false
    private(set) var result: Int32 = 0
    private weak var ownerWindow: Window?
    private var ownerHandle: HWND?

    /// DIP sizes.
    var labelWidth: CGFloat = 170
    var fieldWidth: CGFloat = 340
    let margin: CGFloat = 14
    let rowHeight: CGFloat = 26

    var s: CGFloat { CGFloat(scale) }

    // MARK: Creating

    /// Creates the window sized for `fields` and `buttons`, centred on `owner`.
    func build(title: String, owner: HWND?, fields: [Field], buttons: [ButtonSpec], resizable: Bool = false) -> Bool {
        Window.registerClass("TermsieForm", style: 0x0008, background: HBRUSH(bitPattern: Int(Win.COLOR_WINDOW + 1)))
        ownerHandle = owner
        var style = Win.WS_CAPTION | Win.WS_SYSMENU | Win.WS_CLIPCHILDREN | Win.WS_POPUP
        if resizable { style |= Win.WS_THICKFRAME | Win.WS_MAXIMIZEBOX | Win.WS_MINIMIZEBOX }
        guard create(className: "TermsieForm", title: title, style: style,
                     exStyle: Win.WS_EX_DLGMODALFRAME | Win.WS_EX_CONTROLPARENT,
                     x: 0, y: 0, width: 200, height: 200, parent: owner) else { return false }
        _ = tw_window_set_appearance(raw(hwnd), 0, 0)
        makeFonts()
        let height = layout(fields: fields, buttons: buttons)
        let width = margin * 3 + labelWidth + fieldWidth
        resizeClient(width: width, height: height)
        center(on: owner)
        return true
    }

    private func makeFonts() {
        let pt = Int32(-(9.0 * scale * 96 / 72).rounded())
        font = withWide("Segoe UI") { CreateFontW(pt, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, $0) }
        let mono = FontCache.exists("Cascadia Mono") ? "Cascadia Mono" : "Consolas"
        let mpt = Int32(-(9.5 * scale * 96 / 72).rounded())
        monoFont = withWide(mono) { CreateFontW(mpt, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, $0) }
    }

    private func resizeClient(width: CGFloat, height: CGFloat) {
        guard let hwnd else { return }
        var rc = RECT(left: 0, top: 0, right: LONG(width * s), bottom: LONG(height * s))
        AdjustWindowRectExForDpi(&rc, DWORD(truncatingIfNeeded: GetWindowLongPtrW(hwnd, Win.GWL_STYLE)), false,
                                 DWORD(truncatingIfNeeded: GetWindowLongPtrW(hwnd, -20 /* GWL_EXSTYLE */)),
                                 GetDpiForWindow(hwnd))
        SetWindowPos(hwnd, nil, 0, 0, rc.right - rc.left, rc.bottom - rc.top, Win.SWP_NOMOVE | Win.SWP_NOZORDER)
    }

    private func center(on owner: HWND?) {
        guard let hwnd else { return }
        var me = RECT(), them = RECT()
        GetWindowRect(hwnd, &me)
        if let owner, IsWindowVisible(owner) {
            GetWindowRect(owner, &them)
        } else {
            them = RECT(left: 0, top: 0, right: GetSystemMetrics(0), bottom: GetSystemMetrics(1))
        }
        let w = me.right - me.left, h = me.bottom - me.top
        let x = them.left + ((them.right - them.left) - w) / 2
        let y = them.top + max(0, ((them.bottom - them.top) - h) / 3)
        SetWindowPos(hwnd, nil, x, y, 0, 0, Win.SWP_NOSIZE | Win.SWP_NOZORDER)
    }

    @discardableResult
    func makeControl(_ cls: String, _ text: String, style: DWORD, exStyle: DWORD = 0, frame: CGRect, id: Int32,
                     mono: Bool = false) -> HWND? {
        let h: HWND? = withWide(cls, text) { c, t in
            CreateWindowExW(exStyle, c, t, Win.WS_CHILD | Win.WS_VISIBLE | style,
                            Int32(frame.minX * s), Int32(frame.minY * s), Int32(frame.width * s), Int32(frame.height * s),
                            hwnd, HMENU(bitPattern: Int(id)), GetModuleHandleW(nil), nil)
        }
        if let h { SendMessageW(h, Win.WM_SETFONT, WPARAM(UInt(bitPattern: mono ? monoFont : font)), 1) }
        return h
    }

    /// Lays out the fields top to bottom and the buttons at the bottom right. Returns the height.
    private func layout(fields: [Field], buttons: [ButtonSpec]) -> CGFloat {
        var y = margin
        let fieldX = margin * 2 + labelWidth
        var pagesTop: CGFloat?
        var pageBottom: [Int: CGFloat] = [:]
        var bottomOfAll: CGFloat = 0
        for field in fields {
            if field.page > 0 {
                if pagesTop == nil { pagesTop = y }
                y = pageBottom[field.page] ?? pagesTop!
            } else if let top = pagesTop {
                // A page-0 field after the pages goes below the tallest page.
                y = max(top, pageBottom.values.max() ?? top)
                pagesTop = nil
                pageBottom = [:]
            }
            pageOf[field.key] = field.page
            defer {
                if field.page > 0 { pageBottom[field.page] = y }
                bottomOfAll = max(bottomOfAll, y)
            }
            nextID += 1
            let id = nextID
            let accessoryWidth: CGFloat = field.accessory == nil ? 0 : 84
            let w = fieldWidth - accessoryWidth
            switch field.kind {
            case .heading(let text):
                y += 4
                let h = makeControl("STATIC", text, style: FormWindow.SS_LEFT,
                                    frame: CGRect(x: margin, y: y, width: labelWidth + fieldWidth + margin, height: 18), id: id)
                if let h { labels[field.key] = h; SendMessageW(h, Win.WM_SETFONT, WPARAM(UInt(bitPattern: boldFont())), 1) }
                y += 22
                continue
            case .note(let text):
                let lines = max(1, text.count / 60 + text.filter { $0 == "\n" }.count + 1)
                let h = makeControl("STATIC", text, style: FormWindow.SS_LEFT,
                                    frame: CGRect(x: fieldX, y: y, width: fieldWidth, height: CGFloat(lines) * 16), id: id)
                if let h { controls[field.key] = h }
                y += CGFloat(lines) * 16 + 6
                continue
            default:
                break
            }
            let label = makeControl("STATIC", field.label, style: FormWindow.SS_LEFT,
                                    frame: CGRect(x: margin, y: y + 4, width: labelWidth, height: 18), id: id + 50000)
            if let label { labels[field.key] = label }
            var height = rowHeight - 4
            var control: HWND?
            switch field.kind {
            case .text(let value):
                control = makeControl("EDIT", value, style: Win.WS_TABSTOP | FormWindow.ES_AUTOHSCROLL,
                                      exStyle: Win.WS_EX_CLIENTEDGE, frame: CGRect(x: fieldX, y: y, width: w, height: height), id: id)
            case .multiline(let value, let lines, let monospace):
                height = CGFloat(lines) * 16 + 8
                let text = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
                control = makeControl("EDIT", text,
                                      style: Win.WS_TABSTOP | FormWindow.ES_MULTILINE | FormWindow.ES_WANTRETURN
                                          | FormWindow.ES_AUTOVSCROLL | Win.WS_VSCROLL | (monospace ? Win.WS_HSCROLL | FormWindow.ES_AUTOHSCROLL : 0),
                                      exStyle: Win.WS_EX_CLIENTEDGE, frame: CGRect(x: fieldX, y: y, width: w, height: height),
                                      id: id, mono: monospace)
            case .check(let on):
                control = makeControl("BUTTON", "", style: Win.WS_TABSTOP | FormWindow.BS_AUTOCHECKBOX,
                                      frame: CGRect(x: fieldX, y: y + 2, width: w, height: 18), id: id)
                if let control, on { SendMessageW(control, FormWindow.BM_SETCHECK, 1, 0) }
            case .choice(let options, let selected):
                control = makeControl("COMBOBOX", "", style: Win.WS_TABSTOP | FormWindow.CBS_DROPDOWNLIST | Win.WS_VSCROLL,
                                      frame: CGRect(x: fieldX, y: y, width: w, height: 300), id: id)
                if let control {
                    for o in options { _ = withWide(o) { SendMessageW(control, FormWindow.CB_ADDSTRING, 0, LPARAM(Int(bitPattern: $0))) } }
                    SendMessageW(control, FormWindow.CB_SETCURSEL, WPARAM(max(0, selected)), 0)
                }
            case .combo(let options, let text):
                control = makeControl("COMBOBOX", "", style: Win.WS_TABSTOP | FormWindow.CBS_DROPDOWN | FormWindow.CBS_AUTOHSCROLL | Win.WS_VSCROLL,
                                      frame: CGRect(x: fieldX, y: y, width: w, height: 320), id: id)
                if let control {
                    for o in options { _ = withWide(o) { SendMessageW(control, FormWindow.CB_ADDSTRING, 0, LPARAM(Int(bitPattern: $0))) } }
                    _ = withWide(text) { SetWindowTextW(control, $0) }
                }
            case .button(let title):
                control = makeControl("BUTTON", title, style: Win.WS_TABSTOP | FormWindow.BS_PUSHBUTTON,
                                      frame: CGRect(x: fieldX, y: y, width: min(w, 200), height: height), id: id)
                fieldButtons[id] = field.key
            case .heading, .note:
                break
            }
            if let control { controls[field.key] = control }
            if let accessory = field.accessory {
                nextID += 1
                let h = makeControl("BUTTON", accessory, style: Win.WS_TABSTOP | FormWindow.BS_PUSHBUTTON,
                                    frame: CGRect(x: fieldX + w + 6, y: y, width: accessoryWidth - 6, height: rowHeight - 4), id: nextID)
                accessories[nextID] = field.key
                if let h { accessoryHandles[field.key] = h }
            }
            y += height + 6
        }
        y = max(y, bottomOfAll) + 8
        let buttonWidth: CGFloat = 96
        var x = margin * 2 + labelWidth + fieldWidth
        for b in buttons.reversed() {
            x -= buttonWidth
            makeControl("BUTTON", b.title, style: Win.WS_TABSTOP | (b.isDefault ? FormWindow.BS_DEFPUSHBUTTON : FormWindow.BS_PUSHBUTTON),
                        frame: CGRect(x: x, y: y, width: buttonWidth, height: 28), id: b.id)
            x -= 8
        }
        return y + 28 + margin
    }

    private var bold: HFONT?
    private func boldFont() -> HFONT? {
        if bold == nil {
            let pt = Int32(-(9.0 * scale * 96 / 72).rounded())
            bold = withWide("Segoe UI") { CreateFontW(pt, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, $0) }
        }
        return bold
    }

    // MARK: Reading and writing values

    func text(_ key: String) -> String {
        guard let h = controls[key] else { return "" }
        let n = Int(GetWindowTextLengthW(h))
        var buffer = [WCHAR](repeating: 0, count: n + 1)
        GetWindowTextW(h, &buffer, Int32(buffer.count))
        return String(wideBuffer: buffer).replacingOccurrences(of: "\r\n", with: "\n")
    }

    func setText(_ key: String, _ value: String) {
        guard let h = controls[key] else { return }
        let t = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        _ = withWide(t) { SetWindowTextW(h, $0) }
    }

    func checked(_ key: String) -> Bool {
        guard let h = controls[key] else { return false }
        return SendMessageW(h, FormWindow.BM_GETCHECK, 0, 0) == 1
    }

    func setChecked(_ key: String, _ on: Bool) {
        guard let h = controls[key] else { return }
        SendMessageW(h, FormWindow.BM_SETCHECK, on ? 1 : 0, 0)
    }

    func selection(_ key: String) -> Int {
        guard let h = controls[key] else { return -1 }
        return Int(SendMessageW(h, FormWindow.CB_GETCURSEL, 0, 0))
    }

    func setSelection(_ key: String, _ index: Int) {
        guard let h = controls[key] else { return }
        SendMessageW(h, FormWindow.CB_SETCURSEL, WPARAM(max(0, index)), 0)
    }

    func setOptions(_ key: String, _ options: [String], selected: Int) {
        guard let h = controls[key] else { return }
        SendMessageW(h, FormWindow.CB_RESETCONTENT, 0, 0)
        for o in options { _ = withWide(o) { SendMessageW(h, FormWindow.CB_ADDSTRING, 0, LPARAM(Int(bitPattern: $0))) } }
        SendMessageW(h, FormWindow.CB_SETCURSEL, WPARAM(max(0, selected)), 0)
    }

    func setVisible(_ key: String, _ visible: Bool) {
        let show = visible ? Win.SW_SHOW : Win.SW_HIDE
        if let h = controls[key] { ShowWindow(h, show) }
        if let h = labels[key] { ShowWindow(h, show) }
        if let h = accessoryHandles[key] { ShowWindow(h, show) }
    }

    /// Shows the fields of one page and hides the others'.
    func showPage(_ page: Int) {
        for (key, p) in pageOf where p > 0 { setVisible(key, p == page) }
    }

    func setEnabled(_ key: String, _ enabled: Bool) {
        if let h = controls[key] { EnableWindow(h, enabled ? true : false) }
    }

    func focus(_ key: String, selectAll: Bool = true) {
        guard let h = controls[key] else { return }
        SetFocus(h)
        if selectAll { SendMessageW(h, FormWindow.EM_SETSEL, 0, -1) }
    }

    // MARK: Running

    /// Shows the window and runs until `finish` is called. Returns the code passed to it.
    @discardableResult
    func runModal() -> Int32 {
        guard let hwnd else { return 0 }
        if let owner = ownerHandle { EnableWindow(owner, false) }
        ShowWindow(hwnd, Win.SW_SHOW)
        SetForegroundWindow(hwnd)
        var msg = MSG()
        var sawQuit: Int32?
        while !modalDone {
            let r = GetMessageW(&msg, nil, 0, 0)
            if !r {
                sawQuit = Int32(truncatingIfNeeded: msg.wParam)
                break
            }
            if IsDialogMessageW(hwnd, &msg) { continue }
            TranslateMessage(&msg)
            DispatchMessageW(&msg)
        }
        if let owner = ownerHandle {
            EnableWindow(owner, true)
            SetForegroundWindow(owner)
        }
        if self.hwnd != nil { DestroyWindow(hwnd) }
        if let sawQuit { PostQuitMessage(sawQuit) }
        return result
    }

    /// Shows the window beside its owner without blocking it.
    func showModeless() {
        guard let hwnd else { return }
        if !MessageLoop.dialogs.contains(hwnd) { MessageLoop.dialogs.append(hwnd) }
        ShowWindow(hwnd, Win.SW_SHOW)
        SetForegroundWindow(hwnd)
    }

    func finish(_ code: Int32) {
        result = code
        modalDone = true
        if let hwnd { ShowWindow(hwnd, Win.SW_HIDE) }
    }

    func closeModeless() {
        guard let hwnd else { return }
        MessageLoop.dialogs.removeAll { $0 == hwnd }
        DestroyWindow(hwnd)
    }

    override func didDestroy() {
        if let font { DeleteObject(font) }
        if let monoFont { DeleteObject(monoFont) }
        if let bold { DeleteObject(bold) }
        if let hwnd { MessageLoop.dialogs.removeAll { $0 == hwnd } }
        modalDone = true
    }

    // MARK: Events for subclasses

    /// A dialog button (OK, Cancel, Apply…) was pressed.
    func buttonPressed(_ id: Int32) {
        finish(id)
    }

    /// A field's accessory button (Browse…) or a button field was pressed.
    func accessoryPressed(_ key: String) {}

    /// A choice field changed.
    func selectionChanged(_ key: String) {}

    /// The window is being closed from its title bar. Default: same as Cancel.
    func closeRequested() {
        buttonPressed(Win.IDCANCEL)
    }

    override func handle(_ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch msg {
        case Win.WM_COMMAND:
            let id = Int32(LOWORD(wParam))
            let code = HIWORD(wParam)
            if code == FormWindow.CBN_SELCHANGE, let key = controls.first(where: { GetDlgCtrlID($0.value) == id })?.key {
                selectionChanged(key)
                return 0
            }
            guard code == FormWindow.BN_CLICKED else { return nil }
            if let key = accessories[id] { accessoryPressed(key); return 0 }
            if let key = fieldButtons[id] { accessoryPressed(key); return 0 }
            if id == Win.IDOK || id == Win.IDCANCEL || id < 1000 {
                buttonPressed(id)
                return 0
            }
            return nil
        case Win.WM_CLOSE:
            closeRequested()
            return 0
        case Win.WM_CTLCOLORSTATIC:
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Simple prompts

/// One line of text, with OK and Cancel: rename a terminal.
final class PromptDialog: FormWindow {
    static func run(owner: HWND?, title: String, message: String, initial: String) -> String? {
        let dialog = PromptDialog()
        dialog.labelWidth = 80
        dialog.fieldWidth = 300
        guard dialog.build(title: title, owner: owner,
                           fields: [Field("note", "", .note(message)), Field("value", "Name", .text(initial))],
                           buttons: [ButtonSpec(id: Win.IDOK, title: "OK", isDefault: true),
                                     ButtonSpec(id: Win.IDCANCEL, title: "Cancel")]) else { return nil }
        dialog.focus("value")
        var value: String?
        dialog.onAccept = { value = dialog.text("value") }
        dialog.runModal()
        return value
    }

    var onAccept: (() -> Void)?

    override func buttonPressed(_ id: Int32) {
        if id == Win.IDOK { onAccept?() }
        finish(id)
    }
}

/// Save Workspace As: a name, and whether to fold in what is running now.
final class SaveWorkspaceDialog: FormWindow {
    struct Answer {
        var name: String
        var includeRunning: Bool
    }

    static func run(owner: HWND?, name: String) -> Answer? {
        let dialog = SaveWorkspaceDialog()
        dialog.labelWidth = 120
        dialog.fieldWidth = 300
        let folder = HomePath.abbreviate(ConfigStore.shared.workspacesDir.path)
        guard dialog.build(title: "Save Workspace", owner: owner, fields: [
            Field("note", "", .note("Saves this tab's terminals, their folders and their startup commands to \(folder).")),
            Field("name", "Workspace name", .text(name)),
            Field("running", "Include commands currently running", .check(false)),
        ], buttons: [ButtonSpec(id: Win.IDOK, title: "Save", isDefault: true), ButtonSpec(id: Win.IDCANCEL, title: "Cancel")])
        else { return nil }
        dialog.focus("name")
        var answer: Answer?
        dialog.onAccept = {
            let n = dialog.text("name").trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { answer = Answer(name: n, includeRunning: dialog.checked("running")) }
        }
        dialog.runModal()
        return answer
    }

    var onAccept: (() -> Void)?

    override func buttonPressed(_ id: Int32) {
        if id == Win.IDOK { onAccept?() }
        finish(id)
    }
}
