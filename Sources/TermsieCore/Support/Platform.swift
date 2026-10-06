import Foundation

/// The version both front ends report, and the one the release scripts bump.
public enum AppInfo {
    public static let version = "0.8.0"
    public static let name = "Termsie"
}

/// Runs work on the UI thread later.
///
/// macOS drains the main dispatch queue from its run loop, so the default goes through
/// `DispatchQueue.main`. A Win32 message loop does not drain that queue, so the Windows front end
/// installs `hook` at launch and routes the work through its own message loop instead. Shared code
/// schedules through here and never names a queue.
public enum MainScheduler {
    /// Replaces the dispatch-queue default. Called on any thread; must run `work` on the UI thread.
    public static var hook: ((_ delay: Double, _ work: @escaping () -> Void) -> Void)?

    public static func async(_ work: @escaping () -> Void) {
        after(0, work)
    }

    public static func after(_ seconds: Double, _ work: @escaping () -> Void) {
        if let hook {
            hook(max(seconds, 0), work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0), execute: work)
        }
    }
}

/// Home-directory abbreviation and expansion that understands both separators, so a path saved on
/// one platform reads sensibly on the other.
public enum HomePath {
    public static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// `~` for the home directory itself, `~/rest` (or `~\rest` on Windows) below it.
    public static func abbreviate(_ path: String, home: String = HomePath.home) -> String {
        let normalisedHome = trimmingTrailingSeparator(home)
        guard !normalisedHome.isEmpty else { return path }
        if equalPaths(path, normalisedHome) { return "~" }
        for sep in separators {
            let prefix = normalisedHome + sep
            if hasPathPrefix(path, prefix) {
                return "~" + sep + path.dropFirst(prefix.count)
            }
        }
        return path
    }

    /// The inverse of `abbreviate`. Accepts `~/` and `~\` on every platform.
    public static func expand(_ path: String, home: String = HomePath.home) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") || path.hasPrefix("~\\") {
            let rest = String(path.dropFirst(2))
            #if os(Windows)
            return trimmingTrailingSeparator(home) + "\\" + rest.replacingOccurrences(of: "/", with: "\\")
            #else
            return trimmingTrailingSeparator(home) + "/" + rest
            #endif
        }
        return path
    }

    /// The last path component, whichever separator the path uses.
    public static func lastComponent(_ path: String) -> String {
        let trimmed = trimmingTrailingSeparator(path)
        guard let i = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return trimmed }
        return String(trimmed[trimmed.index(after: i)...])
    }

    #if os(Windows)
    private static let separators = ["\\", "/"]
    #else
    private static let separators = ["/"]
    #endif

    private static func trimmingTrailingSeparator(_ p: String) -> String {
        var s = p
        while s.count > 1, let last = s.last, last == "/" || last == "\\" {
            // Keep a drive root such as `C:\` intact.
            if s.count == 3, s.dropFirst().first == ":" { break }
            s.removeLast()
        }
        return s
    }

    /// Windows paths compare case-insensitively; everything else exactly.
    private static func equalPaths(_ a: String, _ b: String) -> Bool {
        #if os(Windows)
        return trimmingTrailingSeparator(a).replacingOccurrences(of: "/", with: "\\").lowercased()
            == b.replacingOccurrences(of: "/", with: "\\").lowercased()
        #else
        return a == b
        #endif
    }

    private static func hasPathPrefix(_ path: String, _ prefix: String) -> Bool {
        #if os(Windows)
        return path.lowercased().hasPrefix(prefix.lowercased())
        #else
        return path.hasPrefix(prefix)
        #endif
    }
}

/// Reads the shape of a value `JSONSerialization` produced without leaning on CoreFoundation,
/// which only Apple platforms expose. On every platform a JSON boolean has to be told apart from
/// the numbers 0 and 1, which bridge to the same `NSNumber` class.
public enum JSONShape {
    public static func isBool(_ value: Any) -> Bool {
        #if canImport(Darwin)
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        // swift-corelibs-foundation parses a JSON boolean into an NSNumber of type `c` (char) and
        // a JSON number into `i`, `q` or `d`, never `c`. `value is Bool` cannot be used: 0 and 1
        // bridge to Bool as well.
        guard let n = value as? NSNumber else { return false }
        return String(cString: n.objCType) == "c"
        #endif
    }

    public static func isNumber(_ value: Any) -> Bool {
        value is NSNumber && !isBool(value)
    }
}

/// Which shell a launch command names, decided from the executable alone.
public enum ShellKind: String {
    case zsh, bash, fish, pwsh, powershell, cmd, wsl, other

    /// `C:\Program Files\PowerShell\7\pwsh.exe` → `.pwsh`, `/bin/zsh` → `.zsh`.
    public static func of(_ executable: String) -> ShellKind {
        var name = HomePath.lastComponent(executable).lowercased()
        if name.hasSuffix(".exe") { name.removeLast(4) }
        if name.hasPrefix("-") { name.removeFirst() }
        switch name {
        case "zsh": return .zsh
        case "bash", "sh": return name == "bash" ? .bash : .other
        case "fish": return .fish
        case "pwsh", "pwsh-preview": return .pwsh
        case "powershell": return .powershell
        case "cmd": return .cmd
        case "wsl", "wsl.exe": return .wsl
        default: return .other
        }
    }

    public var isPowerShell: Bool { self == .pwsh || self == .powershell }

    /// The name a terminal shows for this shell when nothing better is known.
    public static func displayName(_ executable: String) -> String {
        var name = HomePath.lastComponent(executable)
        if name.lowercased().hasSuffix(".exe") { name.removeLast(4) }
        return name
    }
}

#if os(Windows)
/// Finds the shell a Windows terminal opens when the config names none: PowerShell 7 when it is
/// installed, Windows PowerShell otherwise, and cmd as the last resort.
public enum ShellLocator {
    private static var cached: String?

    public static func defaultWindowsShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let cached { return cached }
        let found = locate(environment: environment)
        cached = found
        return found
    }

    public static func locate(environment: [String: String]) -> String {
        if let pwsh = searchPath("pwsh.exe", environment: environment) { return pwsh }
        let fm = FileManager.default
        let programFiles = environment["ProgramFiles"] ?? "C:\\Program Files"
        for candidate in ["\(programFiles)\\PowerShell\\7\\pwsh.exe", "\(programFiles)\\PowerShell\\7-preview\\pwsh.exe"]
        where fm.fileExists(atPath: candidate) {
            return candidate
        }
        let system = (environment["SystemRoot"] ?? environment["SYSTEMROOT"] ?? "C:\\Windows") + "\\System32"
        let windowsPowerShell = system + "\\WindowsPowerShell\\v1.0\\powershell.exe"
        if fm.fileExists(atPath: windowsPowerShell) { return windowsPowerShell }
        return environment["ComSpec"] ?? environment["COMSPEC"] ?? (system + "\\cmd.exe")
    }

    /// The first directory on PATH holding `name`.
    public static func searchPath(_ name: String, environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? environment["Path"] ?? ""
        for dir in path.split(separator: ";") where !dir.isEmpty {
            let candidate = dir.hasSuffix("\\") ? "\(dir)\(name)" : "\(dir)\\\(name)"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}
#endif

/// Keeps terminal state (history, kept output) readable by its owner only. On Windows the
/// per-user profile folders are already private to the user, and POSIX permission bits have no
/// meaning, so there is nothing further to do.
public enum FilePrivacy {
    public static func createPrivateDirectory(at url: URL) throws {
        #if os(Windows)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #endif
    }

    public static func restrictToOwner(_ url: URL) {
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }
}
