import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// Environment variables as editable text, one per line:
///
///     NAME=value            a plain variable
///     secret NAME           a secret whose stored value is kept
///     secret NAME=value     a secret given a new value, stored in the Credential Manager
///
/// A secret's value is never written into the text, so it never appears on screen.
enum EnvText {
    static let help = "One per line: NAME=value. A secret is “secret NAME=value”; once saved it shows as “secret NAME” and its value stays in the Credential Manager."

    static func render(_ vars: [EnvVar]) -> String {
        vars.map { $0.secret ? "secret \($0.name)" : "\($0.name)=\($0.value)" }.joined(separator: "\n")
    }

    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reads the text back. New secret values go into the store under fresh references, which
    /// are returned so a cancelled edit can give them back.
    static func parse(_ text: String, previous: [EnvVar], owner: String) throws -> (vars: [EnvVar], created: [String]) {
        var out: [EnvVar] = []
        var created: [String] = []
        var seen = Set<String>()
        for (i, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var isSecret = false
            var body = line
            if line.lowercased().hasPrefix("secret ") {
                isSecret = true
                body = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            let name: String
            var value: String?
            if let eq = body.firstIndex(of: "=") {
                name = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
                value = String(body[body.index(after: eq)...])
            } else {
                name = body
            }
            if let problem = EnvVar.problem(withName: name) { throw ParseError(message: "line \(i + 1): \(problem)") }
            guard seen.insert(name).inserted else { throw ParseError(message: "line \(i + 1): “\(name)” is set twice") }
            if isSecret {
                if let value, !value.isEmpty {
                    let ref = SecretStore.newRef()
                    guard SecretStore.setValue(value, for: ref, label: "Termsie: \(name) (\(owner))") else {
                        throw ParseError(message: "line \(i + 1): the secret could not be stored")
                    }
                    created.append(ref)
                    out.append(EnvVar(name: name, secret: true, secretRef: ref))
                } else if let old = previous.first(where: { $0.name == name && $0.secret }) {
                    out.append(old)
                } else {
                    throw ParseError(message: "line \(i + 1): secret “\(name)” has no stored value — write it as secret \(name)=value")
                }
            } else {
                guard let value else { throw ParseError(message: "line \(i + 1): “\(name)” needs a value: \(name)=value") }
                out.append(EnvVar(name: name, value: value))
            }
        }
        return (out, created)
    }
}

/// Optional numbers in a text field: empty means "inherit".
enum OptionalNumber {
    static func render(_ d: Double?) -> String {
        guard let d else { return "" }
        return d == d.rounded() ? String(Int(d)) : String(d)
    }

    static func parse(_ s: String, range: ClosedRange<Double>, label: String) throws -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        guard let d = Double(t), range.contains(d) else {
            throw EnvText.ParseError(message: "\(label) must be a number from \(OptionalNumber.render(range.lowerBound)) to \(OptionalNumber.render(range.upperBound)), or empty to inherit")
        }
        return d
    }
}

/// One terminal's settings: the Windows counterpart of the popover the macOS terminal list opens.
final class TerminalSettingsDialog: FormWindow {
    private weak var tab: TabController?
    private var definitionID = ""
    private var environments: [TermsieConfig.EnvironmentStyle] = []
    private var fonts: [String] = []
    private static let runNowID: Int32 = 10
    private static let workspaceID: Int32 = 11

    static func show(definitionID: String, tab: TabController, owner: HWND?) {
        guard let def = tab.registry.definition(definitionID) else { return }
        let dialog = TerminalSettingsDialog()
        dialog.tab = tab
        dialog.definitionID = definitionID
        let config = ConfigStore.shared.config
        dialog.environments = config.environments
        dialog.fonts = FontCache.families(monospacedOnly: true)
        let envIndex = (def.environment.flatMap { id in config.environments.firstIndex { $0.id == id } } ?? -1) + 1
        let wrapIndex = def.lineWrap.map { $0 ? 1 : 2 } ?? 0
        let inherited = tab.registry.settings.applied(to: TerminalDefinition())
        let fontHint = "Empty uses \(inherited.fontFamily ?? config.font.family) \(OptionalNumber.render(inherited.fontSize ?? config.font.size)) pt"
        guard dialog.build(title: "Terminal Settings — \(def.displayName)", owner: owner, fields: [
            Field("name", "Name", .text(def.name ?? "")),
            Field("cwd", "Working folder", .text(def.cwd ?? ""), accessory: "Browse…"),
            Field("environment", "Environment", .choice(["None"] + config.environments.map(\.label), selected: envIndex)),
            Field("commands", "Startup commands", .multiline(def.startupCommands.joined(separator: "\n"), lines: 5, monospace: true)),
            Field("reopen", "Run them when reopened", .check(def.runCommandsOnReopen)),
            Field("history", "Own command history", .check(def.isolatedHistory)),
            Field("heading", "", .heading("Text")),
            Field("fontFamily", "Font", .combo([""] + dialog.fonts, text: def.fontFamily ?? "")),
            Field("fontSize", "Size", .text(OptionalNumber.render(def.fontSize))),
            Field("fontNote", "", .note(fontHint)),
            Field("padding", "Padding", .text(OptionalNumber.render(def.padding))),
            Field("wrap", "Long lines", .choice(["Inherit", "Wrap", "Don't wrap"], selected: wrapIndex)),
            Field("heading2", "", .heading("Environment variables")),
            Field("env", "Variables", .multiline(EnvText.render(def.env), lines: 4, monospace: true)),
            Field("envNote", "", .note(EnvText.help)),
        ], buttons: [
            ButtonSpec(id: runNowID, title: "Run Now"),
            ButtonSpec(id: workspaceID, title: "Workspace…"),
            ButtonSpec(id: Win.IDCANCEL, title: "Cancel"),
            ButtonSpec(id: Win.IDOK, title: "OK", isDefault: true),
        ]) else { return }
        dialog.focus("name")
        dialog.runModal()
    }

    override func accessoryPressed(_ key: String) {
        guard key == "cwd" else { return }
        let start = HomePath.expand(text("cwd"))
        if let folder = FileDialog.folder(owner: hwnd, title: "Working Folder", start: start.isEmpty ? HomePath.home : start) {
            setText("cwd", HomePath.abbreviate(folder))
        }
    }

    override func buttonPressed(_ id: Int32) {
        guard let tab else { finish(id); return }
        switch id {
        case Win.IDOK:
            if apply() { finish(id) }
        case TerminalSettingsDialog.runNowID:
            let commands = text("commands").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            guard !commands.isEmpty else { Shell.beep(); return }
            if let pane = tab.registry.pane(for: definitionID) {
                pane.runCommandsNow(commands)
            } else {
                Shell.beep()
            }
        case TerminalSettingsDialog.workspaceID:
            if apply() {
                finish(id)
                let target = definitionID
                MainQueue.shared.async { [weak tab] in tab?.showWorkspaceSettings(selecting: target) }
            }
        default:
            finish(id)
        }
    }

    /// Validates and writes the settings back. False leaves the dialog open with a message.
    private func apply() -> Bool {
        guard let tab, let def = tab.registry.definition(definitionID) else { return true }
        do {
            let fontSize = try OptionalNumber.parse(text("fontSize"), range: TermsieConfig.minFontSize...TermsieConfig.maxFontSize,
                                                    label: "Size")
            let padding = try OptionalNumber.parse(text("padding"), range: 0...TermsieConfig.maxPadding, label: "Padding")
            let parsed = try EnvText.parse(text("env"), previous: def.env, owner: def.displayName)
            let envIndex = selection("environment")
            let environment = envIndex > 0 && envIndex - 1 < environments.count ? environments[envIndex - 1].id : nil
            let wrap = selection("wrap")
            let oldRefs = Set(def.env.compactMap(\.secretRef))
            let name = text("name").trimmingCharacters(in: .whitespaces)
            let cwd = text("cwd").trimmingCharacters(in: .whitespaces)
            let family = text("fontFamily").trimmingCharacters(in: .whitespaces)
            tab.registry.mutate(definitionID) { d in
                d.name = name.isEmpty ? nil : name
                d.cwd = cwd.isEmpty ? nil : cwd
                d.environment = environment
                d.startupCommands = text("commands").components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                d.runCommandsOnReopen = checked("reopen")
                d.isolatedHistory = checked("history")
                d.fontFamily = family.isEmpty ? nil : family
                d.fontSize = fontSize
                d.padding = padding
                d.lineWrap = wrap == 1 ? true : wrap == 2 ? false : nil
                d.env = parsed.vars
            }
            let newRefs = Set(parsed.vars.compactMap(\.secretRef))
            SecretStore.discard(oldRefs.subtracting(newRefs))
            tab.stateChanged()
            return true
        } catch {
            Alert.error("Check the settings", error.localizedDescription, owner: hwnd)
            return false
        }
    }
}
