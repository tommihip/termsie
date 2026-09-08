import AppKit
import SwiftTerm

/// Small overlay for searching the scrollback of one pane.
final class FindBarView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 30
    static let width: CGFloat = 340

    weak var terminalView: TermsieTerminalView?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton(title: "‹", target: nil, action: nil)
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        field.placeholderString = "Find"
        field.delegate = self
        field.font = NSFont.systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        addSubview(field)

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        addSubview(countLabel)

        for (b, sel) in [(prevButton, #selector(findPrevious)), (nextButton, #selector(findNext)), (closeButton, #selector(closeBar))] {
            b.bezelStyle = .texturedRounded
            b.setButtonType(.momentaryPushIn)
            b.target = self
            b.action = sel
            b.font = NSFont.systemFont(ofSize: 12)
            addSubview(b)
        }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyColors() {
        let colors = ConfigStore.shared.config.colors
        layer?.backgroundColor = NSColor.hex(colors.headerActiveBackground).cgColor
        layer?.borderColor = NSColor.hex(colors.activeBorder).cgColor
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let pad: CGFloat = 5
        let btnW: CGFloat = 26
        var right = bounds.width - pad
        closeButton.frame = NSRect(x: right - btnW, y: pad, width: btnW, height: h - 2 * pad); right -= btnW + 3
        nextButton.frame = NSRect(x: right - btnW, y: pad, width: btnW, height: h - 2 * pad); right -= btnW + 1
        prevButton.frame = NSRect(x: right - btnW, y: pad, width: btnW, height: h - 2 * pad); right -= btnW + 6
        countLabel.frame = NSRect(x: right - 64, y: pad + 2, width: 64, height: h - 2 * pad); right -= 64 + 4
        field.frame = NSRect(x: pad, y: pad, width: right - pad, height: h - 2 * pad)
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private var term: String { field.stringValue }

    func controlTextDidChange(_ obj: Notification) {
        guard let tv = terminalView else { return }
        tv.clearSearch()
        if !term.isEmpty { _ = tv.findNext(term) }
        updateCount()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.shift) { findPrevious() } else { findNext() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeBar()
            return true
        default:
            return false
        }
    }

    @objc func findNext() {
        guard let tv = terminalView, !term.isEmpty else { return }
        _ = tv.findNext(term)
        updateCount()
    }

    @objc func findPrevious() {
        guard let tv = terminalView, !term.isEmpty else { return }
        _ = tv.findPrevious(term)
        updateCount()
    }

    @objc func closeBar() {
        terminalView?.clearSearch()
        onClose?()
    }

    private func updateCount() {
        guard let tv = terminalView, !term.isEmpty else { countLabel.stringValue = ""; return }
        let s = tv.searchMatchSummary(term)
        countLabel.stringValue = s.total == 0 ? "0" : "\(s.index)/\(s.total)"
    }
}
