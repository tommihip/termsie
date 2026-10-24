import Foundation
import Darwin

/// Turns an `SSHConnection` into the `ssh` process a terminal runs.
///
/// The system `ssh` is used rather than an SSH library so the user's `~/.ssh/config`, agent,
/// `known_hosts`, ProxyJump and hardware keys all behave exactly as they do in any terminal.
///
/// Stored credentials are answered through `SSH_ASKPASS`, pointed at Termsie's own executable
/// (see `SSHAskpass`). The value goes from the Keychain straight to `ssh` over a pipe: never
/// through the screen, a file, the shell history or an argument.
enum SSHLaunch {
    static let executable = "/usr/bin/ssh"

    struct Plan {
        var executable = SSHLaunch.executable
        var args: [String] = []
        var environment: [String: String] = [:]
        /// A private folder holding a stored key and the askpass bookkeeping while connected.
        /// Removed when the session ends.
        var privateDirectory: URL?
    }

    enum Failure: Error { case invalid(String) }

    /// - Parameters:
    ///   - commands: run on the server, in order, before its interactive shell.
    ///   - remoteDirectory: where on the server the shell starts, tilde allowed.
    ///   - secretsFile: the scripted-test secrets file, passed on to the askpass helper.
    static func prepare(_ connection: SSHConnection, commands: [String], remoteDirectory: String?,
                        secretsFile: String? = nil) -> Result<Plan, Failure> {
        if let problem = connection.problem { return .failure(.invalid(problem)) }
        var plan = Plan()
        var args: [String] = []
        if let port = connection.port { args += ["-p", String(port)] }
        if let user = connection.user, !user.isEmpty { args += ["-l", user] }

        let needsPrivateDirectory = connection.identity == .storedKey
            || connection.passwordRef != nil || connection.passphraseRef != nil
        if needsPrivateDirectory {
            guard let dir = makePrivateDirectory() else {
                return .failure(.invalid("could not create a private folder for the connection"))
            }
            plan.privateDirectory = dir
        }

        switch connection.identity {
        case .automatic:
            break
        case .keyFile:
            let path = ((connection.identityFile ?? "") as NSString).expandingTildeInPath
            args += ["-i", path, "-o", "IdentitiesOnly=yes"]
        case .storedKey:
            guard let ref = connection.privateKeyRef, let key = SecretStore.value(for: ref),
                  let dir = plan.privateDirectory else {
                removePrivateDirectory(plan.privateDirectory)
                return .failure(.invalid("the stored private key was not found in the Keychain"))
            }
            let file = dir.appendingPathComponent("id")
            guard writePrivateKey(key, to: file) else {
                removePrivateDirectory(plan.privateDirectory)
                return .failure(.invalid("could not write the stored private key"))
            }
            args += ["-i", file.path, "-o", "IdentitiesOnly=yes"]
        }

        for option in connection.options where !option.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-o", option.trimmingCharacters(in: .whitespaces)]
        }

        if connection.passwordRef != nil || connection.passphraseRef != nil, let dir = plan.privateDirectory {
            plan.environment["SSH_ASKPASS"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
            plan.environment["SSH_ASKPASS_REQUIRE"] = "force"
            plan.environment[SSHAskpass.modeKey] = "1"
            plan.environment[SSHAskpass.stateKey] = dir.appendingPathComponent("askpass-used").path
            if let ref = connection.passwordRef { plan.environment[SSHAskpass.passwordKey] = ref }
            if let ref = connection.passphraseRef { plan.environment[SSHAskpass.passphraseKey] = ref }
            if let secretsFile {
                plan.environment[SSHAskpass.testKey] = "1"
                plan.environment["TERMSIE_SECRETS_FILE"] = secretsFile
            }
        }

        let remote = remoteCommand(commands: commands, directory: remoteDirectory)
        // A command on the line means no tty unless asked for, and the session is interactive.
        if remote != nil { args.append("-t") }
        args.append(connection.host.trimmingCharacters(in: .whitespaces))
        if let remote { args.append(remote) }
        plan.args = args
        return .success(plan)
    }

    /// What the server runs instead of a bare login shell, or nil when there is nothing to do.
    ///
    /// The server hands this line to the user's login shell, which may be fish or anything
    /// else, so the real script runs under `sh`. Commands are chained with `&&`, so one that
    /// fails or is interrupted with Ctrl-C stops the rest, as the local shim does; the INT trap
    /// keeps that Ctrl-C from ending the connection, and the login shell always follows.
    static func remoteCommand(commands: [String], directory: String?) -> String? {
        var steps: [String] = []
        if let dir = directory?.trimmingCharacters(in: .whitespaces), !dir.isEmpty {
            let target: String
            if dir == "~" {
                target = "\"$HOME\""
            } else if dir.hasPrefix("~/") {
                target = "\"$HOME\"/" + shellQuote(String(dir.dropFirst(2)))
            } else {
                target = shellQuote(dir)
            }
            steps.append("cd -- \(target) || printf '\\033[33m[remote folder %s not found]\\033[0m\\n' \(shellQuote(dir))")
        }
        let runnable = commands.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !runnable.isEmpty {
            steps.append("trap : INT; { " + runnable.joined(separator: " && ") + "; }; trap - INT")
        }
        guard !steps.isEmpty else { return nil }
        let script = steps.joined(separator: "; ") + "; exec \"${SHELL:-/bin/sh}\" -l"
        return "exec /bin/sh -c " + shellQuote(script)
    }

    /// Single-quotes a string for a POSIX shell.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Private folder

    /// Root of every session's private folder, in the per-user temporary directory.
    static var privateRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("termsie-ssh", isDirectory: true)
    }

    /// A fresh folder only this user can enter, named by the app's pid so a later launch can
    /// tell which ones were left behind.
    private static func makePrivateDirectory() -> URL? {
        let fm = FileManager.default
        let root = privateRoot
        let dir = root.appendingPathComponent("\(getpid())-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try fm.createDirectory(at: dir, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            return dir
        } catch {
            NSLog("Termsie: could not create \(dir.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes a key readable by this user only, in the form `ssh` insists on: Unix line endings
    /// and a final newline.
    private static func writePrivateKey(_ key: String, to url: URL) -> Bool {
        var text = key.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    static func removePrivateDirectory(_ dir: URL?) {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Removes folders whose app is no longer running — left behind by a crash or a kill.
    static func sweepAbandonedDirectories() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: privateRoot.path)) ?? [] {
            guard let pid = Int32(name.split(separator: "-").first ?? "") else { continue }
            if pid == getpid() { continue }
            if kill(pid, 0) == 0 || errno == EPERM { continue }
            try? fm.removeItem(at: privateRoot.appendingPathComponent(name))
        }
    }
}

/// Termsie's executable acting as `ssh`'s `SSH_ASKPASS` helper.
///
/// `ssh` runs it with the prompt as the only argument and reads the answer from its stdout.
/// A stored password or passphrase is answered once; a second request of the same kind means
/// the stored one was wrong, so that one, and any prompt Termsie has nothing stored for (a new
/// host key, say), is asked on the terminal itself, just as `ssh` would have.
enum SSHAskpass {
    static let modeKey = "TERMSIE_ASKPASS"
    static let passwordKey = "TERMSIE_ASKPASS_PASSWORD"
    static let passphraseKey = "TERMSIE_ASKPASS_PASSPHRASE"
    static let stateKey = "TERMSIE_ASKPASS_STATE"
    static let testKey = "TERMSIE_ASKPASS_TEST"

    static var isRequested: Bool { ProcessInfo.processInfo.environment[modeKey] == "1" }
    /// A scripted test run, allowed to read secrets from `TERMSIE_SECRETS_FILE`.
    static var isTestRun: Bool { isRequested && ProcessInfo.processInfo.environment[testKey] == "1" }

    enum Kind: String { case password, passphrase, other }

    static func kind(of prompt: String) -> Kind {
        let p = prompt.lowercased()
        if p.contains("yes/no") { return .other }
        if p.contains("passphrase") { return .passphrase }
        if p.contains("password") { return .password }
        return .other
    }

    /// Runs the helper and returns its exit status.
    static func run() -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        // "none" is ssh telling the user something (touch your security key) with no answer.
        if env["SSH_ASKPASS_PROMPT"] == "none" {
            _ = writeToTTY(prompt + "\n")
            return 0
        }
        let kind = kind(of: prompt)
        let ref: String? = switch kind {
        case .password: env[passwordKey]
        case .passphrase: env[passphraseKey]
        case .other: nil
        }
        if let ref, let statePath = env[stateKey], claimFirstUse(of: kind, statePath: statePath),
           let value = SecretStore.value(for: ref) {
            print(value)
            return 0
        }
        // Nothing stored, or it was already tried: ask the person at the terminal.
        let echo = kind == .other
        guard let answer = askOnTTY(prompt, echo: echo) else { return 1 }
        print(answer)
        return 0
    }

    /// True the first time a kind of prompt is answered from the Keychain in this session.
    private static func claimFirstUse(of kind: Kind, statePath: String) -> Bool {
        let marker = statePath + "-" + kind.rawValue
        let fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    private static func writeToTTY(_ text: String) -> Bool {
        let fd = open("/dev/tty", O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count
    }

    /// Prompts on the controlling terminal and reads one line, with echo off for secrets.
    private static func askOnTTY(_ prompt: String, echo: Bool) -> String? {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var saved = termios()
        let haveTermios = tcgetattr(fd, &saved) == 0
        if haveTermios, !echo {
            var quiet = saved
            quiet.c_lflag &= ~tcflag_t(ECHO)
            quiet.c_lflag |= tcflag_t(ECHONL)
            tcsetattr(fd, TCSAFLUSH, &quiet)
        }
        defer { if haveTermios { tcsetattr(fd, TCSAFLUSH, &saved) } }
        let promptBytes = Array(prompt.utf8)
        _ = promptBytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var line: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }
            if byte == 0x0a || byte == 0x0d { break }
            line.append(byte)
            if line.count > 8192 { return nil }
        }
        return String(decoding: line, as: UTF8.self)
    }
}
