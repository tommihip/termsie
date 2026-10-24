import AppKit

/// A short confirmation shown over a terminal when something is copied out of it — or when there
/// was nothing to copy.
///
/// The copy tools used to light up for a moment and the menu items did nothing visible at all,
/// so people could not tell whether the clipboard had changed. This says what was copied, how
/// much, and how it begins, on the terminal it came from, whichever way the copy was made
/// (⌘C, a copy tool, a shortcut, or auto-copy on select).
final class CopyToastView: NSView {
    struct Message: Equatable {
        var title: String
        /// The start of what was copied, or why nothing was.
        var detail: String?
        var succeeded: Bool
    }

    static let height: CGFloat = 44
    static let preferredWidth: CGFloat = 340

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        alphaValue = 0
        isHidden = true

        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        titleLabel.font = UIFonts.system(size: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        detailLabel.font = UIFonts.monospaced(size: 10.5, weight: .regular)
        detailLabel.textColor = NSColor(white: 1, alpha: 0.62)
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Never takes clicks: it sits over the terminal, which must keep receiving them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 18) / 2, width: 18, height: 18)
        let x: CGFloat = 38
        let w = max(0, bounds.width - x - 12)
        if detailLabel.stringValue.isEmpty {
            titleLabel.frame = NSRect(x: x, y: (h - 16) / 2, width: w, height: 16)
        } else {
            titleLabel.frame = NSRect(x: x, y: h / 2, width: w, height: 16)
            detailLabel.frame = NSRect(x: x, y: h / 2 - 15, width: w, height: 14)
        }
    }

    func show(_ message: Message, accent: NSColor, warning: NSColor) {
        titleLabel.stringValue = message.title
        detailLabel.stringValue = message.detail ?? ""
        // Copied text in the terminal's kind of type; a reason in ordinary type.
        detailLabel.font = message.succeeded ? UIFonts.monospaced(size: 10.5, weight: .regular)
                                             : UIFonts.system(size: 11)
        let symbol = message.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.image = image?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.contentTintColor = message.succeeded ? accent : warning
        needsLayout = true

        hideWork?.cancel()
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (message.succeeded ? 1.6 : 2.2), execute: work)
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.isHidden = true
        })
    }

    var isShowing: Bool { !isHidden }

    // MARK: Wording

    /// What a successful copy says: which kind, how much, and how it starts.
    static func message(copied text: String, target: TerminalPane.CopyTarget) -> Message {
        let what: String = switch target {
        case .selection: "Copied selection"
        case .lastCommandOutput: "Copied last command and output"
        case .wholeTerminal: "Copied whole terminal"
        case .lastCommand: "Copied last command"
        }
        return Message(title: what + " · " + size(of: text), detail: preview(of: text), succeeded: true)
    }

    /// What an empty copy says, so a press that did nothing does not look like one that worked.
    static func message(nothingFor target: TerminalPane.CopyTarget) -> Message {
        let why: String = switch target {
        case .selection: "Nothing is selected."
        case .lastCommandOutput, .lastCommand: "No command has run in this terminal yet."
        case .wholeTerminal: "The terminal is empty."
        }
        return Message(title: "Nothing copied", detail: why, succeeded: false)
    }

    /// "12 lines", or "1 line · 18 characters" for something short enough that lines say little.
    static func size(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines > 1 { return "\(lines.formatted()) lines" }
        let chars = text.count
        return chars == 1 ? "1 character" : "\(chars.formatted()) characters"
    }

    /// The first line with anything on it, shortened to fit.
    static func preview(of text: String, limit: Int = 60) -> String? {
        guard let line = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
