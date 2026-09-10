import Foundation

/// Owns the per-terminal state directory that doubles as a zsh `ZDOTDIR`.
enum PaneStateStore {
    static func directory(for key: String) -> URL {
        ConfigStore.shared.panesDir.appendingPathComponent(sanitize(key), isDirectory: true)
    }

    static func historyFile(for key: String) -> URL {
        directory(for: key).appendingPathComponent(".zsh_history")
    }

    static func sanitize(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "default" : String(cleaned.prefix(64))
    }

    /// Creates the directory and writes the shim files if they are absent or stale.
    /// The version stamp is written last, so a half-written shim is never treated as usable.
    @discardableResult
    static func ensure(key: String) throws -> URL {
        let dir = directory(for: key)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let stamp = dir.appendingPathComponent(".shim-version")
        if let existing = try? String(contentsOf: stamp, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines) == ShimScripts.version {
            return dir
        }
        for (name, body) in ShimScripts.files {
            let url = dir.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try ShimScripts.version.write(to: stamp, atomically: true, encoding: .utf8)
        return dir
    }

    /// Deletes state directories for terminals that no longer exist.
    /// Skips anything touched in the last hour so a second running instance is never disturbed.
    static func prune(keeping liveKeys: Set<String>, retentionDays: Int) {
        let fm = FileManager.default
        let root = ConfigStore.shared.panesDir
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let keep = Set(liveKeys.map(sanitize))
        let cutoff = Date().addingTimeInterval(-Double(max(retentionDays, 1)) * 86_400)
        let safety = Date().addingTimeInterval(-3600)
        for entry in entries {
            let name = entry.lastPathComponent
            if keep.contains(name) { continue }
            let modified = newestModification(in: entry, fm: fm) ?? .distantPast
            guard modified < cutoff, modified < safety else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    private static func newestModification(in dir: URL, fm: FileManager) -> Date? {
        var newest: Date?
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in urls + [dir] {
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if newest == nil || d > newest! { newest = d }
            }
        }
        return newest
    }
}

/// Decides what shell integration a terminal gets and produces the environment to launch it with.
///
/// The governing rule: any uncertainty resolves to doing nothing. A terminal with shared history
/// is a missing feature; a terminal whose PATH lost half its entries is a broken app.
enum ShellIntegration {
    enum Mode: String { case disabled, zsh, bash, fish, histfileOnly }

    struct Plan {
        var environment: [String: String] = [:]
        var shellArgs: [String] = []
        /// True when the shell itself will run the startup commands, so the typed path stays off.
        var runsStartupCommands = false
        var mode: Mode = .disabled

        static let disabled = Plan()
    }

    /// Shell flags that mean "no rc files" or "not interactive". Shimming those would do nothing
    /// useful and could surprise a user who set them deliberately.
    private static let disqualifyingArgs: Set<String> = ["-f", "--no-rcs", "-d", "--no-globalrcs", "-c", "-s", "--norc", "--noprofile"]

    static func prepare(shell: String,
                        shellArgs: [String],
                        paneKey: String,
                        commands: [String],
                        isolateHistory: Bool,
                        config: TermsieConfig,
                        inheritedEnv: [String: String]) -> Plan {
        var plan = Plan()
        plan.shellArgs = shellArgs

        guard config.shellIntegration.lowercased() != "off" else { return plan }
        guard !shellArgs.contains(where: { disqualifyingArgs.contains($0) }) else { return plan }

        let name = (shell as NSString).lastPathComponent
        let wantsHistory = isolateHistory && config.history.isolate
        let wantsCommands = !commands.isEmpty && config.startupCommands.mode.lowercased() == "shim"
        // Marks alone are reason enough to shim: they are what the copy tools read, and a
        // terminal with history isolation turned off still wants working copy buttons.
        let wantsMarks = config.copy.commandMarks
        guard wantsHistory || wantsCommands || wantsMarks else { return plan }

        switch name {
        case "zsh":
            return zshPlan(paneKey: paneKey, commands: commands, wantsHistory: wantsHistory,
                           wantsCommands: wantsCommands, wantsMarks: wantsMarks, config: config,
                           inheritedEnv: inheritedEnv, base: plan)
        case "bash":
            return bashPlan(paneKey: paneKey, commands: commands, wantsHistory: wantsHistory,
                            wantsCommands: wantsCommands, wantsMarks: wantsMarks, config: config,
                            inheritedEnv: inheritedEnv, base: plan)
        case "fish":
            return fishPlan(paneKey: paneKey, commands: commands, wantsHistory: wantsHistory,
                            wantsCommands: wantsCommands, base: plan)
        default:
            guard wantsHistory, config.history.exportHistfileForUnknownShells else { return plan }
            var p = plan
            p.mode = .histfileOnly
            p.environment["HISTFILE"] = historyPath(paneKey)
            return p
        }
    }

    // MARK: zsh

    private static func zshPlan(paneKey: String, commands: [String], wantsHistory: Bool,
                                wantsCommands: Bool, wantsMarks: Bool, config: TermsieConfig,
                                inheritedEnv: [String: String], base: Plan) -> Plan {
        var plan = base
        let dir: URL
        do {
            dir = try PaneStateStore.ensure(key: paneKey)
        } catch {
            NSLog("Termsie: shell integration unavailable (\(error)); terminal starts unmodified")
            return base
        }
        plan.mode = .zsh
        plan.environment["ZDOTDIR"] = dir.path
        plan.environment["TERMSIE_SHIM"] = "1"
        // Preserve an existing ZDOTDIR so the shim can source the user's real files and hand it
        // back. An empty-but-set value is meaningful, so only skip a value that is already ours.
        if let original = inheritedEnv["ZDOTDIR"],
           !original.hasPrefix(ConfigStore.shared.panesDir.path) {
            plan.environment["TERMSIE_ORIG_ZDOTDIR"] = original
        }
        if wantsHistory {
            plan.environment["TERMSIE_HISTFILE"] = historyPath(paneKey)
            plan.environment["TERMSIE_HISTORY_RESPECT_SHARE"] = config.history.respectShareHistory ? "1" : "0"
            plan.environment["TERMSIE_HISTORY_MERGE"] = config.history.mergeToGlobalOnExit ? "1" : "0"
            if let size = config.history.size { plan.environment["TERMSIE_HISTSIZE"] = String(size) }
            if let save = config.history.saveSize { plan.environment["TERMSIE_SAVEHIST"] = String(save) }
        }
        if wantsMarks { plan.environment["TERMSIE_MARKS"] = "1" }
        if wantsCommands {
            plan.environment["TERMSIE_STARTUP_COUNT"] = String(commands.count)
            for (i, cmd) in commands.enumerated() {
                plan.environment["TERMSIE_STARTUP_\(i + 1)"] = cmd
            }
            plan.environment["TERMSIE_STARTUP_ECHO"] = config.startupCommands.echo ? "1" : "0"
            plan.environment["TERMSIE_STARTUP_RECORD"] = config.startupCommands.recordInHistory ? "1" : "0"
            plan.runsStartupCommands = true
        }
        return plan
    }

    // MARK: bash

    private static func bashPlan(paneKey: String, commands: [String], wantsHistory: Bool,
                                 wantsCommands: Bool, wantsMarks: Bool, config: TermsieConfig,
                                 inheritedEnv: [String: String], base: Plan) -> Plan {
        var plan = base
        plan.mode = .bash
        guard (try? PaneStateStore.ensure(key: paneKey)) != nil else { return base }
        var hooks: [String] = []
        if wantsHistory {
            // Bash reads HISTFILE at startup, so this alone is enough unless the user's rc
            // reassigns it. The prompt hook covers that case.
            plan.environment["HISTFILE"] = historyPath(paneKey, name: ".bash_history")
            plan.environment["TERMSIE_HISTFILE"] = historyPath(paneKey, name: ".bash_history")
            hooks.append("""
            if [ -z "$__TERMSIE_PINNED" ]; then __TERMSIE_PINNED=1; HISTFILE="$TERMSIE_HISTFILE"; history -c; history -r; shopt -s histappend; fi; history -a
            """)
        }
        if wantsCommands {
            // Inline, never an exported function: exported bash functions are the Shellshock
            // mechanism and behave differently across versions.
            let encoded = commands.map { $0.replacingOccurrences(of: "'", with: "'\\''") }
                .map { "eval '\($0)'" }.joined(separator: "; ")
            hooks.append("if [ -z \"$__TERMSIE_RAN\" ]; then __TERMSIE_RAN=1; \(encoded); fi")
            plan.runsStartupCommands = true
        }
        if wantsMarks {
            // A prompt start before every prompt, and the input mark appended to PS1 once.
            //
            // Deliberately no C or D: bash has no preexec, so the only way to emit them is a
            // DEBUG trap, which would silently replace whatever the user has on it. Leaving them
            // out is also what tells Termsie this shell says nothing about commands starting and
            // ending, so it watches the pty's foreground process instead of guessing from marks.
            hooks.append(#"printf '\033]133;A\007'; case "$PS1" in *'133;B'*) ;; *) PS1="$PS1\[\e]133;B\a\]" ;; esac"#)
        }
        guard !hooks.isEmpty else { return base }
        var prompt = hooks.joined(separator: "; ")
        if let existing = inheritedEnv["PROMPT_COMMAND"], !existing.isEmpty {
            prompt += "; " + existing
        }
        plan.environment["PROMPT_COMMAND"] = prompt
        if inheritedEnv["HISTCONTROL"] == nil { plan.environment["HISTCONTROL"] = "ignorespace" }
        return plan
    }

    // MARK: fish

    private static func fishPlan(paneKey: String, commands: [String], wantsHistory: Bool,
                                 wantsCommands: Bool, base: Plan) -> Plan {
        var plan = base
        plan.mode = .fish
        if wantsHistory {
            plan.environment["fish_history"] = "termsie_" + PaneStateStore.sanitize(paneKey)
        }
        if wantsCommands {
            // --init-command runs after config.fish, before the first prompt, and is not recorded.
            for cmd in commands { plan.shellArgs.append(contentsOf: ["--init-command", cmd]) }
            plan.runsStartupCommands = true
        }
        return plan
    }

    private static func historyPath(_ key: String, name: String = ".zsh_history") -> String {
        PaneStateStore.directory(for: key).appendingPathComponent(name).path
    }
}
