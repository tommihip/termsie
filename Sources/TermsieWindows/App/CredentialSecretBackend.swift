import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// Secret values in the Windows Credential Manager, as generic credentials named
/// `Termsie/com.termsie.app.env/<reference>`. They show up under Windows Credentials in Control
/// Panel, labelled with the variable and the terminal that uses it.
///
/// A generic credential holds at most 2,560 bytes, which is far beyond any token or password but
/// is a limit the Keychain does not have; a longer value is refused and reported.
struct CredentialSecretBackend: SecretBackend {
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
        guard data.count <= CredentialSecretBackend.maxBytes else {
            Log.write("secret \(ref) is \(data.count) bytes; Credential Manager holds at most \(CredentialSecretBackend.maxBytes)")
            return false
        }
        let ok = withWide(target(ref), label) { t, l in
            data.withUnsafeBytes { tw_cred_write(t, l, $0.baseAddress, DWORD($0.count)) }
        }
        if ok == 0 { Log.write("could not store secret \(ref): \(GetLastError())") }
        return ok != 0
    }

    func remove(_ ref: String) {
        _ = withWide(target(ref)) { tw_cred_delete($0) }
    }
}
