import Foundation

/// One environment variable a terminal's shell is started with.
///
/// A secret keeps its value out of every file Termsie writes: the definition only holds
/// `secretRef`, an opaque name for the Keychain item that holds the value. Workspace files and
/// session.json can therefore be shared, committed or handed to another tool without the value.
struct EnvVar: Codable, Equatable {
    // Declared explicitly: writing both coder halves suppresses synthesis.
    private enum CodingKeys: String, CodingKey { case name, value, secret, secretRef }

    var name: String
    /// The value of a plain variable. Always empty for a secret.
    var value: String = ""
    var secret: Bool = false
    /// Names the Keychain item holding a secret's value. Safe to write to disk.
    var secretRef: String?

    init(name: String, value: String = "", secret: Bool = false, secretRef: String? = nil) {
        self.name = name
        self.value = secret ? "" : value
        self.secret = secret
        self.secretRef = secretRef
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
        secretRef = try c.decodeIfPresent(String.self, forKey: .secretRef)
        // A value that reached a file next to `secret: true` is ignored rather than trusted, so
        // a hand-edited file cannot quietly turn a secret back into plain text on disk.
        value = secret ? "" : (try c.decodeIfPresent(String.self, forKey: .value) ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if secret {
            try c.encode(true, forKey: .secret)
            try c.encodeIfPresent(secretRef, forKey: .secretRef)
        } else {
            try c.encode(value, forKey: .value)
        }
    }

    /// Variables Termsie itself sets to run the shell integration. Letting a workspace set them
    /// would silently break history isolation and the startup-command shim.
    static let reservedPrefix = "TERMSIE_"

    /// Why a name cannot be used, or nil when it can. POSIX shells only export names made of
    /// letters, digits and underscores that do not start with a digit.
    static func problem(withName name: String) -> String? {
        guard !name.isEmpty else { return "a variable has no name" }
        guard let first = name.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first)),
              name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) })
        else { return "“\(name)” is not a valid variable name (letters, digits and _, not starting with a digit)" }
        if name.hasPrefix(reservedPrefix) { return "“\(name)” is reserved: TERMSIE_ variables are set by Termsie itself" }
        return nil
    }

    /// Resolves layered variable lists into the values a shell is started with. Later layers win
    /// by name, which is how a terminal's own variable overrides the workspace default.
    /// - Returns: the values, and the names of secrets whose value could not be found.
    static func resolve(_ layers: [[EnvVar]]) -> (values: [String: String], missing: [String]) {
        var values: [String: String] = [:]
        var missing: [String] = []
        for layer in layers {
            for v in layer where problem(withName: v.name) == nil {
                if v.secret {
                    if let ref = v.secretRef, let stored = SecretStore.value(for: ref) {
                        values[v.name] = stored
                        missing.removeAll { $0 == v.name }
                    } else {
                        values.removeValue(forKey: v.name)
                        if !missing.contains(v.name) { missing.append(v.name) }
                    }
                } else {
                    values[v.name] = v.value
                    missing.removeAll { $0 == v.name }
                }
            }
        }
        return (values, missing)
    }
}

/// Settings shared by every terminal of one workspace (one tab), sitting between the global
/// config and a terminal's own overrides: terminal → workspace → global.
struct WorkspaceSettings: Codable, Equatable {
    var fontFamily: String?
    var fontSize: Double?
    var padding: Double?
    var lineWrap: Bool?
    /// Lines of output each terminal keeps between closing and reopening. `nil` inherits the
    /// global `restoredOutputLines`; 0 keeps nothing.
    var restoredOutputLines: Int?
    /// Set in every terminal of the workspace. A terminal's own variable of the same name wins.
    var env: [EnvVar] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding)
        lineWrap = try c.decodeIfPresent(Bool.self, forKey: .lineWrap)
        restoredOutputLines = try c.decodeIfPresent(Int.self, forKey: .restoredOutputLines)
        env = try c.decodeIfPresent([EnvVar].self, forKey: .env) ?? []
    }

    /// How many lines of output a terminal in this workspace keeps, resolved against the global
    /// setting and capped at the scrollback, which is all a terminal holds anyway.
    func resolvedOutputLines(_ config: TermsieConfig) -> Int {
        min(max(restoredOutputLines ?? config.restoredOutputLines, 0), max(config.scrollback, 0) + 500)
    }

    /// A definition with this workspace's defaults filled into the fields it leaves unset. What
    /// a terminal actually looks like, as opposed to what it stores.
    func applied(to def: TerminalDefinition) -> TerminalDefinition {
        var out = def
        if out.fontFamily?.isEmpty ?? true { out.fontFamily = fontFamily }
        if out.fontSize == nil { out.fontSize = fontSize }
        if out.padding == nil { out.padding = padding }
        if out.lineWrap == nil { out.lineWrap = lineWrap }
        return out
    }
}
