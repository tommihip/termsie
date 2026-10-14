import Foundation
import CTermsieHost
import TermsieCore

/// Reloads config.json when it changes on disk, through GIO's file monitor; reloads are
/// debounced, since editors write a file in several steps.
final class ConfigWatcher {
    private let directory: URL
    private var watch: OpaquePointer?
    private let debounce = Debouncer()

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        guard watch == nil else { return }
        watch = withWide(directory.path) {
            tw_watch_directory($0, { ctx in
                let me = Unmanaged<ConfigWatcher>.fromOpaque(ctx!).takeUnretainedValue()
                me.debounce.schedule(after: 0.25) { ConfigStore.shared.reload() }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        if watch == nil { Log.write("config watcher unavailable for \(directory.path)") }
    }

    func stop() {
        tw_watch_stop(watch)
        watch = nil
    }
}
