import Foundation
import WinSDK
import CTermsieHost
import TermsieCore

/// Reloads config.json when it changes on disk. A thread waits on the folder's change
/// notification; reloads are debounced, since editors write a file in several steps.
final class ConfigWatcher {
    private let directory: URL
    private var running = false
    private var handle: HANDLE?
    private let debounce = Debouncer()

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        guard !running else { return }
        let path = ShellIntegration.nativePath(directory)
        let h: HANDLE? = withWide(path) {
            FindFirstChangeNotificationW($0, false, DWORD(0x0000_0001 | 0x0000_0010) /* FILE_NAME | LAST_WRITE */)
        }
        guard let h, h != HANDLE(bitPattern: -1) else {
            Log.write("config watcher unavailable for \(path)")
            return
        }
        handle = h
        running = true
        let thread = Thread { [weak self] in
            while let self, self.running, let h = self.handle {
                let r = WaitForSingleObject(h, 1000)
                guard self.running else { break }
                if r == 0 /* WAIT_OBJECT_0 */ {
                    MainQueue.shared.async { [weak self] in
                        self?.debounce.schedule(after: 0.25) { ConfigStore.shared.reload() }
                    }
                    if !FindNextChangeNotification(h) { break }
                }
            }
        }
        thread.name = "Termsie config watcher"
        thread.start()
    }

    func stop() {
        running = false
        if let h = handle { FindCloseChangeNotification(h) }
        handle = nil
    }
}
