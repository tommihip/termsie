import AppKit

/// A top-down form for settings tabs.
///
/// The view is flipped, so children keep their distance from the top when the tab grows, and
/// adding a setting is a single `checkbox(...)` call rather than another hand-computed frame.
final class SettingsForm: NSView {
    /// Checkboxes bound to a boolean config key, so `refresh()` can re-read them all.
    private var boundChecks: [(button: NSButton, keyPath: WritableKeyPath<TermsieConfig, Bool>)] = []
    private var cursorY: CGFloat = 16
    private let margin: CGFloat = 16

    override var isFlipped: Bool { true }

    var contentHeight: CGFloat { cursorY }

    /// A bold heading introducing a group of related settings.
    func section(_ title: String) {
        if !boundChecks.isEmpty { cursorY += 10 }
        let label = NSTextField(labelWithString: title)
        label.font = UIFonts.system(size: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: margin, y: cursorY, width: bounds.width - 2 * margin, height: 16)
        label.autoresizingMask = [.width]
        addSubview(label)
        cursorY += 22
    }

    /// A checkbox wired straight to a boolean in the config.
    @discardableResult
    func checkbox(_ title: String, _ keyPath: WritableKeyPath<TermsieConfig, Bool>,
                  hint: String? = nil) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleChanged(_:)))
        button.frame = NSRect(x: margin, y: cursorY, width: bounds.width - 2 * margin, height: 20)
        button.autoresizingMask = [.width]
        button.state = ConfigStore.shared.config[keyPath: keyPath] ? .on : .off
        addSubview(button)
        boundChecks.append((button, keyPath))
        cursorY += 20
        if let hint { self.hint(hint) } else { cursorY += 6 }
        return button
    }

    /// Explanatory text under the preceding control.
    func hint(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = UIFonts.system(size: 11)
        label.textColor = .tertiaryLabelColor
        let width = bounds.width - 2 * margin - 20
        label.frame = NSRect(x: margin + 20, y: cursorY + 1, width: width, height: 0)
        label.autoresizingMask = [.width]
        addSubview(label)
        let fitted = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        label.frame.size.height = fitted.height
        cursorY += fitted.height + 8
    }

    /// Re-reads every bound control, for when config.json changes underneath us.
    func refresh() {
        let config = ConfigStore.shared.config
        for bound in boundChecks {
            bound.button.state = config[keyPath: bound.keyPath] ? .on : .off
        }
    }

    /// Clicks a bound checkbox by title, so tests exercise the real binding rather than
    /// re-testing ConfigStore underneath it.
    @discardableResult
    func clickCheckbox(titled substring: String) -> Bool {
        guard let bound = boundChecks.first(where: {
            $0.button.title.range(of: substring, options: .caseInsensitive) != nil
        }) else { return false }
        bound.button.performClick(nil)
        return true
    }

    /// The on/off state currently shown, for assertions.
    func checkboxState(titled substring: String) -> Bool? {
        boundChecks.first {
            $0.button.title.range(of: substring, options: .caseInsensitive) != nil
        }.map { $0.button.state == .on }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let bound = boundChecks.first(where: { $0.button === sender }) else { return }
        let value = sender.state == .on
        ConfigStore.shared.update { $0[keyPath: bound.keyPath] = value }
    }
}
