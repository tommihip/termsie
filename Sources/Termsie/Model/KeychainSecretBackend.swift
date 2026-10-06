import Foundation
import Security
import TermsieCore

/// Secret values in the login Keychain, as generic passwords under one service, each named by
/// the opaque reference the definitions store instead of the value.
struct KeychainSecretBackend: SecretBackend {
    func value(for ref: String) -> String? {
        var query = baseQuery(ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setValue(_ value: String, for ref: String, label: String) -> Bool {
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

    func remove(_ ref: String) {
        SecItemDelete(baseQuery(ref) as CFDictionary)
    }

    private func baseQuery(_ ref: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: SecretStore.service,
         kSecAttrAccount as String: ref]
    }
}
