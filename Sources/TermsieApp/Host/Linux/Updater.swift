import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TermsieCore

/// Looks for a newer release on GitHub and points at its page.
///
/// The same feed as the other apps, without the download: a Linux install has no signature the
/// app could pin a replacement to, and a copy under /usr or /opt belongs to a package manager,
/// which keeps it up to date itself.
final class Updater {
    static let shared = Updater()

    private static var repo: String {
        ProcessInfo.processInfo.environment["TERMSIE_UPDATE_REPO"] ?? "tommihip/termsie"
    }
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private struct State: Codable {
        var lastCheck: Date?
        var skippedVersion: String?
    }

    private var busy = false
    private var timer: RepeatingTimer?

    private var stateURL: URL { Host.logDirectory.appendingPathComponent("updater.json") }

    private var state: State {
        get { (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State() }
        set {
            try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: stateURL, options: .atomic) }
        }
    }

    /// Installed by a package manager: it owns updates.
    private static var isPackaged: Bool {
        let path = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        return path.hasPrefix("/usr/") || path.hasPrefix("/opt/") || path.hasPrefix("/app/") || path.hasPrefix("/snap/")
    }

    // MARK: Scheduling

    func startAutomaticChecks() {
        guard !DebugDriver.isActive else { return }
        MainQueue.shared.after(15) { [weak self] in self?.checkIfDue() }
        timer = RepeatingTimer(interval: 60 * 60) { [weak self] in self?.checkIfDue() }
        timer?.start()
    }

    private func checkIfDue() {
        guard ConfigStore.shared.config.updates.checkAutomatically, !busy, !Updater.isPackaged else { return }
        if let last = state.lastCheck, Date().timeIntervalSince(last) < Updater.checkInterval { return }
        check(interactive: false, owner: App.shared.keyWindow?.ref)
    }

    /// The menu item. Always answers, including "you're up to date", and ignores a skipped version.
    func checkNow(owner: WindowRef?) {
        if Updater.isPackaged {
            Alert.info("Updates", "This copy of Termsie was installed as a package, and your package manager keeps it up to date.",
                       owner: owner)
            return
        }
        check(interactive: true, owner: owner)
    }

    /// Nothing is staged on Linux; the app never replaces itself.
    func installPendingUpdate() {}

    private func check(interactive: Bool, owner: WindowRef?) {
        guard !busy else { return }
        busy = true
        Updater.fetchLatest { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .failure(let error):
                if interactive { Alert.error("Could not check for updates", error.localizedDescription, owner: owner) }
            case .success(let release):
                var s = self.state
                s.lastCheck = Date()
                self.state = s
                self.offer(release, interactive: interactive, owner: owner)
            }
        }
    }

    private static func fetchLatest(_ completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        // TERMSIE_UPDATE_FEED points the check at a local copy of the API response, for testing.
        let url = ProcessInfo.processInfo.environment["TERMSIE_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        if url.isFileURL {
            let result = Result { try ReleaseFeed.parse(try Data(contentsOf: url)) }
            MainQueue.shared.async { completion(result) }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Termsie/\(AppInfo.version) (Linux)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<ReleaseInfo, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(ReleaseFeed.FeedError("GitHub answered with HTTP \(http.statusCode)."))
            } else if let data {
                result = Result { try ReleaseFeed.parse(data) }
            } else {
                result = .failure(ReleaseFeed.FeedError("GitHub sent nothing back."))
            }
            MainQueue.shared.async { completion(result) }
        }.resume()
    }

    private func offer(_ release: ReleaseInfo, interactive: Bool, owner: WindowRef?) {
        let current = AppInfo.version
        guard ReleaseFeed.isNewer(release.version, than: current) else {
            if interactive { Alert.info("Termsie is up to date", "Termsie \(current) is the newest version.", owner: owner) }
            return
        }
        if !interactive, state.skippedVersion == release.version { return }
        let notes = release.notes.split(separator: "\n").prefix(14).joined(separator: "\n")
        switch Alert.yesNoCancel("Termsie \(release.version) is available",
                                 "You have \(current).\n\n\(notes)\n\nYes opens the release page, No skips this version.",
                                 owner: owner) {
        case .first: Shell.open(release.pageURL.absoluteString)
        case .second:
            var s = state
            s.skippedVersion = release.version
            state = s
        case .third: break
        }
    }
}
