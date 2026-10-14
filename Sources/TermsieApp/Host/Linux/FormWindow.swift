import Foundation
import CTermsieHost
import TermsieCore

/// A window of GTK controls laid out as a labelled column: the settings dialogs.
///
/// Built from descriptions rather than UI files, so each dialog is a list of fields and the
/// code that reads them back. It can run modally (`runModal`) or stay open beside the main
/// window (`showModeless`). The same API as the Windows form, so the dialogs are shared.
class FormWindow {
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

    static let ok: Int32 = 1
    static let cancel: Int32 = 2

    private var form: OpaquePointer?
    private var controls: [String: OpaquePointer] = [:]
    private var pageOf: [String: Int] = [:]
    private(set) var result: Int32 = 0
    private var modal = false

    /// DIP sizes, kept for the dialogs that set them; GTK lays the form out itself.
    var labelWidth: CGFloat = 170
    var fieldWidth: CGFloat = 340

    var ref: WindowRef? { form.map { UnsafeMutableRawPointer($0) } }

    private static func me(_ ctx: UnsafeMutableRawPointer?) -> FormWindow {
        Unmanaged<FormWindow>.fromOpaque(ctx!).takeUnretainedValue()
    }

    // MARK: Creating

    /// Creates the window sized for `fields` and `buttons`, centred on `owner`.
    func build(title: String, owner: WindowRef?, fields: [Field], buttons: [ButtonSpec], resizable: Bool = false) -> Bool {
        var cb = TWFormCallbacks()
        cb.context = Unmanaged.passUnretained(self).toOpaque()
        cb.button = { ctx, id in FormWindow.me(ctx).buttonPressed(id) }
        cb.accessory = { ctx, key in FormWindow.me(ctx).accessoryPressed(String(cString: key!)) }
        cb.selection_changed = { ctx, key in FormWindow.me(ctx).selectionChanged(String(cString: key!)) }
        cb.close_request = { ctx in
            FormWindow.me(ctx).closeRequested()
            return 0
        }
        form = withWide(title) { tw_form_create(owner, $0, resizable ? 1 : 0, &cb) }
        guard let form else { return false }
        for field in fields {
            pageOf[field.key] = field.page
            let control: OpaquePointer? = field.key.withCString { key in
                withWide(field.label) { label in
                    switch field.kind {
                    case .heading(let text):
                        return withWide(text) { tw_form_add_heading(form, key, $0) }
                    case .note(let text):
                        return withWide(text) { tw_form_add_note(form, key, $0) }
                    case .text(let value):
                        return withWide(value) { v in withOptionalWide(field.accessory) { tw_form_add_text(form, key, label, v, $0) } }
                    case .multiline(let value, let lines, let monospace):
                        return withWide(value) { tw_form_add_multiline(form, key, label, $0, Int32(lines), monospace ? 1 : 0) }
                    case .check(let on):
                        return tw_form_add_check(form, key, label, on ? 1 : 0)
                    case .choice(let options, let selected):
                        return wideList(options).withUnsafeBufferPointer { tw_form_add_choice(form, key, label, $0.baseAddress, Int32(selected)) }
                    case .combo(let options, let text):
                        return wideList(options).withUnsafeBufferPointer { o in withWide(text) { tw_form_add_combo(form, key, label, o.baseAddress, $0) } }
                    case .button(let title):
                        return withWide(title) { tw_form_add_button(form, key, $0) }
                    }
                }
            }
            if let control { controls[field.key] = control }
        }
        for b in buttons {
            withWide(b.title) { tw_form_add_action(form, b.id, $0, b.isDefault ? 1 : 0) }
        }
        return true
    }

    // MARK: Reading and writing values

    func text(_ key: String) -> String {
        guard let c = controls[key], let raw = tw_control_get_text(c) else { return "" }
        defer { tw_free(raw) }
        return String(wide: raw)
    }

    func setText(_ key: String, _ value: String) {
        guard let c = controls[key] else { return }
        withWide(value) { tw_control_set_text(c, $0) }
    }

    func checked(_ key: String) -> Bool {
        guard let c = controls[key] else { return false }
        return tw_control_get_checked(c) != 0
    }

    func setChecked(_ key: String, _ on: Bool) {
        guard let c = controls[key] else { return }
        tw_control_set_checked(c, on ? 1 : 0)
    }

    func selection(_ key: String) -> Int {
        guard let c = controls[key] else { return -1 }
        return Int(tw_control_get_selection(c))
    }

    func setSelection(_ key: String, _ index: Int) {
        guard let c = controls[key] else { return }
        tw_control_set_selection(c, Int32(max(0, index)))
    }

    func setOptions(_ key: String, _ options: [String], selected: Int) {
        guard let c = controls[key] else { return }
        wideList(options).withUnsafeBufferPointer { tw_control_set_options(c, $0.baseAddress, Int32(max(0, selected))) }
    }

    func setVisible(_ key: String, _ visible: Bool) {
        guard let c = controls[key] else { return }
        tw_control_set_visible(c, visible ? 1 : 0)
    }

    /// Shows the fields of one page and hides the others'.
    func showPage(_ page: Int) {
        for (key, p) in pageOf where p > 0 { setVisible(key, p == page) }
    }

    func setEnabled(_ key: String, _ enabled: Bool) {
        guard let c = controls[key] else { return }
        tw_control_set_enabled(c, enabled ? 1 : 0)
    }

    func focus(_ key: String, selectAll: Bool = true) {
        guard let c = controls[key] else { return }
        tw_control_focus(c, selectAll ? 1 : 0)
    }

    // MARK: Running

    /// Shows the window and runs until `finish` is called. Returns the code passed to it.
    @discardableResult
    func runModal() -> Int32 {
        guard let form else { return 0 }
        modal = true
        tw_form_present(form, 1)
        modal = false
        tw_form_destroy(form)
        self.form = nil
        controls.removeAll()
        return result
    }

    /// Shows the window beside its owner without blocking it.
    func showModeless() {
        guard let form else { return }
        tw_form_present(form, 0)
    }

    func finish(_ code: Int32) {
        result = code
        tw_form_finish(form)
    }

    func closeModeless() {
        guard let form else { return }
        tw_form_destroy(form)
        self.form = nil
        controls.removeAll()
    }

    /// Hides a modeless form without destroying it.
    func hide() {
        tw_form_hide(form)
    }

    func returnToOwner() {}

    var isShown: Bool { tw_form_is_visible(form) != 0 }

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
        buttonPressed(FormWindow.cancel)
    }
}
