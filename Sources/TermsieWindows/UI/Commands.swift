import Foundation
import WinSDK
import CTermsieWin
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
    var vk: Int32
    var ctrl = false
    var shift = false
    var alt = false

    var label: String {
        var parts: [String] = []
        if ctrl { parts.append("Ctrl") }
        if alt { parts.append("Alt") }
        if shift { parts.append("Shift") }
        parts.append(Shortcut.keyName(vk))
        return parts.joined(separator: "+")
    }

    static func keyName(_ vk: Int32) -> String {
        switch vk {
        case Win.VK_RETURN: return "Enter"
        case Win.VK_TAB: return "Tab"
        case Win.VK_LEFT: return "Left"
        case Win.VK_RIGHT: return "Right"
        case Win.VK_UP: return "Up"
        case Win.VK_DOWN: return "Down"
        case Win.VK_DELETE: return "Del"
        case Win.VK_PRIOR: return "PgUp"
        case Win.VK_NEXT: return "PgDn"
        case Win.VK_OEM_PLUS: return "="
        case Win.VK_OEM_MINUS: return "-"
        case Win.VK_OEM_COMMA: return ","
        case Win.VK_OEM_4: return "["
        case Win.VK_OEM_6: return "]"
        case Win.VK_OEM_5: return "\\"
        case Win.VK_F1...Win.VK_F24: return "F\(vk - Win.VK_F1 + 1)"
        case 0x30...0x39, 0x41...0x5A: return String(UnicodeScalar(UInt8(vk)))
        default: return String(format: "0x%02X", vk)
        }
    }
}

enum Keymap {
    static func key(_ c: Character) -> Int32 { Int32(c.asciiValue ?? 0) }

    /// macOS's ⌘ becomes Ctrl+Shift, as in Windows Terminal, so that every plain Ctrl+letter
    /// still reaches the shell (Ctrl+C, Ctrl+D, Ctrl+R…). Three-modifier chords stand in for
    /// ⌥⌘ and ⌃⌘ where two would collide.
    static let bindings: [(Shortcut, Command)] = {
        var b: [(Shortcut, Command)] = [
            (Shortcut(vk: key("N"), ctrl: true, shift: true), .newWindow),
            (Shortcut(vk: key("T"), ctrl: true, shift: true), .newTab),
            (Shortcut(vk: Win.VK_TAB, ctrl: true), .nextTab),
            (Shortcut(vk: Win.VK_TAB, ctrl: true, shift: true), .previousTab),
            (Shortcut(vk: Win.VK_NEXT, ctrl: true), .nextTab),
            (Shortcut(vk: Win.VK_PRIOR, ctrl: true), .previousTab),
            (Shortcut(vk: Win.VK_OEM_COMMA, ctrl: true), .settings),
            (Shortcut(vk: Win.VK_OEM_COMMA, ctrl: true, shift: true), .workspaceSettings),
            (Shortcut(vk: Win.VK_F1 + 4, ctrl: true, shift: true), .reloadConfig),
            (Shortcut(vk: Win.VK_F1 + 10), .fullScreen),
            (Shortcut(vk: key("B"), ctrl: true, shift: true), .toggleSidebar),
            (Shortcut(vk: key("S"), ctrl: true, shift: true), .saveWorkspace),
            (Shortcut(vk: key("S"), ctrl: true, shift: true, alt: true), .saveWorkspaceAs),
            (Shortcut(vk: key("O"), ctrl: true, shift: true), .openWorkspaceFile),
            (Shortcut(vk: key("D"), ctrl: true, shift: true), .newTerminal),
            (Shortcut(vk: key("D"), ctrl: true, shift: true, alt: true), .newTerminalTiled),
            (Shortcut(vk: key("I"), ctrl: true, shift: true), .terminalSettings),
            (Shortcut(vk: key("R"), ctrl: true, shift: true), .renameTerminal),
            (Shortcut(vk: key("K"), ctrl: true, shift: true), .clearScrollback),
            (Shortcut(vk: key("W"), ctrl: true, shift: true), .closeTerminal),
            (Shortcut(vk: Win.VK_DELETE, ctrl: true, shift: true), .deleteTerminal),
            (Shortcut(vk: key("C"), ctrl: true, shift: true), .copy),
            (Shortcut(vk: Win.VK_INSERT, ctrl: true), .copy),
            (Shortcut(vk: key("V"), ctrl: true, shift: true), .paste),
            (Shortcut(vk: Win.VK_INSERT, shift: true), .paste),
            (Shortcut(vk: key("A"), ctrl: true, shift: true), .selectAll),
            (Shortcut(vk: key("C"), ctrl: true, shift: true, alt: true), .copyLastCommandOutput),
            (Shortcut(vk: key("L"), ctrl: true, shift: true, alt: true), .copyLastCommand),
            (Shortcut(vk: key("A"), ctrl: true, shift: true, alt: true), .copyWholeTerminal),
            (Shortcut(vk: key("F"), ctrl: true, shift: true), .find),
            (Shortcut(vk: Win.VK_F1 + 2), .findNext),
            (Shortcut(vk: Win.VK_F1 + 2, shift: true), .findPrevious),
            (Shortcut(vk: Win.VK_RETURN, ctrl: true, shift: true), .maximize),
            (Shortcut(vk: key("G"), ctrl: true, shift: true), .tileGrid),
            (Shortcut(vk: Win.VK_OEM_5, ctrl: true, shift: true), .cascade),
            (Shortcut(vk: Win.VK_LEFT, ctrl: true, shift: true, alt: true), .leftHalf),
            (Shortcut(vk: Win.VK_RIGHT, ctrl: true, shift: true, alt: true), .rightHalf),
            (Shortcut(vk: Win.VK_UP, ctrl: true, shift: true, alt: true), .topHalf),
            (Shortcut(vk: Win.VK_DOWN, ctrl: true, shift: true, alt: true), .bottomHalf),
            (Shortcut(vk: key("H"), ctrl: true, shift: true), .toggleHeaders),
            (Shortcut(vk: key("I"), ctrl: true, shift: true, alt: true), .broadcast),
            (Shortcut(vk: Win.VK_LEFT, alt: true), .focusLeft),
            (Shortcut(vk: Win.VK_RIGHT, alt: true), .focusRight),
            (Shortcut(vk: Win.VK_UP, alt: true), .focusUp),
            (Shortcut(vk: Win.VK_DOWN, alt: true), .focusDown),
            (Shortcut(vk: Win.VK_OEM_6, ctrl: true, shift: true), .nextTerminal),
            (Shortcut(vk: Win.VK_OEM_4, ctrl: true, shift: true), .previousTerminal),
            (Shortcut(vk: Win.VK_OEM_PLUS, ctrl: true), .biggerText),
            (Shortcut(vk: Win.VK_ADD, ctrl: true), .biggerText),
            (Shortcut(vk: Win.VK_OEM_MINUS, ctrl: true), .smallerText),
            (Shortcut(vk: Win.VK_SUBTRACT, ctrl: true), .smallerText),
            (Shortcut(vk: key("0"), ctrl: true), .defaultTextSize),
        ]
        for n in 1...9 {
            b.append((Shortcut(vk: key(Character(String(n))), ctrl: true, shift: true), .terminal(n)))
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
    static func build(_ items: [Item], enabled: (Command) -> Bool, checked: (Command) -> Bool) -> (HMENU?, [UINT: Command]) {
        var table: [UINT: Command] = [:]
        var nextID: UINT = 100
        func make(_ items: [Item]) -> HMENU? {
            let menu = CreatePopupMenu()
            for item in items {
                switch item {
                case .separator:
                    AppendMenuW(menu, Win.MF_SEPARATOR, 0, nil)
                case .submenu(let title, let children):
                    let sub = make(children)
                    _ = withWide(title) { AppendMenuW(menu, Win.MF_POPUP | Win.MF_STRING, UINT_PTR(UInt(bitPattern: sub)), $0) }
                case .command(let command):
                    var text = command.title
                    if case .openWorkspace(let name) = command, name.isEmpty { text = "No saved workspaces" }
                    if let s = Keymap.shortcut(for: command) { text += "\t" + s.label }
                    var flags = Win.MF_STRING
                    let isPlaceholder: Bool = { if case .openWorkspace(let n) = command { return n.isEmpty }; return false }()
                    if isPlaceholder || !enabled(command) { flags |= Win.MF_GRAYED }
                    if checked(command) { flags |= Win.MF_CHECKED }
                    nextID += 1
                    table[nextID] = command
                    // Ampersands in names would become mnemonics.
                    _ = withWide(text.replacingOccurrences(of: "&", with: "&&")) { AppendMenuW(menu, flags, UINT_PTR(nextID), $0) }
                }
            }
            return menu
        }
        return (make(items), table)
    }
}
