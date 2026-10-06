import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// A single-line text field drawn with Direct2D.
///
/// The main window draws through a composition swap chain and has no GDI surface, so a standard
/// EDIT control placed in it would never be seen. This covers what an inline field needs: typing,
/// a caret that moves by character and word, selection of everything, paste, and the keys that
/// commit or cancel.
final class TextField {
    private(set) var text: String = ""
    /// Caret position, in characters.
    private(set) var caret = 0
    private var allSelected = false
    var placeholder = ""
    var onChange: ((String) -> Void)?
    var onSubmit: ((_ backwards: Bool) -> Void)?
    var onCancel: (() -> Void)?
    private var assembler = SurrogateAssembler()

    func setText(_ s: String, selectAll: Bool = false) {
        text = s
        caret = s.count
        allSelected = selectAll && !s.isEmpty
    }

    func selectAll() {
        allSelected = !text.isEmpty
        caret = text.count
    }

    private func replaceSelection(with s: String) {
        if allSelected {
            text = s
            caret = s.count
            allSelected = false
        } else {
            let i = text.index(text.startIndex, offsetBy: caret)
            text.insert(contentsOf: s, at: i)
            caret += s.count
        }
        onChange?(text)
    }

    /// A key press. Returns true when the field used it.
    func keyDown(_ vk: Int32, ctrl: Bool, shift: Bool, owner: HWND?) -> Bool {
        switch vk {
        case Win.VK_RETURN:
            onSubmit?(shift)
            return true
        case Win.VK_ESCAPE:
            onCancel?()
            return true
        case Win.VK_LEFT:
            if allSelected { allSelected = false; caret = 0; return true }
            caret = ctrl ? wordBoundary(before: caret) : max(0, caret - 1)
            return true
        case Win.VK_RIGHT:
            if allSelected { allSelected = false; caret = text.count; return true }
            caret = ctrl ? wordBoundary(after: caret) : min(text.count, caret + 1)
            return true
        case Win.VK_HOME:
            allSelected = false
            caret = 0
            return true
        case Win.VK_END:
            allSelected = false
            caret = text.count
            return true
        case Win.VK_BACK:
            if allSelected { replaceSelection(with: ""); return true }
            guard caret > 0 else { return true }
            let from = ctrl ? wordBoundary(before: caret) : caret - 1
            removeRange(from, caret)
            caret = from
            onChange?(text)
            return true
        case Win.VK_DELETE:
            if allSelected { replaceSelection(with: ""); return true }
            guard caret < text.count else { return true }
            let to = ctrl ? wordBoundary(after: caret) : caret + 1
            removeRange(caret, to)
            onChange?(text)
            return true
        case 0x41 where ctrl:   // Ctrl+A
            selectAll()
            return true
        case 0x56 where ctrl:   // Ctrl+V
            if let pasted = Clipboard.get(owner: owner) {
                replaceSelection(with: pasted.components(separatedBy: .newlines).joined(separator: " "))
            }
            return true
        case 0x43 where ctrl:   // Ctrl+C
            Clipboard.set(text, owner: owner)
            return true
        default:
            return false
        }
    }

    /// A character from WM_CHAR.
    func character(_ unit: UInt16) {
        guard unit >= 0x20, unit != 0x7f else { return }
        guard let s = assembler.add(unit) else { return }
        replaceSelection(with: s)
    }

    private func removeRange(_ a: Int, _ b: Int) {
        let lo = text.index(text.startIndex, offsetBy: max(0, min(a, b)))
        let hi = text.index(text.startIndex, offsetBy: min(text.count, max(a, b)))
        text.removeSubrange(lo..<hi)
    }

    private func wordBoundary(before i: Int) -> Int {
        let chars = Array(text)
        var j = i
        while j > 0, chars[j - 1] == " " { j -= 1 }
        while j > 0, chars[j - 1] != " " { j -= 1 }
        return j
    }

    private func wordBoundary(after i: Int) -> Int {
        let chars = Array(text)
        var j = i
        while j < chars.count, chars[j] != " " { j += 1 }
        while j < chars.count, chars[j] == " " { j += 1 }
        return j
    }

    func draw(in rect: CGRect, renderer: Renderer, focused: Bool, caretOn: Bool) {
        let c = Theme.colors
        let font = Theme.ui(11.5)
        renderer.fillRounded(rect, radius: 4, Theme.color(c.background, alpha: 0.95))
        renderer.strokeRounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: 4, width: 1,
                               Theme.color(focused ? c.activeBorder : c.inactiveBorder))
        let inner = rect.insetBy(dx: 6, dy: 0)
        renderer.clipped(inner) {
            if text.isEmpty {
                renderer.text(placeholder, in: inner, font: font, color: Theme.color(c.headerText, alpha: 0.6))
            } else {
                let prefix = String(text.prefix(caret))
                let caretX = font.width(of: prefix)
                // Keep the caret in view when the text is wider than the field.
                let shift = max(0, caretX - inner.width + 4)
                let textRect = CGRect(x: inner.minX - shift, y: inner.minY, width: max(inner.width + shift, font.width(of: text) + 8),
                                      height: inner.height)
                if allSelected {
                    renderer.fill(CGRect(x: textRect.minX, y: inner.midY - 8, width: font.width(of: text), height: 16),
                                  Theme.color(c.selection))
                }
                renderer.text(text, in: textRect, font: font, color: Theme.color(c.foreground))
            }
            if focused && caretOn && !allSelected {
                let prefix = String(text.prefix(caret))
                let x = min(inner.minX + font.width(of: prefix) - max(0, font.width(of: prefix) - inner.width + 4), inner.maxX - 1)
                renderer.fill(CGRect(x: x.rounded(), y: inner.midY - 7, width: 1, height: 14), Theme.color(c.cursor))
            }
        }
    }
}
