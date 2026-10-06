import AppKit
import SwiftTerm
import TermsieCore

// The config model and store live in TermsieCore. This file adds what only the Mac app needs:
// AppKit fonts and colours, SwiftTerm's Mac bell style, and a file watcher built on kqueue.

extension TermsieConfig {
    var nsFont: NSFont { resolvedFont(family: nil, size: nil) }

    /// The font for a terminal, given its optional overrides. A nil field inherits the global one,
    /// which is what makes changing the global font move every terminal that has not opted out.
    func resolvedFont(family: String?, size: Double?) -> NSFont {
        let spec = resolvedFontSpec(family: family, size: size)
        return NSFont(name: spec.family, size: spec.size)
            ?? NSFont(name: font.family, size: spec.size)
            ?? UIFonts.monospaced(size: spec.size, weight: .regular)
    }

    var terminalBellStyle: BellStyle {
        switch bell.lowercased() {
        case "none": return .none
        case "sound": return .sound
        case "both", "soundandvisual": return .soundAndVisual
        default: return .visual
        }
    }

    /// The terminal background for an environment: the configured background pulled toward the
    /// environment's tint, then given the window's opacity.
    func background(for environmentID: String?) -> NSColor {
        NSColor(backgroundRGBA(for: environmentID))
    }
}

// MARK: - Color helpers

extension NSColor {
    convenience init?(hex: String) {
        guard let c = RGBA(hex: hex) else { return nil }
        self.init(c)
    }

    convenience init(_ c: RGBA) {
        self.init(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    static func hex(_ hex: String, fallback: NSColor = .magenta) -> NSColor {
        NSColor(hex: hex) ?? fallback
    }
}

// MARK: - Watching

extension ConfigStore {
    /// Watches both the file (in-place edits) and its directory (atomic saves replace the file).
    func startWatching() {
        ConfigFileWatcher.shared.start(store: self)
    }
}

/// Reloads the config when config.json changes on disk, by kqueue on the file and its folder.
final class ConfigFileWatcher {
    static let shared = ConfigFileWatcher()

    private weak var store: ConfigStore?
    private var watcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    func start(store: ConfigStore) {
        self.store = store
        watchDirectory()
        watchFile()
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.store?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func watchDirectory() {
        guard let store else { return }
        let fd = open(store.configDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleReload()
            if self.fileWatcher == nil { self.watchFile() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        guard let store else { return }
        let fd = open(store.configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let events = src.data
            self.scheduleReload()
            if events.contains(.delete) || events.contains(.rename) {
                // The file was replaced; watch the new inode once the writer is done.
                self.fileWatcher?.cancel()
                self.fileWatcher = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watchFile() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatcher = src
    }
}
