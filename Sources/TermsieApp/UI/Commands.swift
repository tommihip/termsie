import Foundation
import CTermsieHost
import TermsieCore

/// Every action the menu and the keyboard can trigger.
enum Command: Hashable {
    // App and window
    case newWindow, newTab, closeTab, nextTab, previousTab, moveTabToNewWindow, mergeAllWindows
    case settings, environments, editConfig, reloadConfig, showConfigFolder, checkForUpdates, about, exit
    case fullScreen, toggleSidebar
    // Workspaces
    case newWorkspace, workspaceSettings, saveWorkspace, saveWorkspaceAs, openWorkspaceFile, showWorkspacesFolder
    case openWorkspace(String)
    // Terminals
    case newTerminal, newTerminalTiled, duplicateTerminal, terminalSettings, renameTerminal, clearScrollback
    case runStartupCommands, runAllStartupCommands, closeTerminal, deleteTerminal
    case copy, paste, selectAll, copyLastCommandOutput, copyLastCommand, copyWholeTerminal, autoCopy
    case find, findNext, findPrevious
    case maximize, collapse, tileGrid, cascade, leftHalf, rightHalf, topHalf, bottomHalf, center
    case bringToFront, sendToBack, toggleHeaders, broadcast
    case focusLeft, focusRight, focusUp, focusDown, nextTerminal, previousTerminal
    case terminal(Int)
    case biggerText, smallerText, defaultTextSize
    case environment(String)

    var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .moveTabToNewWindow: return "Move Tab to New Window"
        case .mergeAllWindows: return "Merge All Windows"
        case .settings: return "Settings…"
        case .environments: return "Manage Environments…"
        case .editConfig: return "Edit config.json…"
        case .reloadConfig: return "Reload Settings"
        case .showConfigFolder: return "Show Config Folder"
        case .checkForUpdates: return "Check for Updates…"
        case .about: return "About Termsie"
        case .exit: return "Exit"
        case .fullScreen: return "Full Screen"
        case .toggleSidebar: return "Terminal List"
        case .newWorkspace: return "New Workspace"
        case .workspaceSettings: return "Workspace Settings…"
        case .saveWorkspace: return "Save Workspace"
        case .saveWorkspaceAs: return "Save Workspace As…"
        case .openWorkspaceFile: return "Open Workspace File…"
        case .showWorkspacesFolder: return "Show Workspaces Folder"
        case .openWorkspace(let name): return name
        case .newTerminal: return "New Terminal"
        case .newTerminalTiled: return "New Terminal, Tile All"
        case .duplicateTerminal: return "Duplicate Terminal"
        case .terminalSettings: return "Terminal Settings…"
        case .renameTerminal: return "Set Terminal Name…"
        case .clearScrollback: return "Clear Scrollback"
        case .runStartupCommands: return "Run Startup Commands"
        case .runAllStartupCommands: return "Run All Startup Commands"
        case .closeTerminal: return "Close Terminal"
        case .deleteTerminal: return "Delete Terminal"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        case .copyLastCommandOutput: return CopyTarget.lastCommandOutput.title
        case .copyLastCommand: return CopyTarget.lastCommand.title
        case .copyWholeTerminal: return CopyTarget.wholeTerminal.title
        case .autoCopy: return "Auto-Copy Selection"
        case .find: return "Find…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .maximize: return "Maximize Terminal"
        case .collapse: return "Collapse Terminal"
        case .tileGrid: return "Tile Grid"
        case .cascade: return "Cascade"
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .center: return "Center"
        case .bringToFront: return "Bring to Front"
        case .sendToBack: return "Send to Back"
        case .toggleHeaders: return "Terminal Headers"
        case .broadcast: return "Broadcast Input to All Terminals"
        case .focusLeft: return "Focus Terminal Left"
        case .focusRight: return "Focus Terminal Right"
        case .focusUp: return "Focus Terminal Above"
        case .focusDown: return "Focus Terminal Below"
        case .nextTerminal: return "Next Terminal"
        case .previousTerminal: return "Previous Terminal"
        case .terminal(let n): return "Terminal \(n)"
        case .biggerText: return "Bigger Text"
        case .smallerText: return "Smaller Text"
        case .defaultTextSize: return "Default Text Size"
        case .environment(let id):
            if id.isEmpty { return "None" }
            return ConfigStore.shared.config.environment(id)?.label ?? id
        }
    }
}

/// A key and its modifiers.
struct Shortcut: Hashable {
    var key: Key
    var ctrl = false
    var shift = false
    var alt = false

    var label: String {
        var parts: [String] = []
        if ctrl { parts.append("Ctrl") }
        if alt { parts.append("Alt") }
        if shift { parts.append("Shift") }
        parts.append(key.name)
        return parts.joined(separator: "+")
    }
}

enum Keymap {
    /// macOS's ⌘ becomes Ctrl+Shift, as in Windows Terminal and GNOME Terminal, so that every
    /// plain Ctrl+letter still reaches the shell (Ctrl+C, Ctrl+D, Ctrl+R…). Three-modifier
    /// chords stand in for ⌥⌘ and ⌃⌘ where two would collide.
    static let bindings: [(Shortcut, Command)] = {
        var b: [(Shortcut, Command)] = [
            (Shortcut(key: .char("N"), ctrl: true, shift: true), .newWindow),
            (Shortcut(key: .char("T"), ctrl: true, shift: true), .newTab),
            (Shortcut(key: .tab, ctrl: true), .nextTab),
            (Shortcut(key: .tab, ctrl: true, shift: true), .previousTab),
            (Shortcut(key: .pageDown, ctrl: true), .nextTab),
            (Shortcut(key: .pageUp, ctrl: true), .previousTab),
            (Shortcut(key: .char(","), ctrl: true), .settings),
            (Shortcut(key: .char(","), ctrl: true, shift: true), .workspaceSettings),
            (Shortcut(key: .f(5), ctrl: true, shift: true), .reloadConfig),
            (Shortcut(key: .f(11)), .fullScreen),
            (Shortcut(key: .char("B"), ctrl: true, shift: true), .toggleSidebar),
            (Shortcut(key: .char("S"), ctrl: true, shift: true), .saveWorkspace),
            (Shortcut(key: .char("S"), ctrl: true, shift: true, alt: true), .saveWorkspaceAs),
            (Shortcut(key: .char("O"), ctrl: true, shift: true), .openWorkspaceFile),
            (Shortcut(key: .char("D"), ctrl: true, shift: true), .newTerminal),
            (Shortcut(key: .char("D"), ctrl: true, shift: true, alt: true), .newTerminalTiled),
            (Shortcut(key: .char("I"), ctrl: true, shift: true), .terminalSettings),
            (Shortcut(key: .char("R"), ctrl: true, shift: true), .renameTerminal),
            (Shortcut(key: .char("K"), ctrl: true, shift: true), .clearScrollback),
            (Shortcut(key: .char("W"), ctrl: true, shift: true), .closeTerminal),
            (Shortcut(key: .delete, ctrl: true, shift: true), .deleteTerminal),
            (Shortcut(key: .char("C"), ctrl: true, shift: true), .copy),
            (Shortcut(key: .insert, ctrl: true), .copy),
            (Shortcut(key: .char("V"), ctrl: true, shift: true), .paste),
            (Shortcut(key: .insert, shift: true), .paste),
            (Shortcut(key: .char("A"), ctrl: true, shift: true), .selectAll),
            (Shortcut(key: .char("C"), ctrl: true, shift: true, alt: true), .copyLastCommandOutput),
            (Shortcut(key: .char("L"), ctrl: true, shift: true, alt: true), .copyLastCommand),
            (Shortcut(key: .char("A"), ctrl: true, shift: true, alt: true), .copyWholeTerminal),
            (Shortcut(key: .char("F"), ctrl: true, shift: true), .find),
            (Shortcut(key: .f(3)), .findNext),
            (Shortcut(key: .f(3), shift: true), .findPrevious),
            (Shortcut(key: .enter, ctrl: true, shift: true), .maximize),
            (Shortcut(key: .char("G"), ctrl: true, shift: true), .tileGrid),
            (Shortcut(key: .char("\\"), ctrl: true, shift: true), .cascade),
            (Shortcut(key: .left, ctrl: true, shift: true, alt: true), .leftHalf),
            (Shortcut(key: .right, ctrl: true, shift: true, alt: true), .rightHalf),
            (Shortcut(key: .up, ctrl: true, shift: true, alt: true), .topHalf),
            (Shortcut(key: .down, ctrl: true, shift: true, alt: true), .bottomHalf),
            (Shortcut(key: .char("H"), ctrl: true, shift: true), .toggleHeaders),
            (Shortcut(key: .char("I"), ctrl: true, shift: true, alt: true), .broadcast),
            (Shortcut(key: .left, alt: true), .focusLeft),
            (Shortcut(key: .right, alt: true), .focusRight),
            (Shortcut(key: .up, alt: true), .focusUp),
            (Shortcut(key: .down, alt: true), .focusDown),
            (Shortcut(key: .char("]"), ctrl: true, shift: true), .nextTerminal),
            (Shortcut(key: .char("["), ctrl: true, shift: true), .previousTerminal),
            (Shortcut(key: .char("="), ctrl: true), .biggerText),
            (Shortcut(key: .char("+"), ctrl: true), .biggerText),
            (Shortcut(key: .char("-"), ctrl: true), .smallerText),
            (Shortcut(key: .char("0"), ctrl: true), .defaultTextSize),
        ]
        for n in 1...9 {
            b.append((Shortcut(key: .char(Character(String(n))), ctrl: true, shift: true), .terminal(n)))
        }
        return b
    }()

    private static let lookup: [Shortcut: Command] = {
        var map: [Shortcut: Command] = [:]
        for (s, c) in bindings where map[s] == nil { map[s] = c }
        return map
    }()

    static func command(for shortcut: Shortcut) -> Command? { lookup[shortcut] }

    /// The first shortcut bound to a command, for the menu's right-hand column.
    static func shortcut(for command: Command) -> Shortcut? {
        bindings.first { $0.1 == command }?.0
    }
}

/// The menu behind the ☰ button, built fresh each time it opens so its state is current.
enum MenuBuilder {
    enum Item {
        case command(Command)
        case separator
        case submenu(String, [Item])
    }

    static func structure(workspaces: [String], environments: [TermsieConfig.EnvironmentStyle], tabCount: Int) -> [Item] {
        let openWorkspace: [Item] = workspaces.isEmpty
            ? [.command(.openWorkspace(""))]
            : workspaces.map { .command(.openWorkspace($0)) }
        let envItems: [Item] = [.command(.environment("")), .separator]
            + environments.map { .command(.environment($0.id)) }
            + [.separator, .command(.environments)]
        return [
            .submenu("File", [
                .command(.newWindow), .command(.newTab), .command(.closeTab), .separator,
                .submenu("Open Workspace", openWorkspace), .command(.openWorkspaceFile), .command(.showWorkspacesFolder),
                .separator,
                .command(.newWorkspace), .command(.saveWorkspace), .command(.saveWorkspaceAs), .command(.workspaceSettings),
                .separator,
                .command(.settings), .command(.environments), .command(.editConfig), .command(.reloadConfig),
                .command(.showConfigFolder), .separator,
                .command(.checkForUpdates), .command(.about), .separator, .command(.exit),
            ]),
            .submenu("Shell", [
                .command(.newTerminal), .command(.newTerminalTiled), .command(.duplicateTerminal), .separator,
                .command(.terminalSettings), .command(.renameTerminal), .command(.clearScrollback),
                .command(.runStartupCommands), .command(.runAllStartupCommands), .separator,
                .command(.closeTerminal), .command(.deleteTerminal),
            ]),
            .submenu("Edit", [
                .command(.copy), .command(.paste), .command(.selectAll), .separator,
                .command(.copyLastCommandOutput), .command(.copyLastCommand), .command(.copyWholeTerminal),
                .command(.autoCopy), .separator,
                .command(.find), .command(.findNext), .command(.findPrevious),
            ]),
            .submenu("View", [
                .command(.toggleSidebar), .separator,
                .command(.maximize), .command(.collapse),
                .submenu("Arrange", [
                    .command(.tileGrid), .command(.cascade), .separator,
                    .command(.leftHalf), .command(.rightHalf), .command(.topHalf), .command(.bottomHalf), .command(.center),
                    .separator, .command(.bringToFront), .command(.sendToBack),
                ]),
                .submenu("Environment", envItems),
                .separator,
                .command(.toggleHeaders), .command(.broadcast), .separator,
                .command(.focusLeft), .command(.focusRight), .command(.focusUp), .command(.focusDown),
                .command(.nextTerminal), .command(.previousTerminal),
                .submenu("Go to Terminal", (1...9).map { .command(.terminal($0)) }),
                .separator,
                .command(.biggerText), .command(.smallerText), .command(.defaultTextSize), .separator,
                .command(.fullScreen),
            ]),
            .submenu("Window", [
                .command(.nextTab), .command(.previousTab), .separator,
                .command(.moveTabToNewWindow), .command(.mergeAllWindows),
            ]),
        ]
    }

    /// Builds the popup and returns it with the id → command table.
    static func build(_ items: [Item], enabled: (Command) -> Bool, checked: (Command) -> Bool) -> (NativeMenu, [Int32: Command]) {
        var table: [Int32: Command] = [:]
        var nextID: Int32 = 100
        func make(_ items: [Item]) -> NativeMenu {
            let menu = NativeMenu()
            for item in items {
                switch item {
                case .separator:
                    menu.appendSeparator()
                case .submenu(let title, let children):
                    menu.append(submenu: make(children), title: title)
                case .command(let command):
                    var text = command.title
                    if case .openWorkspace(let name) = command, name.isEmpty { text = "No saved workspaces" }
                    if let s = Keymap.shortcut(for: command) { text += "\t" + s.label }
                    let isPlaceholder: Bool = { if case .openWorkspace(let n) = command { return n.isEmpty }; return false }()
                    nextID += 1
                    table[nextID] = command
                    menu.append(id: nextID, title: text, enabled: !isPlaceholder && enabled(command), checked: checked(command))
                }
            }
            return menu
        }
        return (make(items), table)
    }
}
