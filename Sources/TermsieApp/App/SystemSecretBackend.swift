import Foundation
import CTermsieHost
import TermsieCore

/// Secret values in the system's store, named `Termsie/com.termsie.app.env/<reference>`: generic
/// credentials in the Windows Credential Manager (under Windows Credentials in Control Panel),
/// items in the Secret Service (GNOME Keyring, KWallet) on Linux, labelled with the variable and
/// the terminal that uses it.
///
/// A Windows generic credential holds at most 2,560 bytes, which is far beyond any token or
/// password but is a limit the Keychain does not have; a longer value is refused and reported.
struct SystemSecretBackend: SecretBackend {
    static let maxBytes = 2560

    private func target(_ ref: String) -> String {
        "Termsie/\(SecretStore.service)/\(ref)"
    }

    func value(for ref: String) -> String? {
        var blob: UnsafeMutableRawPointer?
        let length = withWide(target(ref)) { tw_cred_read($0, &blob) }
        guard length >= 0, let blob else { return nil }
        defer { tw_free(blob) }
        return String(decoding: UnsafeRawBufferPointer(start: blob, count: Int(length)), as: UTF8.self)
    }

    func setValue(_ value: String, for ref: String, label: String) -> Bool {
        let data = Array(value.utf8)
        guard data.count <= SystemSecretBackend.maxBytes else {
            Log.write("secret \(ref) is \(data.count) bytes; the store holds at most \(SystemSecretBackend.maxBytes)")
            return false
        }
        let ok = withWide(target(ref), label) { t, l in
            data.withUnsafeBytes { tw_cred_write(t, l, $0.baseAddress, UInt32($0.count)) }
        }
        if ok == 0 { Log.write("could not store secret \(ref) in \(Host.secretStoreName)") }
        return ok != 0
    }

    func remove(_ ref: String) {
        _ = withWide(target(ref)) { tw_cred_delete($0) }
    }
}
