import Foundation
import Glibc
import TermsieCore

/// What each terminal is running, read from the kernel: the pty's foreground process group is
/// the job in front, and /proc says what it is.
struct ProcessSnapshot {
    struct Entry {
        let pid: Int
        let name: String
    }

    init() {}

    /// The program the user is running in the terminal whose shell is `shell`, or nil when the
    /// shell itself is in front.
    func foreground(below shell: Int, ptyFd: Int32) -> Entry? {
        guard shell > 0, ptyFd >= 0 else { return nil }
        let pgid = tcgetpgrp(ptyFd)
        guard pgid > 0, Int(pgid) != shell, let name = ProcessInfoReader.name(of: Int(pgid)) else { return nil }
        return Entry(pid: Int(pgid), name: name)
    }

    /// The shell's working directory, for shells that do not report it themselves.
    func currentDirectory(of pid: Int) -> String? {
        ProcessInfoReader.currentDirectory(of: pid)
    }
}

enum ProcessInfoReader {
    /// Short executable name for `pid` (e.g. "node", "zsh").
    static func name(of pid: Int) -> String? {
        guard pid > 0, let comm = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else { return nil }
        let name = comm.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func currentDirectory(of pid: Int) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4097)
        let n = readlink("/proc/\(pid)/cwd", &buffer, buffer.count - 1)
        guard n > 0 else { return nil }
        buffer[Int(n)] = 0
        return String(cString: buffer)
    }

    static func arguments(of pid: Int) -> [String]? {
        guard pid > 0, let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !data.isEmpty else { return nil }
        let args = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        let trimmed = args.last == "" ? Array(args.dropLast()) : args
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A shell-friendly command line for a program, shortened the way the macOS app shows one:
    /// the executable's name without its folder, and `node /usr/lib/node_modules/npm/bin/npm-cli.js
    /// run dev` as `npm run dev`.
    static func commandLine(of pid: Int) -> String? {
        guard var args = arguments(of: pid), !args.isEmpty else { return nil }
        let interpreters: Set<String> = ["node", "python", "python3", "ruby", "perl", "bun", "deno"]
        let first = HomePath.lastComponent(args[0])
        if interpreters.contains(first), args.count > 1, !args[1].hasPrefix("-") {
            args.removeFirst()
            var script = HomePath.lastComponent(args[0])
            for suffix in ["-cli.js", ".js", ".py"] where script.hasSuffix(suffix) {
                script.removeLast(suffix.count)
            }
            args[0] = script
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
