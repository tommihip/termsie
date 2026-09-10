import AppKit

/// A top-down form for settings tabs.
///
/// The view is flipped, so children keep their distance from the top when the tab grows, and
/// adding a setting is a single `checkbox(...)` call rather than another hand-computed frame.
final class SettingsForm: NSView, NSTextFieldDelegate {
    /// Checkboxes bound to a boolean config key, so `refresh()` can re-read them all.
    private var boundChecks: [(button: NSButton, keyPath: WritableKeyPath<TermsieConfig, Bool>)] = []
    /// Number fields bound to a numeric config key. Doubles cover the integer settings too;
    /// `isInteger` only decides how the value is displayed and rounded on the way back.
    private var boundNumbers: [BoundNumber] = []
    private var cursorY: CGFloat = 16
    private let margin: CGFloat = 16

    private struct BoundNumber {
        let field: NSTextField
        let stepper: NSStepper
        let label: String
        let keyPath: WritableKeyPath<TermsieConfig, Double>
        let range: ClosedRange<Double>
        let isInteger: Bool
    }

    override var isFlipped: Bool { true }

    var contentHeight: CGFloat { cursorY }

    /// A bold heading introducing a group of related settings.
    func section(_ title: String) {
        if !boundChecks.isEmpty || !boundNumbers.isEmpty { cursorY += 10 }
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

    /// A labelled number field with a stepper, wired straight to a numeric config value.
    ///
    /// Integer settings are bound through a `Double` key path proxy on `TermsieConfig` rather than
    /// a second generic overload: one storage type here keeps `refresh()` a single loop.
    @discardableResult
    func number(_ title: String, _ keyPath: WritableKeyPath<TermsieConfig, Double>,
                range: ClosedRange<Double>, step: Double = 1, isInteger: Bool = false,
                suffix: String? = nil, hint: String? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: margin, y: cursorY + 3, width: 300, height: 18)
        addSubview(label)

        let field = NSTextField()
        field.frame = NSRect(x: margin + 310, y: cursorY + 1, width: 54, height: 22)
        field.alignment = .right
        field.delegate = self
        addSubview(field)

        let stepper = NSStepper()
        stepper.frame = NSRect(x: margin + 368, y: cursorY, width: 19, height: 24)
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        addSubview(stepper)

        if let suffix {
            let unit = NSTextField(labelWithString: suffix)
            unit.font = UIFonts.system(size: 11)
            unit.textColor = .tertiaryLabelColor
            unit.frame = NSRect(x: margin + 392, y: cursorY + 4, width: 60, height: 16)
            addSubview(unit)
        }

        boundNumbers.append(BoundNumber(field: field, stepper: stepper, label: title,
                                        keyPath: keyPath, range: range, isInteger: isInteger))
        show(boundNumbers[boundNumbers.count - 1], value: ConfigStore.shared.config[keyPath: keyPath])
        cursorY += 26
        if let hint { self.hint(hint) } else { cursorY += 6 }
        return field
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
        for bound in boundNumbers {
            // Not while it is being typed into: rewriting the field under the caret would fight
            // the user for every keystroke.
            guard window?.firstResponder !== bound.field.currentEditor() else { continue }
            show(bound, value: config[keyPath: bound.keyPath])
        }
    }

    private func show(_ bound: BoundNumber, value: Double) {
        let clamped = min(max(value, bound.range.lowerBound), bound.range.upperBound)
        bound.field.stringValue = bound.isInteger
            ? String(Int(clamped.rounded()))
            : String(format: "%g", clamped)
        bound.stepper.doubleValue = clamped
    }

    private func store(_ bound: BoundNumber, value: Double) {
        var clamped = min(max(value, bound.range.lowerBound), bound.range.upperBound)
        if bound.isInteger { clamped = clamped.rounded() }
        ConfigStore.shared.update { $0[keyPath: bound.keyPath] = clamped }
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

    /// Sets a bound number by its label, so tests drive the real binding.
    @discardableResult
    func setNumber(titled substring: String, to value: Double) -> Bool {
        guard let bound = boundNumbers.first(where: {
            $0.label.range(of: substring, options: .caseInsensitive) != nil
        }) else { return false }
        store(bound, value: value)
        show(bound, value: ConfigStore.shared.config[keyPath: bound.keyPath])
        return true
    }

    /// The number currently shown, for assertions.
    func numberState(titled substring: String) -> Double? {
        boundNumbers.first {
            $0.label.range(of: substring, options: .caseInsensitive) != nil
        }.map { Double($0.stepper.doubleValue) }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let bound = boundChecks.first(where: { $0.button === sender }) else { return }
        let value = sender.state == .on
        ConfigStore.shared.update { $0[keyPath: bound.keyPath] = value }
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        guard let bound = boundNumbers.first(where: { $0.stepper === sender }) else { return }
        store(bound, value: sender.doubleValue)
        show(bound, value: ConfigStore.shared.config[keyPath: bound.keyPath])
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let bound = boundNumbers.first(where: { $0.field === field }),
              let value = Double(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        bound.stepper.doubleValue = min(max(value, bound.range.lowerBound), bound.range.upperBound)
        store(bound, value: value)
    }

    /// An unparseable or out-of-range entry snaps back to what was actually stored, rather than
    /// leaving the field showing a number the config does not hold.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let bound = boundNumbers.first(where: { $0.field === field }) else { return }
        show(bound, value: ConfigStore.shared.config[keyPath: bound.keyPath])
    }
}
