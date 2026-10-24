import Foundation

/// What makes a terminal an SSH session rather than a local shell: where to connect and how to
/// log in.
///
/// Termsie runs the system's own `ssh` with these settings, so `~/.ssh/config`, the agent,
/// `known_hosts` and ProxyJump all keep working. Credentials never reach a file Termsie writes:
/// a password, a key's passphrase or a stored private key lives in the Keychain, and the
/// definition holds only the opaque reference, exactly like a secret environment variable.
struct SSHConnection: Codable, Equatable {
    /// Which private key `ssh` offers.
    enum Identity: String, Codable, CaseIterable {
        /// Whatever `~/.ssh/config` and the agent provide. Nothing is passed.
        case automatic
        /// A key file on disk, passed with `-i`.
        case keyFile
        /// A private key kept in the Keychain, written to a private file only while connected.
        case storedKey
    }

    var host: String = ""
    /// `nil` lets `~/.ssh/config` or the local user name decide.
    var user: String?
    /// `nil` lets `~/.ssh/config` decide, normally 22.
    var port: Int?
    var identity: Identity = .automatic
    /// The key file for `.keyFile`, stored tilde-preserving.
    var identityFile: String?
    /// Keychain reference of the login password, answered when the server asks for one.
    var passwordRef: String?
    /// Keychain reference of the private key's passphrase.
    var passphraseRef: String?
    /// Keychain reference of the private key itself, for `.storedKey`.
    var privateKeyRef: String?
    /// Extra `ssh -o` options as `Key=Value`, e.g. `ProxyJump=bastion`.
    var options: [String] = []

    init(host: String = "", user: String? = nil, port: Int? = nil) {
        self.host = host
        self.user = user
        self.port = port
    }

    /// Tolerant decode, like the rest of the model: a hand-written `{"host": "db1"}` is enough.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identity = (try? c.decodeIfPresent(Identity.self, forKey: .identity)) ?? .automatic
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        passwordRef = try c.decodeIfPresent(String.self, forKey: .passwordRef)
        passphraseRef = try c.decodeIfPresent(String.self, forKey: .passphraseRef)
        privateKeyRef = try c.decodeIfPresent(String.self, forKey: .privateKeyRef)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
    }

    /// `user@host:port`, leaving out what is not set. What the terminal is called by default.
    var destination: String {
        var out = host
        if let user, !user.isEmpty { out = user + "@" + out }
        if let port, port != 22 { out += ":\(port)" }
        return out
    }

    /// Every Keychain reference this connection uses.
    var secretRefs: [String] {
        [passwordRef, passphraseRef, privateKeyRef].compactMap { $0 }
    }

    // MARK: Validation

    /// Options that make `ssh` run a local command. A workspace file can be shared, so opening
    /// one must never be able to run something on this Mac just by connecting.
    static let refusedOptions: Set<String> = [
        "proxycommand", "localcommand", "permitlocalcommand", "knownhostscommand",
        "pkcs11provider", "securitykeyprovider", "include", "match",
    ]

    /// Why this connection cannot be started, or nil when it can.
    var problem: String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return "no host is set" }
        // A leading dash would be read by ssh as an option rather than a host.
        guard !h.hasPrefix("-"), !Self.hasUnsafeCharacters(h) else { return "“\(host)” is not a valid host" }
        if let user, user.hasPrefix("-") || Self.hasUnsafeCharacters(user) {
            return "“\(user)” is not a valid user name"
        }
        if let port, !(1...65535).contains(port) { return "port \(port) is out of range" }
        for option in options {
            let parts = option.split(separator: "=", maxSplits: 1)
            let key = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard parts.count == 2, !key.isEmpty, !key.contains(" "), !key.hasPrefix("-") else {
                return "“\(option)” is not an option of the form Key=Value"
            }
            if Self.refusedOptions.contains(key.lowercased()) {
                return "\(key) is not allowed here, because it runs a command on this Mac — put it in ~/.ssh/config instead"
            }
        }
        if identity == .keyFile, (identityFile ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "no key file is chosen"
        }
        if identity == .storedKey, privateKeyRef == nil { return "no private key is stored" }
        return nil
    }

    private static func hasUnsafeCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
}
