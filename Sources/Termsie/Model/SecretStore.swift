import Foundation
import Security

/// Holds the values of secret environment variables, outside every file Termsie writes.
///
/// Values live in the login Keychain as generic passwords under one service, each named by an
/// opaque reference that the definitions store instead of the value.
///
/// Scripted test runs (`--snapshot` / `--record`) can point it at a JSON file with
/// `TERMSIE_SECRETS_FILE`, so the suite never touches the user's Keychain. The file backend is
/// refused outside those runs.
enum SecretStore {
    static let service = "com.termsie.app.env"

    static func newRef() -> String {
        "s-" + UUID().uuidString.lowercased()
    }

    static func value(for ref: String) -> String? {
        if let url = testFileURL { return readTestFile(url)[ref] }
        var query = baseQuery(ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores a value, replacing any held under the same reference. `label` is what the item is
    /// called in Keychain Access, so the user can recognise it there.
    @discardableResult
    static func setValue(_ value: String, for ref: String, label: String) -> Bool {
        if let url = testFileURL {
            var all = readTestFile(url)
            all[ref] = value
            return writeTestFile(all, to: url)
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        let status = SecItemUpdate(baseQuery(ref) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            NSLog("Termsie: could not update secret \(ref): \(status)")
            return false
        }
        var add = baseQuery(ref)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess { NSLog("Termsie: could not store secret \(ref): \(added)") }
        return added == errSecSuccess
    }

    static func remove(_ ref: String) {
        if let url = testFileURL {
            var all = readTestFile(url)
            all.removeValue(forKey: ref)
            writeTestFile(all, to: url)
            return
        }
        SecItemDelete(baseQuery(ref) as CFDictionary)
    }

    private static func baseQuery(_ ref: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: ref]
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
    static func discard<S: Sequence>(_ refs: S) where S.Element == String {
        candidates.formUnion(refs)
        guard !candidates.isEmpty, !sweepScheduled else { return }
        sweepScheduled = true
        // After the current event, so the change that dropped the reference has landed.
        DispatchQueue.main.async { sweep() }
    }

    static func sweep() {
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
        for controller in AppDelegate.shared.controllers {
            if let data = try? encoder.encode(controller.snapshot()) {
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
        guard DebugDriver.isActive,
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
