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
        } else if action == "dumpNames", let controller {
            for id in controller.registry.order {
                let n = controller.displayedNames(for: id)
                NSLog("DebugDriver name: id=\(id) header=[\(n.header ?? "-")] row=[\(n.row)]")
            }
        } else if action == "readout", let controller {
            NSLog("DebugDriver readout: \(controller.activePane?.showsResizeReadout == true ? "visible" : "cleared")")
        } else if action.hasPrefix("rename:"), let controller {
            let parts = action.dropFirst(7).split(separator: "x", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0]), let id = controller.registry.id(at: n - 1) {
                controller.registry.mutate(id) { $0.name = String(parts[1]) }
            }
        } else if action.hasPrefix("setEnv:"), let controller {
            let parts = action.dropFirst(7).split(separator: "x", maxSplits: 1)
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
