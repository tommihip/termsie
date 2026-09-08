import Darwin
import Foundation

/// Reads process facts straight from the kernel so the UI can show what each pane is doing
/// without requiring any shell integration.
enum ProcessInspector {
    /// Current working directory of `pid`.
    static func currentDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let got = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        guard got == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Process group currently in the foreground of the terminal whose master fd is `ptyFd`.
    static func foregroundProcessGroup(ptyFd: Int32) -> pid_t? {
        guard ptyFd >= 0 else { return nil }
        let pgid = tcgetpgrp(ptyFd)
        return pgid > 0 ? pgid : nil
    }

    /// Short executable name for `pid` (e.g. "node", "zsh").
    static func name(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension ProcessInspector {
    /// argv of `pid` via `KERN_PROCARGS2` (works for the user's own processes).
    static func arguments(of pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args.isEmpty ? nil : args
    }

    /// A shell-friendly command line for the foreground job of `pid`'s terminal, or nil when idle.
    static func commandLine(of pid: pid_t) -> String? {
        guard var args = arguments(of: pid), !args.isEmpty else { return nil }
        // "node /opt/homebrew/bin/npm run dev" → "npm run dev"
        let interpreters: Set<String> = ["node", "python", "python3", "ruby", "perl", "bun", "deno"]
        let first = (args[0] as NSString).lastPathComponent
        if interpreters.contains(first), args.count > 1, !args[1].hasPrefix("-") {
            args.removeFirst()
            args[0] = (args[0] as NSString).lastPathComponent
        } else {
            args[0] = first
        }
        return args.map { arg -> String in
            if arg.isEmpty { return "''" }
            let safe = arg.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_./=:@,+%".unicodeScalars.contains($0) }
            return safe ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
