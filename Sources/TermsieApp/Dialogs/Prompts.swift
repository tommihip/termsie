import Foundation
import TermsieCore

// MARK: - Simple prompts

/// One line of text, with OK and Cancel: rename a terminal.
final class PromptDialog: FormWindow {
    static func run(owner: WindowRef?, title: String, message: String, initial: String) -> String? {
        let dialog = PromptDialog()
        dialog.labelWidth = 80
        dialog.fieldWidth = 300
        guard dialog.build(title: title, owner: owner,
                           fields: [Field("note", "", .note(message)), Field("value", "Name", .text(initial))],
                           buttons: [ButtonSpec(id: FormWindow.ok, title: "OK", isDefault: true),
                                     ButtonSpec(id: FormWindow.cancel, title: "Cancel")]) else { return nil }
        dialog.focus("value")
        var value: String?
        dialog.onAccept = { value = dialog.text("value") }
        dialog.runModal()
        return value
    }

    var onAccept: (() -> Void)?

    override func buttonPressed(_ id: Int32) {
        if id == FormWindow.ok { onAccept?() }
        finish(id)
    }
}

/// Save Workspace As: a name, and whether to fold in what is running now.
final class SaveWorkspaceDialog: FormWindow {
    struct Answer {
        var name: String
        var includeRunning: Bool
    }

    static func run(owner: WindowRef?, name: String) -> Answer? {
        let dialog = SaveWorkspaceDialog()
        dialog.labelWidth = 120
        dialog.fieldWidth = 300
        let folder = HomePath.abbreviate(ConfigStore.shared.workspacesDir.path)
        guard dialog.build(title: "Save Workspace", owner: owner, fields: [
            Field("note", "", .note("Saves this tab's terminals, their folders and their startup commands to \(folder).")),
            Field("name", "Workspace name", .text(name)),
            Field("running", "Include commands currently running", .check(false)),
        ], buttons: [ButtonSpec(id: FormWindow.ok, title: "Save", isDefault: true), ButtonSpec(id: FormWindow.cancel, title: "Cancel")])
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
        if id == FormWindow.ok { onAccept?() }
        finish(id)
    }
}
