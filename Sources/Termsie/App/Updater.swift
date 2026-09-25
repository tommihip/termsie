import AppKit
import CryptoKit
import Security

/// Looks for a newer release on GitHub and, if the user agrees, replaces this app with it.
///
/// There is no update framework. Releases are already published to GitHub as notarised dmgs, so
/// the feed is the GitHub releases API, and the trust anchor is the Developer ID signature on the
/// app inside the dmg, pinned to the team that signs Termsie. The checksum GitHub reports for the
/// asset is checked too, but it comes from the same place as the download, so it only catches
/// corruption; the signature is what refuses an impostor.
///
/// The swap happens after Termsie has quit, from a small shell script, so a running binary is
/// never overwritten. If the quit is cancelled (a process the user chose to keep), the verified
/// copy stays staged and goes in whenever Termsie next quits.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private nonisolated static let repo = "tommihip/termsie"
    private nonisolated static let bundleID = "com.termsie.app"
    /// The team whose Developer ID signs releases. Anything signed by anyone else is refused.
    private nonisolated static let teamID = "44Y68253MG"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private enum DefaultsKey {
        static let lastCheck = "UpdaterLastCheck"
        static let skippedVersion = "UpdaterSkippedVersion"
    }

    struct Release {
        let version: String
        let notes: String
        let pageURL: URL
        let dmgURL: URL?
        /// Hex SHA-256 of the dmg, when GitHub reports one.
        let sha256: String?
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// A verified app waiting in a temporary directory on the same volume as this one.
    private struct PendingInstall {
        let version: String
        let staged: URL
        let workDir: URL
    }

    private var busy = false
    private var timer: Timer?
    private var pending: PendingInstall?
    private var relaunchAfterInstall = false
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    private var cancelled = false

    /// The version on disk, which is the one being replaced. `AppInfo.version` covers a binary run
    /// outside a bundle.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppInfo.version
    }

    // MARK: Scheduling

    /// A first look shortly after launch, once the session has been restored, then hourly ticks
    /// that only reach the network when a day has passed since the last successful check. A
    /// laptop that was asleep or offline catches up within the hour.
    func startAutomaticChecks() {
        guard !DebugDriver.isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard ConfigStore.shared.config.updates.checkAutomatically, !busy, pending == nil else { return }
        if let last = UserDefaults.standard.object(forKey: DefaultsKey.lastCheck) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    /// The menu item. Always answers, including "you're up to date", and ignores a skipped version.
    func checkNow() {
        guard !busy else { return }
        if let pending {
            let alert = NSAlert()
            alert.messageText = "Termsie \(pending.version) is ready to install"
            alert.informativeText = "It will be installed when Termsie quits. Restart now to finish?"
            alert.addButton(withTitle: "Restart Now")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { restartToInstall() }
            return
        }
        Task { await check(userInitiated: true) }
    }

    // MARK: Checking

    private func check(userInitiated: Bool) async {
        busy = true
        defer { busy = false }

        let release: Release
        do {
            release = try await Self.fetchLatestRelease()
        } catch {
            if userInitiated {
                showError("Termsie couldn't check for updates", error)
            } else {
                NSLog("Termsie: update check failed: \(error.localizedDescription)")
            }
            return
        }
        UserDefaults.standard.set(Date(), forKey: DefaultsKey.lastCheck)

        let current = Self.currentVersion
        guard Self.isNewer(release.version, than: current) else {
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = "You're up to date"
                alert.informativeText = "Termsie \(current) is the newest version."
                alert.runModal()
            }
            return
        }
        if !userInitiated {
            if UserDefaults.standard.string(forKey: DefaultsKey.skippedVersion) == release.version { return }
            // Not while someone is typing into another app; the offer waits for them to come back.
            await waitUntilActive()
        }

        switch ask(about: release, current: current) {
        case .alertFirstButtonReturn:
            if let blocker = Self.inPlaceBlocker {
                offerDownloadPage(release, reason: blocker)
            } else {
                await install(release)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: DefaultsKey.skippedVersion)
        default:
            break
        }
    }

    private func ask(about release: Release, current: String) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Termsie \(release.version) is available"
        alert.informativeText = "You have \(current). Installing downloads the new version, checks its signature, "
            + "then restarts Termsie. Your terminals reopen, but anything running in them is ended."
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        if !release.notes.isEmpty { alert.accessoryView = notesView(release.notes) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func notesView(_ markdown: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.autoresizingMask = [.width]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let body = (try? NSMutableAttributedString(markdown: markdown, options: options))
            ?? NSMutableAttributedString(string: markdown)
        body.addAttributes([.font: UIFonts.system(size: 12), .foregroundColor: NSColor.labelColor],
                           range: NSRange(location: 0, length: body.length))
        text.textStorage?.setAttributedString(body)
        scroll.documentView = text
        return scroll
    }

    private func waitUntilActive() async {
        guard !NSApp.isActive else { return }
        for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
            break
        }
    }

    private nonisolated static func fetchLatestRelease() async throws -> Release {
        // TERMSIE_UPDATE_FEED points the check at a local copy of the API response, for testing
        // the install path. It cannot loosen the signature check.
        let url = ProcessInfo.processInfo.environment["TERMSIE_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Termsie/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub answered with HTTP \(http.statusCode).")
        }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
                let digest: String?
            }
            let tagName: String
            let htmlUrl: URL
            let body: String?
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Payload.self, from: data)
        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        let dmg = payload.assets.first { $0.name == "\(AppInfo.name)-\(version).dmg" }
            ?? payload.assets.first { $0.name.hasSuffix(".dmg") }
        let sha = dmg?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, notes: payload.body ?? "", pageURL: payload.htmlUrl,
                       dmgURL: dmg?.browserDownloadUrl, sha256: sha)
    }

    /// Numeric, component-wise, so 0.10.0 is newer than 0.9.0. Missing components count as zero.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let trimmed = s.hasPrefix("v") ? s.dropFirst() : Substring(s)
            return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    /// Why the running copy cannot replace itself, or nil when it can.
    private static var inPlaceBlocker: String? {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else {
            return "This copy of Termsie is not running from an app bundle."
        }
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running Termsie from a temporary location. Move it to your Applications folder, open it from there, and try again."
        }
        let parent = app.deletingLastPathComponent().path
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: app.path) else {
            return "Termsie can't replace itself in \(parent) without an administrator's permission."
        }
        return nil
    }

    private func install(_ release: Release) async {
        guard let dmgURL = release.dmgURL else {
            offerDownloadPage(release, reason: "The release has no disk image attached.")
            return
        }
        let fm = FileManager.default
        let panel = UpdateProgressPanel(title: "Downloading Termsie \(release.version)…") { [weak self] in
            self?.cancelled = true
            self?.downloadTask?.cancel()
        }
        cancelled = false
        panel.show()

        var workDir: URL?
        do {
            // Same volume as the app, so moving it into place is a rename.
            let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: Bundle.main.bundleURL, create: true)
            workDir = dir
            let dmg = try await download(dmgURL, into: dir, panel: panel)
            if cancelled { throw CancellationError() }

            panel.setStatus("Verifying…")
            if let sha = release.sha256 { try await Self.verifyDigest(of: dmg, sha256: sha) }
            let staged = try await Self.extractApp(from: dmg, into: dir)
            try await Self.verifySignature(of: staged)
            let version = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String ?? "?"
            // A validly signed old release is still a downgrade; never install one.
            guard Self.isNewer(version, than: Self.currentVersion) else {
                throw UpdateError("The download is version \(version), which is not newer than this one.")
            }
            if cancelled { throw CancellationError() }
            try? fm.removeItem(at: dmg)
            pending = PendingInstall(version: version, staged: staged, workDir: dir)
        } catch {
            panel.close()
            if let workDir { try? fm.removeItem(at: workDir) }
            if cancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            showError("Termsie \(release.version) couldn't be installed", error, page: release.pageURL)
            return
        }
        panel.close()
        restartToInstall()
    }

    private func restartToInstall() {
        relaunchAfterInstall = true
        NSApp.terminate(nil)
        // Only reached when the quit was cancelled. The update stays staged for the next quit,
        // which the user did not ask to turn into a restart.
        relaunchAfterInstall = false
    }

    private func download(_ url: URL, into dir: URL, panel: UpdateProgressPanel) async throws -> URL {
        let destination = dir.appendingPathComponent(url.lastPathComponent)
        defer {
            progressObservation = nil
            downloadTask = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                // The temporary file is deleted when this handler returns, so move it now.
                if let error { return continuation.resume(throwing: error) }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    return continuation.resume(throwing: UpdateError("The download failed with HTTP \(http.statusCode)."))
                }
                guard let tmp else { return continuation.resume(throwing: UpdateError("The download was empty.")) }
                do {
                    try FileManager.default.moveItem(at: tmp, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let fraction = progress.fractionCompleted
                DispatchQueue.main.async { panel.setProgress(fraction) }
            }
            downloadTask = task
            task.resume()
        }
    }

    private nonisolated static func verifyDigest(of file: URL, sha256 expected: String) async throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw UpdateError("The download is damaged: its checksum does not match the release.")
        }
    }

    /// Copies the app out of the dmg into `dir`. The image is mounted privately (no Finder window,
    /// not browsable) and always detached again.
    private nonisolated static func extractApp(from dmg: URL, into dir: URL) async throws -> URL {
        let mount = dir.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                     "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let source = mount.appendingPathComponent("\(AppInfo.name).app")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw UpdateError("The disk image does not contain \(AppInfo.name).app.")
        }
        let staged = dir.appendingPathComponent("\(AppInfo.name).app")
        // ditto keeps the signature, extended attributes and symlinks exactly as signed.
        try run("/usr/bin/ditto", [source.path, staged.path])
        return staged
    }

    /// Refuses anything not signed with a Developer ID certificate issued to Termsie's team, for
    /// Termsie's bundle identifier, with every architecture and nested bundle intact.
    private nonisolated static func verifySignature(of app: URL) async throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The downloaded app could not be read.")
        }
        let text = "anchor apple generic"
            + " and identifier \"\(bundleID)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"      // Developer ID CA
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"  // Developer ID Application
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError("The signature requirement could not be built.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw UpdateError("The download is not signed by Termsie's developer (\(reason)), so it was not installed.")
        }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = (tool as NSString).lastPathComponent
            throw UpdateError("\(name) failed (\(process.terminationStatus))\(message.isEmpty ? "" : ": \(message)")")
        }
    }

    /// Called as Termsie terminates. Hands the swap to a detached script that waits for this
    /// process to exit, moves the old app aside, moves the new one in (putting the old one back if
    /// that fails), and reopens Termsie when the quit was a restart for the update.
    func installPendingUpdate() {
        guard let pending else { return }
        let script = """
        pid=$1 staged=$2 app=$3 work=$4 relaunch=$5
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i + 1)); [ "$i" -gt 600 ] && exit 1
          sleep 0.1
        done
        if mv "$app" "$work/previous.app"; then
          if mv "$staged" "$app"; then
            rm -rf "$work"
          else
            mv "$work/previous.app" "$app"
          fi
        fi
        [ "$relaunch" = 1 ] && open "$app"
        exit 0
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "termsie-update", String(getpid()), pending.staged.path,
                             Bundle.main.bundleURL.path, pending.workDir.path, relaunchAfterInstall ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("Termsie: could not start the update installer: \(error)")
        }
    }

    // MARK: Alerts

    private func offerDownloadPage(_ release: Release, reason: String) {
        let alert = NSAlert()
        alert.messageText = "Termsie can't update itself here"
        alert.informativeText = reason + "\n\nYou can download Termsie \(release.version) from its release page instead."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
    }

    private func showError(_ title: String, _ error: Error, page: URL? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if page != nil { alert.addButton(withTitle: "Open Release Page") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, let page { NSWorkspace.shared.open(page) }
    }
}

/// A small floating window with a progress bar and a Cancel button, shown while an update
/// downloads and is verified.
final class UpdateProgressPanel: NSObject {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let onCancel: () -> Void

    init(title: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 108),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "Software Update"
        panel.isReleasedWhenClosed = false
        let content = panel.contentView!

        label.stringValue = title
        label.font = UIFonts.system(size: 13, weight: .semibold)
        label.frame = NSRect(x: 20, y: 72, width: 340, height: 18)
        content.addSubview(label)

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = NSRect(x: 20, y: 46, width: 340, height: 20)
        content.addSubview(bar)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 276, y: 10, width: 90, height: 28)
        content.addSubview(cancel)
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.close() }

    func setProgress(_ fraction: Double) { bar.doubleValue = fraction }

    /// Switches to an indeterminate bar for the steps whose length is unknown.
    func setStatus(_ text: String) {
        label.stringValue = text
        bar.isIndeterminate = true
        bar.startAnimation(nil)
    }

    @objc private func cancelPressed() { onCancel() }
}
