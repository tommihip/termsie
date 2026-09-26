import Foundation

/// The editable configuration of one workspace: its defaults and each terminal's settings,
/// startup commands and environment variables. Both views of the Workspace Settings panel edit
/// this one value, so the form and the JSON can never disagree about what a field means.
///
/// Geometry, stacking and open/closed state are deliberately not part of it. They belong to the
/// canvas, and a document that carried them would fight every drag made while the panel is open.
struct WorkspaceDocument: Equatable {
    struct Variable: Equatable {
        var name: String
        /// A plain variable's value. For a secret, a new value waiting to be stored; nil keeps
        /// the stored one. Never rendered to JSON for a secret.
        var value: String?
        var secret: Bool
        /// The Keychain item holding a secret's value. Internal: never shown in either view.
        var ref: String?

        init(name: String, value: String?, secret: Bool, ref: String? = nil) {
            self.name = name; self.value = value; self.secret = secret; self.ref = ref
        }
    }

    struct Defaults: Equatable {
        var fontFamily: String?
        var fontSize: Double?
        var padding: Double?
        var lineWrap: Bool?
        var restoredOutputLines: Int?
        var env: [Variable] = []
    }

    struct Terminal: Equatable {
        var id: String
        var name: String?
        var cwd: String?
        var environment: String?
        var startupCommands: [String] = []
        var runCommandsOnReopen = true
        var isolatedHistory = true
        var fontFamily: String?
        var fontSize: Double?
        var padding: Double?
        var lineWrap: Bool?
        var env: [Variable] = []

        var displayName: String {
            if let n = name, !n.isEmpty { return n }
            if let dir = cwd, !dir.isEmpty {
                let base = ((dir as NSString).expandingTildeInPath as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
            return "shell"
        }
    }

    var workspace = Defaults()
    var terminals: [Terminal] = []

    // MARK: From and to the live model

    init(workspace: Defaults = Defaults(), terminals: [Terminal] = []) {
        self.workspace = workspace
        self.terminals = terminals
    }

    init(settings: WorkspaceSettings, definitions: [TerminalDefinition]) {
        workspace = Defaults(fontFamily: settings.fontFamily, fontSize: settings.fontSize,
                             padding: settings.padding, lineWrap: settings.lineWrap,
                             restoredOutputLines: settings.restoredOutputLines,
                             env: settings.env.map(Self.variable))
        terminals = definitions.map { def in
            Terminal(id: def.id, name: def.name, cwd: def.cwd, environment: def.environment,
                     startupCommands: def.startupCommands, runCommandsOnReopen: def.runCommandsOnReopen,
                     isolatedHistory: def.isolatedHistory, fontFamily: def.fontFamily,
                     fontSize: def.fontSize, padding: def.padding, lineWrap: def.lineWrap,
                     env: def.env.map(Self.variable))
        }
    }

    private static func variable(_ v: EnvVar) -> Variable {
        Variable(name: v.name, value: v.secret ? nil : v.value, secret: v.secret, ref: v.secretRef)
    }

    private static func envVar(_ v: Variable) -> EnvVar {
        EnvVar(name: v.name, value: v.value ?? "", secret: v.secret, secretRef: v.secret ? v.ref : nil)
    }

    var settings: WorkspaceSettings {
        var s = WorkspaceSettings()
        s.fontFamily = workspace.fontFamily
        s.fontSize = workspace.fontSize
        s.padding = workspace.padding
        s.lineWrap = workspace.lineWrap
        s.restoredOutputLines = workspace.restoredOutputLines
        s.env = workspace.env.map(Self.envVar)
        return s
    }

    /// The definitions this document describes, in its order. Fields the document does not carry
    /// (position, stacking, open state) are kept from `existing`; a terminal new to the document
    /// starts from a blank definition.
    func definitions(merging existing: [TerminalDefinition]) -> [TerminalDefinition] {
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return terminals.map { t in
            var def = byID[t.id] ?? TerminalDefinition(id: t.id)
            def.name = t.name
            def.cwd = t.cwd
            def.environment = t.environment
            def.startupCommands = t.startupCommands
            def.runCommandsOnReopen = t.runCommandsOnReopen
            def.isolatedHistory = t.isolatedHistory
            def.fontFamily = t.fontFamily
            def.fontSize = t.fontSize
            def.padding = t.padding
            def.lineWrap = t.lineWrap
            def.env = t.env.map(Self.envVar)
            return def
        }
    }

    // MARK: Secrets

    /// Moves every secret value waiting in the document into the Keychain, under a fresh
    /// reference, and forgets it here. Called before the document is shown as JSON and before
    /// it is applied, so a typed secret never reaches the text view or a file.
    ///
    /// Always a fresh reference, never the variable's existing one: until Apply the old value
    /// must stay intact, or Revert could not revert.
    /// - Returns: the references created, so the caller can offer them for clean-up if the
    ///   document is abandoned.
    mutating func stashSecrets() -> [String] {
        var created: [String] = []
        func stash(_ vars: inout [Variable], owner: String) {
            for i in vars.indices where vars[i].secret {
                guard let value = vars[i].value else { continue }
                vars[i].value = nil
                guard !value.isEmpty else { continue }
                let ref = SecretStore.newRef()
                if SecretStore.setValue(value, for: ref, label: "Termsie: \(vars[i].name) (\(owner))") {
                    vars[i].ref = ref
                    created.append(ref)
                }
            }
        }
        stash(&workspace.env, owner: "workspace")
        for i in terminals.indices { stash(&terminals[i].env, owner: terminals[i].displayName) }
        return created
    }

    /// Gives each secret that arrived without a value the reference its namesake had in
    /// `previous`, so editing the JSON (which never shows references) keeps stored values.
    mutating func adoptSecretRefs(from previous: WorkspaceDocument) {
        func adopt(_ vars: inout [Variable], from old: [Variable]) {
            for i in vars.indices where vars[i].secret && vars[i].value == nil && vars[i].ref == nil {
                vars[i].ref = old.first { $0.name == vars[i].name && $0.secret }?.ref
            }
        }
        adopt(&workspace.env, from: previous.workspace.env)
        for i in terminals.indices {
            let old = previous.terminals.first { $0.id == terminals[i].id }?.env ?? []
            adopt(&terminals[i].env, from: old)
        }
    }

    /// Every reference the document uses.
    var secretRefs: Set<String> {
        Set((workspace.env + terminals.flatMap(\.env)).compactMap { $0.secret ? $0.ref : nil })
    }

    // MARK: Validation

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Everything that would make the document unusable, in reading order.
    func problems(environments: [String]) -> [String] {
        var out: [String] = []
        if terminals.isEmpty { out.append("a workspace needs at least one terminal") }
        func check(_ vars: [Variable], at path: String) {
            var seen = Set<String>()
            for (i, v) in vars.enumerated() {
                if let problem = EnvVar.problem(withName: v.name) { out.append("\(path).env[\(i)]: \(problem)") }
                if !seen.insert(v.name).inserted { out.append("\(path).env: “\(v.name)” is set twice") }
                if v.secret && v.ref == nil && (v.value ?? "").isEmpty {
                    out.append("\(path).env[\(i)]: secret “\(v.name)” has no stored value — give it a \"value\"")
                }
            }
        }
        check(workspace.env, at: "workspace")
        var ids = Set<String>()
        for (i, t) in terminals.enumerated() {
            if !ids.insert(t.id).inserted { out.append("terminals[\(i)]: id “\(t.id)” is used twice") }
            if let env = t.environment, !environments.contains(env) {
                out.append("terminals[\(i)].environment: unknown “\(env)” (known: \(environments.joined(separator: ", ")))")
            }
            check(t.env, at: "terminals[\(i)]")
        }
        return out
    }
}

// MARK: - JSON

extension WorkspaceDocument {
    /// Pretty JSON in a fixed, readable key order. Every key is always present — `null` means
    /// "inherit" — so the text documents its own schema for whoever edits it next.
    func jsonText() -> String {
        func vars(_ list: [Variable]) -> JSONValue {
            .array(list.map { v in
                var fields: [(String, JSONValue)] = [("name", .string(v.name))]
                if v.secret {
                    // A secret's value is never rendered, even one waiting to be stored.
                    fields.append(("secret", .bool(true)))
                } else {
                    fields.append(("value", .string(v.value ?? "")))
                }
                return .object(fields)
            })
        }
        func opt(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
        func opt(_ d: Double?) -> JSONValue { d.map(JSONValue.number) ?? .null }
        func opt(_ b: Bool?) -> JSONValue { b.map(JSONValue.bool) ?? .null }

        let ws: JSONValue = .object([
            ("fontFamily", opt(workspace.fontFamily)),
            ("fontSize", opt(workspace.fontSize)),
            ("padding", opt(workspace.padding)),
            ("lineWrap", opt(workspace.lineWrap)),
            ("restoredOutputLines", workspace.restoredOutputLines.map { .number(Double($0)) } ?? .null),
            ("env", vars(workspace.env)),
        ])
        let terms: JSONValue = .array(terminals.map { t in
            .object([
                ("id", .string(t.id)),
                ("name", opt(t.name)),
                ("cwd", opt(t.cwd)),
                ("environment", opt(t.environment)),
                ("startupCommands", .array(t.startupCommands.map(JSONValue.string))),
                ("runCommandsOnReopen", .bool(t.runCommandsOnReopen)),
                ("isolatedHistory", .bool(t.isolatedHistory)),
                ("fontFamily", opt(t.fontFamily)),
                ("fontSize", opt(t.fontSize)),
                ("padding", opt(t.padding)),
                ("lineWrap", opt(t.lineWrap)),
                ("env", vars(t.env)),
            ])
        })
        return JSONValue.object([("workspace", ws), ("terminals", terms)]).rendered() + "\n"
    }

    /// Parses the JSON view. Strict about shape — an unknown key is an error, not silently
    /// dropped — because a misspelt `startupCommand` that vanishes on Apply is worse than one
    /// that is pointed out. Lenient about spelling out defaults: every key but `terminals` may
    /// be left out.
    init(jsonText: String) throws {
        let data = Data(jsonText.utf8)
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw Problem(message: "not valid JSON" + (detail.map { ": \($0)" } ?? ""))
        }
        let r = try Reader(root, path: "")
        try r.allow(["workspace", "terminals"])

        if let ws = try r.object("workspace") {
            try ws.allow(["fontFamily", "fontSize", "padding", "lineWrap", "restoredOutputLines", "env"])
            workspace = Defaults(fontFamily: try ws.string("fontFamily"),
                                 fontSize: try ws.number("fontSize", range: TermsieConfig.minFontSize...TermsieConfig.maxFontSize),
                                 padding: try ws.number("padding", range: 0...TermsieConfig.maxPadding),
                                 lineWrap: try ws.bool("lineWrap"),
                                 restoredOutputLines: try ws.integer("restoredOutputLines",
                                                                     range: 0...TermsieConfig.maxRestoredOutputLines),
                                 env: try ws.variables("env"))
        }
        guard let list = try r.array("terminals") else {
            throw Problem(message: "“terminals” is missing: list the workspace's terminals")
        }
        terminals = try list.map { t in
            try t.allow(["id", "name", "cwd", "environment", "startupCommands", "runCommandsOnReopen",
                         "isolatedHistory", "fontFamily", "fontSize", "padding", "lineWrap", "env"])
            return Terminal(
                id: try t.string("id") ?? TerminalDefinition.newID(),
                name: try t.string("name"),
                cwd: try t.string("cwd"),
                environment: try t.string("environment"),
                startupCommands: try t.lines("startupCommands"),
                runCommandsOnReopen: try t.bool("runCommandsOnReopen") ?? true,
                isolatedHistory: try t.bool("isolatedHistory") ?? true,
                fontFamily: try t.string("fontFamily"),
                fontSize: try t.number("fontSize", range: TermsieConfig.minFontSize...TermsieConfig.maxFontSize),
                padding: try t.number("padding", range: 0...TermsieConfig.maxPadding),
                lineWrap: try t.bool("lineWrap"),
                env: try t.variables("env"))
        }
    }
}

/// A typed view over one JSONSerialization object, reporting errors with a path to the field.
private struct Reader {
    let dict: [String: Any]
    let path: String

    init(_ any: Any, path: String) throws {
        guard let dict = any as? [String: Any] else {
            throw WorkspaceDocument.Problem(message: "\(path.isEmpty ? "the document" : path) must be an object")
        }
        self.dict = dict
        self.path = path
    }

    private func at(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    private func fail(_ key: String, _ what: String) -> WorkspaceDocument.Problem {
        WorkspaceDocument.Problem(message: "\(at(key)) must be \(what)")
    }

    private func present(_ key: String) -> Any? {
        guard let v = dict[key], !(v is NSNull) else { return nil }
        return v
    }

    func allow(_ keys: Set<String>) throws {
        let unknown = dict.keys.filter { !keys.contains($0) }.sorted()
        guard let first = unknown.first else { return }
        let where_ = path.isEmpty ? "at the top level" : "in \(path)"
        throw WorkspaceDocument.Problem(
            message: "unknown key “\(first)” \(where_) (allowed: \(keys.sorted().joined(separator: ", ")))")
    }

    /// Empty strings read as nil: in every field here, empty means "not set".
    func string(_ key: String) throws -> String? {
        guard let v = present(key) else { return nil }
        guard let s = v as? String else { throw fail(key, "a string or null") }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = present(key) else { return nil }
        // NSNumber bridges both numbers and booleans; only a real JSON boolean is accepted.
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw fail(key, "true, false or null")
        }
        return n.boolValue
    }

    func number(_ key: String, range: ClosedRange<Double>) throws -> Double? {
        guard let v = present(key) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw fail(key, "a number or null") }
        let d = n.doubleValue
        guard range.contains(d) else { throw fail(key, "between \(String(format: "%g", range.lowerBound)) and \(String(format: "%g", range.upperBound))") }
        return d
    }

    func integer(_ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let d = try number(key, range: Double(range.lowerBound)...Double(range.upperBound)) else { return nil }
        guard d == d.rounded() else { throw fail(key, "a whole number or null") }
        return Int(d)
    }

    func object(_ key: String) throws -> Reader? {
        guard let v = present(key) else { return nil }
        return try Reader(v, path: at(key))
    }

    func array(_ key: String) throws -> [Reader]? {
        guard let v = present(key) else { return nil }
        guard let list = v as? [Any] else { throw fail(key, "a list") }
        return try list.enumerated().map { try Reader($1, path: "\(at(key))[\($0)]") }
    }

    /// A list of commands. A single string is accepted too, one command per line.
    func lines(_ key: String) throws -> [String] {
        guard let v = present(key) else { return [] }
        let raw: [String]
        if let s = v as? String {
            raw = s.components(separatedBy: .newlines)
        } else if let list = v as? [Any], list.allSatisfy({ $0 is String }) {
            raw = list as! [String]
        } else {
            throw fail(key, "a list of strings")
        }
        return raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Either the full form, `[{"name": "A", "value": "1"}, {"name": "T", "secret": true}]`, or
    /// the shorthand `{"A": "1"}` for plain variables. Numbers and booleans become their text.
    func variables(_ key: String) throws -> [WorkspaceDocument.Variable] {
        guard let v = present(key) else { return [] }
        if let dict = v as? [String: Any] {
            return try dict.keys.sorted().map { name in
                WorkspaceDocument.Variable(name: name, value: try Self.text(dict[name]!, at: "\(at(key)).\(name)"),
                                           secret: false)
            }
        }
        guard let list = v as? [Any] else { throw fail(key, "a list of variables or an object of NAME: value") }
        return try list.enumerated().map { i, item in
            let r = try Reader(item, path: "\(at(key))[\(i)]")
            try r.allow(["name", "value", "secret"])
            guard let name = try r.string("name") else {
                throw WorkspaceDocument.Problem(message: "\(r.path).name is missing")
            }
            let secret = try r.bool("secret") ?? false
            let value = try r.present("value").map { try Self.text($0, at: "\(r.path).value") }
            return WorkspaceDocument.Variable(name: name, value: secret ? value : (value ?? ""), secret: secret)
        }
    }

    private static func text(_ any: Any, at path: String) throws -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        throw WorkspaceDocument.Problem(message: "\(path) must be a string, number or boolean")
    }
}

/// Just enough JSON to render in a chosen key order, which neither JSONEncoder nor
/// JSONSerialization promises.
private indirect enum JSONValue {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([(String, JSONValue)])

    func rendered(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .string(let s): return Self.quote(s)
        case .number(let d):
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            // Short lists of scalars stay on one line, the way a person would write them.
            if items.allSatisfy(\.isScalar) {
                let line = "[" + items.map { $0.rendered() }.joined(separator: ", ") + "]"
                if line.count + indent.count <= 100 { return line }
            }
            return "[\n" + items.map { inner + $0.rendered(indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            // Small all-scalar objects — an environment variable — read best on one line too.
            if fields.allSatisfy({ $0.1.isScalar }) {
                let line = "{ " + fields.map { Self.quote($0.0) + ": " + $0.1.rendered() }.joined(separator: ", ") + " }"
                if line.count + indent.count <= 100 { return line }
            }
            return "{\n" + fields.map { inner + Self.quote($0.0) + ": " + $0.1.rendered(indent: inner) }
                .joined(separator: ",\n") + "\n\(indent)}"
        }
    }

    var isScalar: Bool {
        switch self {
        case .array, .object: return false
        default: return true
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
