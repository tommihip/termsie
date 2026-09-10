import AppKit

/// Developer aid, in two modes.
///
/// `Termsie --snapshot out.png [--actions newTerminalAction,type:ls,tileGrid] [--quit]`
/// performs menu actions on the key window, saves a PNG of it, and optionally exits.
/// Useful for verifying rendering and layout from scripts.
///
/// `Termsie --record frames/ [--actions ...] [--fps 12] [--record-width 1000] [--step 0.7] [--tail 1.5] [--quit]`
/// does the same but writes a numbered frame on a timer throughout, so a whole
/// action sequence can be assembled into a video or GIF. Both go through
/// ScreenCaptureKit and so need Screen Recording permission.
enum DebugDriver {
    static func startIfRequested() {
        let args = CommandLine.arguments
        let snapshotPath = value(of: "--snapshot", in: args)
        let recordDir = value(of: "--record", in: args)
        guard snapshotPath != nil || recordDir != nil else { return }

        var actions: [String] = []
        if let spec = value(of: "--actions", in: args) {
            actions = spec.split(separator: ",").map(String.init)
        }

        // How long each action is given before the next one fires. Recording wants
        // this longer than the test suite does, so gestures read as deliberate.
        let step = value(of: "--step", in: args).flatMap(Double.init) ?? 0.7
        let tail = value(of: "--tail", in: args).flatMap(Double.init) ?? 1.5
        let lead = 1.5

        var t = lead
        for action in actions {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { perform(action) }
            t += step
        }
        let shouldQuit = args.contains("--quit")

        if let dir = recordDir {
            let fps = value(of: "--fps", in: args).flatMap(Double.init) ?? 12
            let width = value(of: "--record-width", in: args).flatMap(Int.init) ?? 1000
            startRecording(into: dir, fps: fps, width: width, duration: t + tail, quit: shouldQuit)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + t + tail) {
            finish(path: snapshotPath!, quit: shouldQuit)
        }
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Writes `frame-0000.jpg`, `frame-0001.jpg`, … into `dir` until `duration` elapses.
    ///
    /// Frames are captured one at a time and never concurrently: ScreenCaptureKit
    /// screenshots take long enough that a fixed-rate timer would otherwise stack
    /// requests up and drift. The result is close to `fps` rather than exactly it,
    /// which is why the assembler reads the real frame count rather than assuming.
    private static func startRecording(
        into dir: String, fps: Double, width: Int, duration: TimeInterval, quit: Bool
    ) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let interval = 1.0 / max(fps, 1)
        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        var index = 0
        // Elapsed seconds per frame. Capture is slower than the requested rate,
        // so the assembler times playback from these rather than from `fps`.
        var stamps: [TimeInterval] = []

        func captureNext() {
            guard Date() < deadline else {
                let timing = stamps.map { String(format: "%.4f", $0) }.joined(separator: "\n")
                try? timing.write(to: url.appendingPathComponent("timing.txt"),
                                  atomically: true, encoding: .utf8)
                NSLog("DebugDriver: recorded \(index) frames in \(String(format: "%.1f", Date().timeIntervalSince(start)))s to \(dir)")
                if quit {
                    for controller in AppDelegate.shared.controllers {
                        controller.panes.forEach { $0.terminate() }
                    }
                    exit(0)
                }
                return
            }
            guard let window = NSApp.keyWindow ?? AppDelegate.shared.controllers.first?.window else {
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { captureNext() }
                return
            }
            let path = url.appendingPathComponent(String(format: "frame-%04d.jpg", index)).path
            index += 1
            let started = Date()
            stamps.append(started.timeIntervalSince(start))
            Task { @MainActor in
                do {
                    _ = try await WindowCapture.writeJPEG(of: window, to: path, maxWidth: width)
                } catch {
                    NSLog("DebugDriver: frame capture failed — \(error.localizedDescription)")
                }
                let remaining = max(0, interval - Date().timeIntervalSince(started))
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { captureNext() }
            }
        }
        captureNext()
    }

    private static func perform(_ action: String) {
        let controller = NSApp.keyWindow?.windowController as? TerminalWindowController
            ?? AppDelegate.shared.controllers.first
        if action.hasPrefix("type:") {
            let text = String(action.dropFirst(5)).replacingOccurrences(of: "\\n", with: "\r")
            controller?.activePane?.terminalView.send(txt: text)
        } else if action.hasPrefix("copy:"), let controller {
            let name = String(action.dropFirst(5))
            guard let target = TerminalPane.CopyTarget(rawValue: name) else {
                NSLog("DebugDriver copy: unknown target [\(name)]")
                return
            }
            NSLog("DebugDriver copy: \(name) copied=\(controller.performCopy(target))")
        } else if action == "dumpClipboard" {
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            // Through a format argument, not interpolated: copied text is full of % signs.
            NSLog("DebugDriver clipboard: [%@]", text.replacingOccurrences(of: "\n", with: "\\n"))
        } else if action == "autoCopyNow", let controller {
            let did = controller.activePane?.terminalView.autoCopySelection() ?? false
            NSLog("DebugDriver autoCopy: copied=\(did)")
        } else if action == "dumpCopyState", let controller {
            let pane = controller.activePane
            NSLog("DebugDriver copyState: \(pane?.terminalView.copyStateDescription ?? "-")")
        } else if action.hasPrefix("select:"), let controller {
            // select:<row>x<col>x<row>x<col>, rows relative to the visible screen.
            let parts = action.dropFirst(7).split(separator: "x").compactMap { Int($0) }
            if parts.count == 4 {
                controller.activePane?.terminalView.selectForTesting(
                    fromRow: parts[0], fromCol: parts[1], toRow: parts[2], toCol: parts[3])
            }
        } else if action == "dumpSelection", let controller {
            let view = controller.activePane?.terminalView
            let text = view?.getSelection() ?? ""
            NSLog("DebugDriver selection: active=%@ text=[%@]", "\(view?.selectionActive ?? false)",
                  text.replacingOccurrences(of: "\n", with: "\\n"))
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
        } else if action.hasPrefix("cursorAt:"), let controller {
            let parts = action.dropFirst(9).split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                let result = controller.cursorDescription(at: NSPoint(x: parts[0], y: parts[1]))
                NSLog("DebugDriver cursor: at=\(Int(parts[0])),\(Int(parts[1])) shape=\(result.cursor) terminal=\(result.pane)")
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
        } else if action == "dumpTextLayout", let controller {
            let config = ConfigStore.shared.config
            NSLog("DebugDriver textLayoutGlobal: padding=\(config.terminalPadding) wrap=\(config.lineWrap) cols=\(config.resolvedUnwrappedColumns)")
            for id in controller.registry.order {
                let def = controller.registry.definition(id)
                guard let pane = controller.registry.pane(for: id) else { continue }
                let host = pane.scrollHost
                NSLog("DebugDriver textLayout: id=\(id) override=[\(def?.padding.map { String(format: "%g", $0) } ?? "-") \(def?.lineWrap.map(String.init) ?? "-")]"
                    + " padding=\(host.padding) wrap=\(host.wrapsLines) gridCols=\(pane.terminalView.getTerminal().cols)"
                    + " termWidth=\(Int(pane.terminalView.frame.width)) hostWidth=\(Int(host.frame.width))"
                    + " content=\(host.contentColumns) hscroll=\(host.showsHorizontalScroller) offset=\(Int(host.horizontalOffset))")
            }
        } else if action.hasPrefix("setGlobalTextLayout:") {
            // setGlobalTextLayout:<padding>|<wrap 0|1>|<columns>; an empty field is left alone.
            let parts = action.dropFirst(20).split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 3 {
                ConfigStore.shared.update {
                    if let padding = Double(parts[0]) { $0.terminalPadding = padding }
                    if let wrap = Int(parts[1]) { $0.lineWrap = wrap != 0 }
                    if let cols = Int(parts[2]) { $0.unwrappedColumns = cols }
                }
            }
        } else if action.hasPrefix("setTextLayout:"), let controller {
            // setTextLayout:<n>|<padding>|<wrap 0|1>; an empty field clears that override.
            let parts = action.dropFirst(14).split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 3, let n = Int(parts[0]), let id = controller.registry.id(at: n - 1) {
                controller.registry.mutate(id) {
                    $0.padding = Double(parts[1])
                    $0.lineWrap = Int(parts[2]).map { $0 != 0 }
                }
            }
        } else if action.hasPrefix("scrollTerminal:"), let controller {
            if let delta = Double(action.dropFirst(15)), let pane = controller.activePane {
                let moved = pane.scrollHost.scrollBy(CGFloat(delta))
                NSLog("DebugDriver scrollTerminal: moved=\(moved) offset=\(Int(pane.scrollHost.horizontalOffset))")
            }
        } else if action.hasPrefix("setNumberSetting:") {
            // setNumberSetting:<label>|<value>, driving the real settings control.
            let parts = action.dropFirst(17).split(separator: "|", maxSplits: 1)
            if parts.count == 2, let value = Double(parts[1]) {
                let found = SettingsWindowController.shared.setGeneralNumber(String(parts[0]), to: value)
                NSLog("DebugDriver setNumberSetting: [\(parts[0])] found=\(found)")
            }
        } else if action.hasPrefix("readNumberSetting:") {
            let title = String(action.dropFirst(18))
            let state = SettingsWindowController.shared.generalNumberState(title)
            NSLog("DebugDriver readNumberSetting: [\(title)] shown=\(state.map { String(format: "%g", $0) } ?? "-")")
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

    /// Captures the window and, when asked, quits once the file is on disk.
    private static func finish(path: String, quit: Bool) {
        guard let window = NSApp.keyWindow ?? AppDelegate.shared.controllers.first?.window else {
            NSLog("DebugDriver: no window to snapshot")
            if quit { exit(1) }
            return
        }
        logState(window)

        // The capture is asynchronous, so the process must not be torn down until it lands.
        // A watchdog covers the case where the permission prompt stalls it indefinitely.
        var finished = false
        let done: (Int32) -> Void = { code in
            guard !finished else { return }
            finished = true
            if quit {
                for controller in AppDelegate.shared.controllers {
                    controller.panes.forEach { $0.terminate() }
                }
                exit(code)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard !finished else { return }
            NSLog("DebugDriver: capture timed out")
            done(1)
        }
        Task { @MainActor in
            do {
                let size = try await WindowCapture.writePNG(of: window, to: path)
                NSLog("DebugDriver: wrote \(path) (\(size.width)x\(size.height))")
                done(0)
            } catch {
                NSLog("DebugDriver: capture failed — \(error.localizedDescription)")
                done(1)
            }
        }
    }

    private static func logState(_ window: NSWindow) {
        if let controller = window.windowController as? TerminalWindowController {
            let pane = controller.activePane
            NSLog("DebugDriver: metal=\(pane?.terminalView.isUsingMetalRenderer ?? false) panes=\(controller.panes.count) defs=\(controller.registry.count) open=\(controller.registry.openCount) sidebar=\(controller.sidebarVisible ? String(Int(controller.sidebarWidth)) : "hidden") opaque=\(window.isOpaque) blur=\(controller.backdropCount) termAlpha=\(String(format: "%.2f", pane?.terminalView.backgroundOpacity ?? 1)) title=\(window.title)")
        }
    }

}
