import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// The global settings, in pages: General, Appearance, Copy and History, Environments.
/// Everything here is config.json, which can also be edited directly and reloads on save.
final class SettingsDialog: FormWindow {
    private static let editConfigID: Int32 = 30
    private var fonts: [String] = []

    private static let cursorStyles = ["block", "bar", "underline", "blinkBlock", "blinkBar", "blinkUnderline"]
    private static let cursorLabels = ["Block", "Bar", "Underline", "Blinking block", "Blinking bar", "Blinking underline"]
    private static let bells = ["none", "sound", "visual", "both"]
    private static let bellLabels = ["None", "Sound", "Flash the badge", "Sound and badge"]
    private static let exits = ["clean", "always", "never"]
    private static let exitLabels = ["When it exits cleanly", "Always", "Never"]

    static func show(owner: HWND?, page: Int = 1) {
        let config = ConfigStore.shared.config
        let dialog = SettingsDialog()
        dialog.fonts = FontCache.families(monospacedOnly: true)
        dialog.labelWidth = 220
        dialog.fieldWidth = 360
        let cursor = cursorStyles.firstIndex { $0.lowercased() == config.cursorStyle.lowercased() } ?? 0
        let bell = bells.firstIndex(of: config.bell.lowercased()) ?? 2
        let exit = exits.firstIndex(of: config.closePaneOnExit.lowercased()) ?? 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let environments = (try? encoder.encode(config.environments)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let defaultShell = ShellLocator.defaultWindowsShell()
        guard dialog.build(title: "Termsie Settings", owner: owner, fields: [
            Field("page", "Section", .choice(["General", "Appearance", "Copy and History", "Environments"], selected: page - 1)),
            // General
            Field("shell", "Shell", .text(config.shell ?? ""), accessory: "Browse…", page: 1),
            Field("shellNote", "", .note("Empty uses \(HomePath.lastComponent(defaultShell)). Any program works: pwsh, cmd, wsl.exe, Git Bash."), page: 1),
            Field("shellArgs", "Shell arguments", .text(config.shellArgs.map(WindowsCommandLine.quote).joined(separator: " ")), page: 1),
            Field("integration", "Shell integration", .choice(["On (history, startup commands, marks)", "Off"],
                                                              selected: config.shellIntegration.lowercased() == "off" ? 1 : 0), page: 1),
            Field("scrollback", "Scrollback lines", .text(String(config.scrollback)), page: 1),
            Field("kept", "Output kept when a terminal closes", .text(String(config.restoredOutputLines)), page: 1),
            Field("exit", "Close a terminal when its shell exits", .choice(exitLabels, selected: exit), page: 1),
            Field("confirm", "Ask before ending running programs", .check(config.confirmClosingRunningProcess), page: 1),
            Field("restore", "Reopen the last session at launch", .check(config.restoreSession), page: 1),
            Field("ask", "Ask before running startup commands", .check(config.startupCommands.askBeforeRunning), page: 1),
            Field("echo", "Show startup commands as they run", .check(config.startupCommands.echo), page: 1),
            Field("updates", "Check for updates daily", .check(config.updates.checkAutomatically), page: 1),
            // Appearance
            Field("fontFamily", "Font", .combo(dialog.fonts, text: config.font.family), page: 2),
            Field("fontSize", "Font size", .text(OptionalNumber.render(config.font.size)), page: 2),
            Field("cursor", "Cursor", .choice(cursorLabels, selected: cursor), page: 2),
            Field("bell", "Bell", .choice(bellLabels, selected: bell), page: 2),
            Field("opacity", "Opacity (0.25 to 1)", .text(String(config.opacity)), page: 2),
            Field("blur", "Translucent, with the backdrop blurred", .check(config.blurBackground), page: 2),
            Field("blurNote", "", .note("The blurred backdrop needs Windows 11 22H2 or later; elsewhere terminals are opaque."), page: 2),
            Field("padding", "Padding", .text(OptionalNumber.render(config.terminalPadding)), page: 2),
            Field("wrap", "Wrap long lines", .check(config.lineWrap), page: 2),
            Field("columns", "Columns when not wrapping", .text(String(config.unwrappedColumns)), page: 2),
            Field("headers", "Terminal headers", .check(config.showPaneHeaders), page: 2),
            Field("lights", "Close, collapse and zoom buttons", .check(config.trafficLights), page: 2),
            Field("scale", "Scale terminals with the window", .check(config.resizeTerminalsWithWindow), page: 2),
            Field("snap", "Resize in whole character cells", .check(config.snapToCells), page: 2),
            // Copy and history
            Field("autoCopy", "Copy a selection as it is made", .check(config.copy.autoCopyOnSelect), page: 3),
            Field("tools", "Show the copy tools in the list", .check(config.copy.showTools), page: 3),
            Field("marks", "Mark commands (OSC 133) for the copy tools", .check(config.copy.commandMarks), page: 3),
            Field("trim", "Trim blank space from copied text", .check(config.copy.trimCopiedText), page: 3),
            Field("isolate", "Each terminal keeps its own history", .check(config.history.isolate), page: 3),
            Field("merge", "Add a terminal's history to the shared one on exit", .check(config.history.mergeToGlobalOnExit), page: 3),
            Field("retention", "Forget deleted terminals' history after (days)", .text(String(config.history.retentionDays)), page: 3),
            // Environments
            Field("environments", "Environments", .multiline(environments, lines: 18, monospace: true), page: 4),
            Field("envNote", "", .note("Each has an id, a label, a tint (#rrggbb) and a strength from 0 to 1. A terminal's environment tints its background, header and list row."), page: 4),
        ], buttons: [
            ButtonSpec(id: editConfigID, title: "config.json…"),
            ButtonSpec(id: Win.IDCANCEL, title: "Cancel"),
            ButtonSpec(id: Win.IDOK, title: "OK", isDefault: true),
        ]) else { return }
        dialog.showPage(page)
        dialog.runModal()
    }

    override func selectionChanged(_ key: String) {
        if key == "page" { showPage(selection("page") + 1) }
    }

    override func accessoryPressed(_ key: String) {
        guard key == "shell" else { return }
        if let path = FileDialog.open(owner: hwnd, title: "Shell", filterName: "Programs", filterSpec: "*.exe",
                                      folder: "C:\\Windows\\System32") {
            setText("shell", path)
        }
    }

    override func buttonPressed(_ id: Int32) {
        switch id {
        case Win.IDOK:
            if save() { finish(id) }
        case SettingsDialog.editConfigID:
            Shell.open(ConfigStore.shared.configURL.path)
        default:
            finish(id)
        }
    }

    private func integer(_ key: String, _ label: String, _ range: ClosedRange<Int>) throws -> Int {
        let t = text(key).trimmingCharacters(in: .whitespaces)
        guard let n = Int(t), range.contains(n) else {
            throw EnvText.ParseError(message: "\(label) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return n
    }

    private func save() -> Bool {
        do {
            let fontSize = try OptionalNumber.parse(text("fontSize"), range: TermsieConfig.minFontSize...TermsieConfig.maxFontSize,
                                                    label: "Font size") ?? 13
            guard let opacity = Double(text("opacity").trimmingCharacters(in: .whitespaces)), (0.25...1).contains(opacity) else {
                throw EnvText.ParseError(message: "Opacity must be a number from 0.25 to 1")
            }
            let padding = try OptionalNumber.parse(text("padding"), range: 0...TermsieConfig.maxPadding, label: "Padding") ?? 0
            let scrollback = try integer("scrollback", "Scrollback", 0...1_000_000)
            let kept = try integer("kept", "Output kept", 0...TermsieConfig.maxRestoredOutputLines)
            let columns = try integer("columns", "Columns", TermsieConfig.minUnwrappedColumns...TermsieConfig.maxUnwrappedColumns)
            let retention = try integer("retention", "History retention", 1...3650)
            let envText = text("environments")
            let environments: [TermsieConfig.EnvironmentStyle]
            do {
                environments = try JSONDecoder().decode([TermsieConfig.EnvironmentStyle].self, from: Data(envText.utf8))
            } catch {
                throw EnvText.ParseError(message: "Environments must be a JSON list of {\"id\", \"label\", \"tint\", \"strength\"}")
            }
            let shell = text("shell").trimmingCharacters(in: .whitespaces)
            let args = ProcessInfoReader.splitCommandLine(text("shellArgs"))
            let family = text("fontFamily").trimmingCharacters(in: .whitespaces)
            ConfigStore.shared.update { c in
                c.shell = shell.isEmpty ? nil : shell
                c.shellArgs = args
                c.shellIntegration = selection("integration") == 1 ? "off" : "auto"
                c.scrollback = scrollback
                c.restoredOutputLines = kept
                c.closePaneOnExit = SettingsDialog.exits[max(0, selection("exit"))]
                c.confirmClosingRunningProcess = checked("confirm")
                c.restoreSession = checked("restore")
                c.startupCommands.askBeforeRunning = checked("ask")
                c.startupCommands.echo = checked("echo")
                c.updates.checkAutomatically = checked("updates")
                if !family.isEmpty { c.font.family = family }
                c.font.size = fontSize
                c.cursorStyle = SettingsDialog.cursorStyles[max(0, selection("cursor"))]
                c.bell = SettingsDialog.bells[max(0, selection("bell"))]
                c.opacity = opacity
                c.blurBackground = checked("blur")
                c.terminalPadding = padding
                c.lineWrap = checked("wrap")
                c.unwrappedColumns = columns
                c.showPaneHeaders = checked("headers")
                c.trafficLights = checked("lights")
                c.resizeTerminalsWithWindow = checked("scale")
                c.snapToCells = checked("snap")
                c.copy.autoCopyOnSelect = checked("autoCopy")
                c.copy.showTools = checked("tools")
                c.copy.commandMarks = checked("marks")
                c.copy.trimCopiedText = checked("trim")
                c.history.isolate = checked("isolate")
                c.history.mergeToGlobalOnExit = checked("merge")
                c.history.retentionDays = retention
                c.environments = environments
            }
            return true
        } catch {
            Alert.error("Check the settings", error.localizedDescription, owner: hwnd)
            return false
        }
    }
}
