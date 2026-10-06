import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WinSDK
import CTermsieWin
import TermsieCore

/// Looks for a newer release on GitHub and, if the user agrees, replaces this copy with it.
///
/// The same feed as the macOS app. The trust anchor is the Authenticode signature: the new
/// Termsie.exe must carry a valid signature from the same signer as the copy that is running.
/// An unsigned (development) copy therefore never replaces itself, and points at the release
/// page instead. The SHA-256 GitHub reports is checked too, but it comes from the same place as
/// the download, so it only catches corruption; the signature is what refuses an impostor.
///
/// Installed from the Microsoft Store or an MSIX package, Windows updates the app itself and
/// this steps aside, as the macOS app does for Homebrew.
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

    private struct Pending {
        let version: String
        let staged: URL
        let workDir: URL
    }

    private var busy = false
    private var timer: RepeatingTimer?
    private var pending: Pending?
    private var relaunch = false

    private var stateURL: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base).appendingPathComponent("Termsie", isDirectory: true).appendingPathComponent("updater.json")
    }

    private var state: State {
        get { (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State() }
        set {
            try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: stateURL, options: .atomic) }
        }
    }

    /// The architecture of this build, which is the one its replacement must match.
    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    static var executableURL: URL {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let n = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        return URL(fileURLWithPath: String(decoding: buffer.prefix(n), as: UTF16.self))
    }

    /// Packaged (MSIX) installs live under WindowsApps, which only Windows may change.
    private static var isPackaged: Bool {
        executableURL.path.lowercased().contains("\\windowsapps\\") || executableURL.path.lowercased().contains("/windowsapps/")
    }

    private static var installDir: URL { executableURL.deletingLastPathComponent() }

    // MARK: Scheduling

    func startAutomaticChecks() {
        guard !DebugDriver.isActive else { return }
        MainQueue.shared.after(15) { [weak self] in self?.checkIfDue() }
        timer = RepeatingTimer(interval: 60 * 60) { [weak self] in self?.checkIfDue() }
        timer?.start()
    }

    private func checkIfDue() {
        guard ConfigStore.shared.config.updates.checkAutomatically, !busy, pending == nil, !Updater.isPackaged else { return }
        if let last = state.lastCheck, Date().timeIntervalSince(last) < Updater.checkInterval { return }
        check(interactive: false, owner: App.shared.keyWindow?.hwnd)
    }

    /// The menu item. Always answers, including "you're up to date", and ignores a skipped version.
    func checkNow(owner: HWND?) {
        if let pending {
            if Alert.yesNo("Termsie \(pending.version) is ready to install",
                           "It installs when Termsie quits. Restart now to install it?", owner: owner) {
                relaunch = true
                App.shared.quit()
            }
            return
        }
        if Updater.isPackaged {
            Alert.info("Updates", "This copy of Termsie was installed as a package, and Windows keeps it up to date.", owner: owner)
            return
        }
        check(interactive: true, owner: owner)
    }

    private func check(interactive: Bool, owner: HWND?) {
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
        // TERMSIE_UPDATE_FEED points the check at a local copy of the API response, for testing
        // the install path. It cannot loosen the signature check.
        let url = ProcessInfo.processInfo.environment["TERMSIE_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        if url.isFileURL {
            let result = Result { try ReleaseFeed.parse(try Data(contentsOf: url)) }
            MainQueue.shared.async { completion(result) }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Termsie/\(AppInfo.version) (Windows)", forHTTPHeaderField: "User-Agent")
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

    private func offer(_ release: ReleaseInfo, interactive: Bool, owner: HWND?) {
        let current = AppInfo.version
        guard ReleaseFeed.isNewer(release.version, than: current) else {
            if interactive { Alert.info("Termsie is up to date", "Termsie \(current) is the newest version.", owner: owner) }
            return
        }
        if !interactive, state.skippedVersion == release.version { return }
        guard let asset = release.windowsZip(arch: Updater.arch) else {
            if interactive || Alert.yesNo("Termsie \(release.version) is available",
                                          "There is no Windows download for it yet. Open the release page?", owner: owner) {
                Shell.open(release.pageURL.absoluteString)
            }
            return
        }
        let notes = release.notes.split(separator: "\n").prefix(14).joined(separator: "\n")
        switch Alert.yesNoCancel("Termsie \(release.version) is available",
                                 "You have \(current). Installing downloads the new version, checks its signature, and replaces this copy when Termsie quits.\n\n\(notes)\n\nYes installs, No skips this version.",
                                 owner: owner) {
        case .first: install(release, asset: asset, owner: owner)
        case .second:
            var s = state
            s.skippedVersion = release.version
            state = s
        case .third: break
        }
    }

    // MARK: Installing

    private static var inPlaceBlocker: String? {
        let dir = installDir
        let probe = dir.appendingPathComponent(".termsie-write-test")
        if FileManager.default.createFile(atPath: probe.path, contents: Data()) {
            try? FileManager.default.removeItem(at: probe)
            return nil
        }
        return "Termsie can't replace itself in \(dir.path) without an administrator's permission."
    }

    /// The signer of the running copy, nil when it is unsigned.
    static var currentSigner: String? {
        signer(of: executableURL.path)
    }

    static func signer(of path: String) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 512)
        let ok = withWide(path) { tw_verify_signature($0, &buffer, Int32(buffer.count)) }
        guard ok != 0 else { return nil }
        let name = String(wideBuffer: buffer)
        return name.isEmpty ? "(unnamed signer)" : name
    }

    private func install(_ release: ReleaseInfo, asset: ReleaseInfo.Asset, owner: HWND?) {
        if let blocker = Updater.inPlaceBlocker {
            Alert.info("Install Termsie \(release.version) by hand", blocker + "\n\nThe release page will open.", owner: owner)
            Shell.open(release.pageURL.absoluteString)
            return
        }
        guard let signer = Updater.currentSigner else {
            Alert.info("Install Termsie \(release.version) by hand",
                       "This copy of Termsie is not signed, so it cannot check that an update comes from the same publisher.\n\nThe release page will open.",
                       owner: owner)
            Shell.open(release.pageURL.absoluteString)
            return
        }
        busy = true
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("termsie-update-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(asset.name)
        URLSession.shared.downloadTask(with: asset.url) { [weak self] location, response, error in
            var failure: String?
            if let error { failure = error.localizedDescription }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 { failure = "HTTP \(http.statusCode)" }
            else if let location {
                do { try FileManager.default.moveItem(at: location, to: zip) } catch { failure = error.localizedDescription }
            }
            MainQueue.shared.async {
                guard let self else { return }
                if let failure {
                    self.busy = false
                    Alert.error("The update could not be downloaded", failure, owner: owner)
                    return
                }
                self.verifyAndStage(release: release, asset: asset, zip: zip, work: work, signer: signer, owner: owner)
            }
        }.resume()
    }

    private func verifyAndStage(release: ReleaseInfo, asset: ReleaseInfo.Asset, zip: URL, work: URL, signer: String, owner: HWND?) {
        defer { busy = false }
        func refuse(_ why: String) {
            try? FileManager.default.removeItem(at: work)
            Alert.error("The update was not installed", why, owner: owner)
        }
        if let expected = asset.sha256 {
            var digest = [UInt8](repeating: 0, count: 32)
            let ok = withWide(ShellIntegration.nativePath(zip)) { tw_sha256_file($0, &digest) }
            guard ok != 0, ReleaseFeed.hex(digest) == expected.lowercased() else {
                return refuse("The download is damaged: its checksum does not match the one GitHub lists.")
            }
        }
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try? FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        // tar.exe has shipped with Windows since 1803 and reads zip files.
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: system + "\\System32\\tar.exe")
        tar.arguments = ["-xf", ShellIntegration.nativePath(zip), "-C", ShellIntegration.nativePath(extracted)]
        do {
            try tar.run()
            tar.waitUntilExit()
        } catch {
            return refuse("The download could not be unpacked: \(error.localizedDescription)")
        }
        guard tar.terminationStatus == 0 else { return refuse("The download could not be unpacked.") }
        // The zip holds a Termsie folder; accept the files at the top level too.
        var staged = extracted.appendingPathComponent("Termsie", isDirectory: true)
        if !FileManager.default.fileExists(atPath: staged.appendingPathComponent("Termsie.exe").path) { staged = extracted }
        let exe = staged.appendingPathComponent("Termsie.exe")
        guard FileManager.default.fileExists(atPath: exe.path) else { return refuse("The download holds no Termsie.exe.") }
        guard let newSigner = Updater.signer(of: ShellIntegration.nativePath(exe)) else {
            return refuse("The new Termsie.exe is not validly signed.")
        }
        guard newSigner == signer else {
            return refuse("The new Termsie.exe is signed by “\(newSigner)”, not “\(signer)” who signed this copy.")
        }
        pending = Pending(version: release.version, staged: staged, workDir: work)
        if Alert.yesNo("Termsie \(release.version) is ready", "Restart Termsie now to finish installing it? Otherwise it installs the next time Termsie quits.",
                       owner: owner) {
            relaunch = true
            App.shared.quit()
        }
    }

    /// Called on the way out: hands the swap to a helper that waits for this process to end,
    /// copies the new files over this copy, and starts Termsie again when asked to.
    func installPendingUpdate() {
        guard let pending else { return }
        self.pending = nil
        let pid = GetCurrentProcessId()
        let target = ShellIntegration.nativePath(Updater.installDir)
        let source = ShellIntegration.nativePath(pending.staged)
        let script = pending.workDir.appendingPathComponent("install.cmd")
        var lines = [
            "@echo off",
            ":wait",
            "tasklist /FI \"PID eq \(pid)\" | find \"\(pid)\" >nul && (timeout /t 1 /nobreak >nul & goto wait)",
            "robocopy \"\(source)\" \"\(target)\" /E /R:10 /W:1 /NFL /NDL /NJH /NJS /NP >nul",
        ]
        if relaunch { lines.append("start \"\" \"\(target)\\Termsie.exe\"") }
        lines.append("rmdir /S /Q \"\(ShellIntegration.nativePath(pending.workDir))\" >nul 2>&1")
        do {
            try lines.joined(separator: "\r\n").write(to: script, atomically: true, encoding: .utf8)
        } catch {
            Log.write("could not write the update script: \(error)")
            return
        }
        let cmd = (ProcessInfo.processInfo.environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe")
        let commandLine = WindowsCommandLine.build(executable: cmd, arguments: ["/c", ShellIntegration.nativePath(script)])
        if withWide(commandLine, { tw_spawn_detached($0) }) == 0 {
            Log.write("could not start the update helper")
        }
    }
}
