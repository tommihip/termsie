import AppKit

enum MainMenu {
    private static let workspacesDelegate = WorkspacesMenuDelegate()

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.tag = tag
        return it
    }

    private static func key(_ code: Int) -> String {
        String(Character(UnicodeScalar(code)!))
    }

    static func install() {
        let main = NSMenu()

        // Application
        let appMenu = NSMenu(title: AppInfo.name)
        appMenu.addItem(item("About \(AppInfo.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings (config.json)…", #selector(AppDelegate.openConfig(_:)), ","))
        appMenu.addItem(item("Reload Settings", #selector(AppDelegate.reloadConfig(_:)), ",", [.command, .shift]))
        appMenu.addItem(item("Show Config Folder", #selector(AppDelegate.openConfigFolder(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(AppInfo.name)", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(AppInfo.name)", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(submenu(appMenu))

        // Shell
        let shell = NSMenu(title: "Shell")
        shell.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        shell.addItem(item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"))
        shell.addItem(.separator())
        shell.addItem(item("New Terminal", #selector(TerminalWindowController.newTerminalAction(_:)), "d"))
        shell.addItem(item("New Terminal, Tile All", #selector(TerminalWindowController.newTerminalTiled(_:)), "d", [.command, .control]))
        shell.addItem(item("Duplicate Terminal", #selector(TerminalWindowController.duplicateTerminal(_:)), "d", [.command, .shift]))
        shell.addItem(.separator())
        shell.addItem(item("Terminal Settings…", #selector(TerminalWindowController.showTerminalSettings(_:)), "i"))
        shell.addItem(item("Set Terminal Name…", #selector(TerminalWindowController.renameActivePane(_:)), "r", [.command, .option]))
        shell.addItem(item("Clear Scrollback", #selector(TerminalWindowController.clearScrollback(_:)), "k"))
        shell.addItem(.separator())
        shell.addItem(item("Close Terminal", #selector(TerminalWindowController.closeActivePane(_:)), "w"))
        shell.addItem(item("Delete Terminal", #selector(TerminalWindowController.deleteTerminal(_:)), String(Character(UnicodeScalar(8))), [.command]))
        shell.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        main.addItem(submenu(shell))

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Find…", #selector(TerminalWindowController.showFind(_:)), "f"))
        edit.addItem(item("Find Next", #selector(TerminalWindowController.findNext(_:)), "g"))
        edit.addItem(item("Find Previous", #selector(TerminalWindowController.findPrevious(_:)), "g", [.command, .shift]))
        main.addItem(submenu(edit))

        // View
        let view = NSMenu(title: "View")
        view.addItem(item("Toggle Terminal List", #selector(TerminalWindowController.toggleSidebar(_:)), "s", [.command, .control]))
        view.addItem(.separator())
        view.addItem(item("Maximize Terminal", #selector(TerminalWindowController.toggleZoom(_:)), "\r", [.command, .shift]))
        let arrange = NSMenu(title: "Arrange")
        arrange.addItem(item("Tile Grid", #selector(TerminalWindowController.tileGrid(_:)), "=", [.command, .option]))
        arrange.addItem(item("Cascade", #selector(TerminalWindowController.cascade(_:)), "\\", [.command, .option]))
        arrange.addItem(.separator())
        arrange.addItem(item("Left Half", #selector(TerminalWindowController.tilePaneLeft(_:)), key(NSLeftArrowFunctionKey), [.command, .control, .option]))
        arrange.addItem(item("Right Half", #selector(TerminalWindowController.tilePaneRight(_:)), key(NSRightArrowFunctionKey), [.command, .control, .option]))
        arrange.addItem(item("Top Half", #selector(TerminalWindowController.tilePaneTop(_:)), key(NSUpArrowFunctionKey), [.command, .control, .option]))
        arrange.addItem(item("Bottom Half", #selector(TerminalWindowController.tilePaneBottom(_:)), key(NSDownArrowFunctionKey), [.command, .control, .option]))
        arrange.addItem(item("Center", #selector(TerminalWindowController.centerPane(_:))))
        arrange.addItem(.separator())
        arrange.addItem(item("Bring to Front", #selector(TerminalWindowController.bringPaneToFront(_:)), "f", [.command, .option]))
        arrange.addItem(item("Send to Back", #selector(TerminalWindowController.sendPaneToBack(_:)), "b", [.command, .option]))
        let arrangeItem = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
        arrangeItem.submenu = arrange
        view.addItem(arrangeItem)
        view.addItem(.separator())
        view.addItem(item("Toggle Terminal Headers", #selector(TerminalWindowController.togglePaneHeaders(_:)), "h", [.command, .shift]))
        view.addItem(item("Broadcast Input to All Terminals", #selector(TerminalWindowController.toggleBroadcast(_:)), "i", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Focus Terminal Left", #selector(TerminalWindowController.focusLeft(_:)), key(NSLeftArrowFunctionKey), [.command, .option]))
        view.addItem(item("Focus Terminal Right", #selector(TerminalWindowController.focusRight(_:)), key(NSRightArrowFunctionKey), [.command, .option]))
        view.addItem(item("Focus Terminal Above", #selector(TerminalWindowController.focusUp(_:)), key(NSUpArrowFunctionKey), [.command, .option]))
        view.addItem(item("Focus Terminal Below", #selector(TerminalWindowController.focusDown(_:)), key(NSDownArrowFunctionKey), [.command, .option]))
        view.addItem(item("Next Terminal", #selector(TerminalWindowController.focusNextPane(_:)), "]"))
        view.addItem(item("Previous Terminal", #selector(TerminalWindowController.focusPreviousPane(_:)), "["))
        view.addItem(.separator())
        for n in 1...9 {
            view.addItem(item("Terminal \(n)", #selector(TerminalWindowController.focusPaneByNumber(_:)), "\(n)", [.command, .option], tag: n))
        }
        view.addItem(.separator())
        view.addItem(item("Bigger Text", #selector(TerminalWindowController.increaseFontSize(_:)), "="))
        view.addItem(item("Smaller Text", #selector(TerminalWindowController.decreaseFontSize(_:)), "-"))
        view.addItem(item("Default Text Size", #selector(TerminalWindowController.resetFontSize(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        main.addItem(submenu(view))

        // Workspaces
        let workspaces = NSMenu(title: "Workspaces")
        workspaces.addItem(item("Save Workspace…", #selector(TerminalWindowController.saveWorkspace(_:)), "s", [.command, .shift]))
        workspaces.addItem(item("Open Workspace File…", #selector(AppDelegate.openWorkspaceFile(_:)), "o", [.command, .shift]))
        workspaces.addItem(item("Show Workspaces Folder", #selector(AppDelegate.openWorkspacesFolder(_:))))
        workspaces.addItem(.separator())
        let openMenu = NSMenu(title: "Open Workspace")
        openMenu.delegate = workspacesDelegate
        let openItem = NSMenuItem(title: "Open Workspace", action: nil, keyEquivalent: "")
        openItem.submenu = openMenu
        workspaces.addItem(openItem)
        main.addItem(submenu(workspaces))

        // Window
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]))
        windowMenu.addItem(item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]))
        windowMenu.addItem(item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))))
        windowMenu.addItem(item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))))
        windowMenu.addItem(.separator())
        for n in 1...9 {
            windowMenu.addItem(item("Tab \(n)", #selector(TerminalWindowController.selectTabByNumber(_:)), "\(n)", [.command], tag: n))
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        main.addItem(submenu(windowMenu))

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }
}

/// Fills the "Open Workspace" submenu from the workspaces folder each time it opens.
final class WorkspacesMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let names = WorkspaceStore.list()
        if names.isEmpty {
            let it = NSMenuItem(title: "No saved workspaces", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            return
        }
        for name in names {
            let it = NSMenuItem(title: name, action: #selector(AppDelegate.openWorkspaceMenuItem(_:)), keyEquivalent: "")
            it.representedObject = name
            menu.addItem(it)
        }
    }
}
