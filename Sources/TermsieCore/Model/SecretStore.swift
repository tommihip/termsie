import Foundation

/// Where secret values actually live. macOS keeps them in the login Keychain, Windows in the
/// Credential Manager; each front end installs its backend at launch.
public protocol SecretBackend {
    func value(for ref: String) -> String?
    /// Stores a value, replacing any held under the same reference. `label` is what the item is
    /// called in the system's credential UI, so the user can recognise it there.
    func setValue(_ value: String, for ref: String, label: String) -> Bool
    func remove(_ ref: String)
}

/// Holds the values of secret environment variables, outside every file Termsie writes.
///
/// Values live in the system credential store, each named by an opaque reference that the
/// definitions store instead of the value.
///
/// Scripted test runs (`--snapshot` / `--record`) can point it at a JSON file with
/// `TERMSIE_SECRETS_FILE`, so the suite never touches the user's credential store. The file
/// backend is refused outside those runs.
public enum SecretStore {
    public static let service = "com.termsie.app.env"

    /// The platform's store. Until one is installed, secrets cannot be read or written, which
    /// the callers already treat as "not found".
    public static var backend: SecretBackend?
    /// True for a scripted test run; only then is `TERMSIE_SECRETS_FILE` honoured.
    public static var testModeEnabled = false
    /// The tabs open right now, as they would be saved. A reference still used by one of them
    /// is never deleted.
    public static var openTabs: () -> [TabLayout] = { [] }

    public static func newRef() -> String {
        "s-" + UUID().uuidString.lowercased()
    }

    public static func value(for ref: String) -> String? {
        if let url = testFileURL { return readTestFile(url)[ref] }
        return backend?.value(for: ref)
    }

    @discardableResult
    public static func setValue(_ value: String, for ref: String, label: String) -> Bool {
        if let url = testFileURL {
            var all = readTestFile(url)
            all[ref] = value
            return writeTestFile(all, to: url)
        }
        guard let backend else {
            NSLog("Termsie: no secret store available; \(ref) not saved")
            return false
        }
        return backend.setValue(value, for: ref, label: label)
    }

    public static func remove(_ ref: String) {
        if let url = testFileURL {
            var all = readTestFile(url)
            all.removeValue(forKey: ref)
            writeTestFile(all, to: url)
            return
        }
        backend?.remove(ref)
    }

    // MARK: Clean-up

    /// References that may no longer be used by anything, waiting for `sweep()`.
    private static var candidates = Set<String>()
    private static var sweepScheduled = false

    /// Offers references for deletion. Each is deleted only if nothing still refers to it — no
    /// open tab and no saved workspace — so removing a secret from one copy of a workspace can
    /// never break another.
    ///
    /// Only references somebody explicitly let go of are ever considered. Sweeping every item
    /// under the service instead would delete the secrets of a workspace file kept outside the
    /// workspaces folder, which Termsie has no way to see.
    public static func discard<S: Sequence>(_ refs: S) where S.Element == String {
        candidates.formUnion(refs)
        guard !candidates.isEmpty, !sweepScheduled else { return }
        sweepScheduled = true
        // After the current event, so the change that dropped the reference has landed.
        MainScheduler.async { sweep() }
    }

    public static func sweep() {
        sweepScheduled = false
        guard !candidates.isEmpty else { return }
        let referenced = referencedText()
        for ref in candidates where !referenced.contains(where: { $0.contains(ref) }) {
            remove(ref)
        }
        candidates.removeAll()
    }

    /// Every place a reference can legitimately live, as text. A plain substring test is exact
    /// enough: a reference is a UUID, and cannot occur by accident.
    private static func referencedText() -> [String] {
        var texts: [String] = []
        let encoder = JSONEncoder()
        for tab in openTabs() {
            if let data = try? encoder.encode(tab) {
                texts.append(String(decoding: data, as: UTF8.self))
            }
        }
        let fm = FileManager.default
        let dir = ConfigStore.shared.workspacesDir
        for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".json") {
            if let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) {
                texts.append(text)
            }
        }
        if let text = try? String(contentsOf: ConfigStore.shared.sessionURL, encoding: .utf8) {
            texts.append(text)
        }
        return texts
    }

    // MARK: Test backend

    private static var testFileURL: URL? {
        guard testModeEnabled,
              let path = ProcessInfo.processInfo.environment["TERMSIE_SECRETS_FILE"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func readTestFile(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    @discardableResult
    private static func writeTestFile(_ dict: [String: String], to url: URL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(dict) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
