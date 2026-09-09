import AppKit

/// Developer aid: `Termsie --snapshot out.png [--actions newTerminalAction,type:ls,tileGrid] [--quit]`
/// performs menu actions on the key window, saves a PNG of it, and optionally exits.
/// Useful for verifying rendering and layout from scripts.
enum DebugDriver {
    static func startIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        var actions: [String] = []
        if let j = args.firstIndex(of: "--actions"), j + 1 < args.count {
            actions = args[j + 1].split(separator: ",").map(String.init)
        }
        var t = 1.5
        for action in actions {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { perform(action) }
            t += 0.7
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 1.5) {
            snapshot(to: path)
            if args.contains("--quit") {
                for c in AppDelegate.shared.controllers { c.panes.forEach { $0.terminate() } }
                exit(0)
            }
        }
    }

    private static func perform(_ action: String) {
        let controller = NSApp.keyWindow?.windowController as? TerminalWindowController
            ?? AppDelegate.shared.controllers.first
        if action.hasPrefix("type:") {
            let text = String(action.dropFirst(5)).replacingOccurrences(of: "\\n", with: "\r")
            controller?.activePane?.terminalView.send(txt: text)
        } else if action == "wait" {
            return
        } else if action == "terminate" {
            NSApp.terminate(nil)
        } else if action == "dumpLayout" || action == "dumpTerminals", let controller {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            if let data = try? enc.encode(controller.snapshot(includeLiveState: true)) {
                NSLog("DebugDriver terminals: \(String(decoding: data, as: UTF8.self))")
            }
            let open = controller.registry.order.map { "\($0)=\(controller.registry.isOpen($0) ? "open" : "closed")" }
            NSLog("DebugDriver state: \(open.joined(separator: " "))")
        } else if action.hasPrefix("move:"), let controller, let pane = controller.activePane {
            let parts = action.dropFirst(5).split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                controller.simulateDrag(pane, zone: .move, delta: NSPoint(x: parts[0], y: parts[1]))
            }
        } else if action.hasPrefix("resize:"), let controller, let pane = controller.activePane {
            let parts = action.dropFirst(7).split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                controller.simulateDrag(pane, zone: .bottomRight, delta: NSPoint(x: parts[0], y: parts[1]))
            }
        } else if action == "dumpWorkspace", let controller {
            NSLog("DebugDriver workspace: name=[\(controller.workspaceName ?? "-")] modified=\(controller.isWorkspaceModified)")
        } else if action.hasPrefix("saveWorkspaceNamed:"), let controller {
            controller.saveWorkspaceForTesting(named: String(action.dropFirst(19)))
        } else if action == "newWorkspaceDiscarding", let controller {
            controller.newWorkspaceForTesting()
        } else if action.hasPrefix("resizeWindow:"), let controller {
            let parts = action.dropFirst(13).split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let window = controller.window {
                var f = window.frame
                f.size = NSSize(width: parts[0], height: parts[1])
                window.setFrame(f, display: true)
            }
        } else if action == "dumpBadges", let controller {
            for pane in controller.panes {
                NSLog("DebugDriver badge: #\(pane.index) active=\(pane.isActive) badge=\(pane.header.badge)")
            }
        } else if action == "dumpFonts", let controller {
            let global = ConfigStore.shared.config.font
            NSLog("DebugDriver globalFont: \(global.family) \(global.size)")
            for id in controller.registry.order {
                let def = controller.registry.definition(id)
                let pane = controller.registry.pane(for: id)
                let font = pane?.terminalView.font
                NSLog("DebugDriver font: id=\(id) override=[\(def?.fontFamily ?? "-") \(def?.fontSize.map { String(format: "%g", $0) } ?? "-")] actual=[\(font?.familyName ?? "-") \(font.map { String(format: "%g", $0.pointSize) } ?? "-")]")
            }
        } else if action.hasPrefix("setFont:"), let controller {
            // setFont:<n>|<family>|<size>; an empty family or size clears that override.
            let parts = action.dropFirst(8).split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 3, let n = Int(parts[0]), let id = controller.registry.id(at: n - 1) {
                controller.registry.mutate(id) {
                    $0.fontFamily = parts[1].isEmpty ? nil : String(parts[1])
                    $0.fontSize = Double(parts[2])
                }
            }
        } else if action.hasPrefix("setGlobalFont:") {
            let parts = action.dropFirst(14).split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 2 {
                ConfigStore.shared.update {
                    if !parts[0].isEmpty { $0.font.family = String(parts[0]) }
                    if let size = Double(parts[1]) { $0.font.size = size }
                }
            }
        } else if action == "dumpEnvironments" {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            if let data = try? enc.encode(ConfigStore.shared.config.environments) {
                NSLog("DebugDriver environments: \(String(decoding: data, as: UTF8.self))")
            }
        } else if action.hasPrefix("addEnvironment:") {
            // addEnvironment:<label>|<tint>|<strength>
            let parts = action.dropFirst(15).split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 3 {
                ConfigStore.shared.update {
                    let id = String(parts[0]).lowercased().replacingOccurrences(of: " ", with: "-")
                    $0.environments.append(TermsieConfig.EnvironmentStyle(
                        id: id, label: String(parts[0]),
                        tint: parts[1].isEmpty ? nil : String(parts[1]),
                        strength: Double(parts[2]) ?? 0.22))
                }
            }
        } else if action.hasPrefix("removeEnvironment:") {
            let target = String(action.dropFirst(18))
            ConfigStore.shared.update { $0.environments.removeAll { $0.id == target } }
        } else if action.hasPrefix("clickSetting:") {
            let title = String(action.dropFirst(13))
            let clicked = SettingsWindowController.shared.clickGeneralSetting(title)
            NSLog("DebugDriver clickSetting: [\(title)] found=\(clicked)")
        } else if action.hasPrefix("readSetting:") {
            let title = String(action.dropFirst(12))
            let state = SettingsWindowController.shared.generalSettingState(title)
            NSLog("DebugDriver readSetting: [\(title)] shown=\(state.map(String.init) ?? "-")")
        } else if action == "openSettings" {
            SettingsWindowController.shared.show()
        } else if action == "dumpNames", let controller {
            for id in controller.registry.order {
                let n = controller.displayedNames(for: id)
                NSLog("DebugDriver name: id=\(id) header=[\(n.header ?? "-")] row=[\(n.row)]")
            }
        } else if action == "readout", let controller {
            NSLog("DebugDriver readout: \(controller.activePane?.showsResizeReadout == true ? "visible" : "cleared")")
        } else if action.hasPrefix("rename:"), let controller {
            let parts = action.dropFirst(7).split(separator: "|", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0]), let id = controller.registry.id(at: n - 1) {
                controller.registry.mutate(id) { $0.name = String(parts[1]) }
            }
        } else if action.hasPrefix("setEnv:"), let controller {
            let parts = action.dropFirst(7).split(separator: "|", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0]), let id = controller.registry.id(at: n - 1) {
                controller.setEnvironment(String(parts[1]), for: id)
            }
        } else if action == "frames", let controller {
            for pane in controller.panes {
                NSLog("DebugDriver frame: #\(pane.index) id=\(pane.definitionID) z=\(pane.zIndex) frame=\(NSStringFromRect(pane.frame)) fraction=\(NSStringFromRect(pane.layoutFraction))")
            }
        } else if action.hasPrefix("dumpThumb:"), let controller,
                  let n = Int(action.dropFirst(10)), let id = controller.registry.id(at: n - 1) {
            NSLog("DebugDriver thumb: id=\(id) renders=\(controller.thumbnailRenderCount(for: id)) open=\(controller.registry.isOpen(id))")
        } else if action.hasPrefix("openTerminal:"), let controller,
                  let n = Int(action.dropFirst(13)), let id = controller.registry.id(at: n - 1) {
            controller.openTerminal(id, isReopen: true)
        } else if action.hasPrefix("closeTerminal:"), let controller,
                  let n = Int(action.dropFirst(14)), let id = controller.registry.id(at: n - 1),
                  let pane = controller.registry.pane(for: id) {
            controller.closePane(pane, force: true)
        } else if action.hasPrefix("deleteTerminal:"), let controller,
                  let n = Int(action.dropFirst(15)), let id = controller.registry.id(at: n - 1) {
            controller.sidebarDidRequestDelete(id)
        } else if action.hasPrefix("pane:"), let n = Int(action.dropFirst(5)) {
            let item = NSMenuItem(); item.tag = n
            controller?.focusPaneByNumber(item)
        } else {
            let sel = Selector(action + ":")
            let target: AnyObject? = controller?.responds(to: sel) == true ? controller : nil
            NSApp.sendAction(sel, to: target, from: nil)
        }
    }

    private static func snapshot(to path: String) {
        guard let window = NSApp.keyWindow ?? AppDelegate.shared.controllers.first?.window else {
            NSLog("DebugDriver: no window to snapshot")
            return
        }
        if let controller = window.windowController as? TerminalWindowController {
            let pane = controller.activePane
            NSLog("DebugDriver: metal=\(pane?.terminalView.isUsingMetalRenderer ?? false) panes=\(controller.panes.count) defs=\(controller.registry.count) open=\(controller.registry.openCount) sidebar=\(controller.sidebarVisible ? String(Int(controller.sidebarWidth)) : "hidden") opaque=\(window.isOpaque) blur=\(controller.backdropCount) termAlpha=\(String(format: "%.2f", pane?.terminalView.backgroundOpacity ?? 1)) title=\(window.title)")
        }
        let id = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            NSLog("DebugDriver: CGWindowListCreateImage failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            NSLog("DebugDriver: wrote \(path) (\(image.width)x\(image.height))")
        } catch {
            NSLog("DebugDriver: \(error)")
        }
    }
}
