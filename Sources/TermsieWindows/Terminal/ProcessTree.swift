import Foundation
import WinSDK
import CTermsieWin
import TermsieCore

/// What each terminal is running, read from the process list.
///
/// Windows has no foreground process group for a console, so "the job in front" is taken to be
/// the newest process below the shell: a console hands its keyboard to whatever the shell
/// started last and is waiting on. Console hosts are skipped; they are plumbing, not programs.
struct ProcessSnapshot {
    struct Entry {
        let pid: DWORD
        let parent: DWORD
        let name: String
    }

    let entries: [Entry]
    private let children: [DWORD: [Int]]

    init() {
        var buffer = [TWProcessInfo](repeating: TWProcessInfo(), count: 4096)
        let count = Int(tw_list_processes(&buffer, Int32(buffer.count)))
        var list: [Entry] = []
        list.reserveCapacity(count)
        for i in 0..<count {
            var info = buffer[i]
            let name = withUnsafeBytes(of: &info.name) { raw -> String in
                let units = raw.bindMemory(to: WCHAR.self)
                let n = units.firstIndex(of: 0) ?? units.count
                return String(decoding: units.prefix(n), as: UTF16.self)
            }
            list.append(Entry(pid: info.pid, parent: info.parentPid, name: name))
        }
        entries = list
        var map: [DWORD: [Int]] = [:]
        for (i, e) in list.enumerated() where e.pid != e.parent {
            map[e.parent, default: []].append(i)
        }
        children = map
    }

    private static let plumbing: Set<String> = ["conhost.exe", "openconsole.exe"]

    /// The program the user is running in the terminal whose shell is `shell`, or nil when the
    /// shell itself is in front.
    func foreground(below shell: DWORD) -> Entry? {
        guard shell != 0 else { return nil }
        // Walk down, always into the newest real child: the chain of programs each waiting on
        // the one it started.
        var current = shell
        var found: Entry?
        var guardCount = 0
        while let kids = children[current], guardCount < 64 {
            guardCount += 1
            let real = kids.map { entries[$0] }.filter { !ProcessSnapshot.plumbing.contains($0.name.lowercased()) }
            guard let newest = real.last else { break }
            found = newest
            current = newest.pid
        }
        return found
    }

    func name(of pid: DWORD) -> String? {
        entries.first { $0.pid == pid }?.name
    }
}

enum ProcessInfoReader {
    /// The command line of a program, shortened the way the macOS app shows one: the executable's
    /// name without its folder, and `node C:\...\npm-cli.js run dev` as `npm run dev`.
    static func commandLine(of pid: DWORD) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let n = Int(tw_process_command_line(pid, &buffer, Int32(buffer.count)))
        guard n > 0 else { return nil }
        let raw = String(decoding: buffer.prefix(n), as: UTF16.self)
        var args = splitCommandLine(raw)
        guard !args.isEmpty else { return nil }
        var first = HomePath.lastComponent(args[0])
        if first.lowercased().hasSuffix(".exe") { first.removeLast(4) }
        let interpreters: Set<String> = ["node", "python", "python3", "ruby", "perl", "bun", "deno"]
        if interpreters.contains(first.lowercased()), args.count > 1, !args[1].hasPrefix("-") {
            args.removeFirst()
            var script = HomePath.lastComponent(args[0])
            for suffix in ["-cli.js", ".js", ".py", ".cmd"] where script.lowercased().hasSuffix(suffix) {
                script.removeLast(suffix.count)
            }
            args[0] = script
        } else {
            args[0] = first
        }
        return args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// CommandLineToArgvW's rules: whitespace separates, quotes group, backslashes escape a quote.
    static func splitCommandLine(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var hasArg = false
        var backslashes = 0
        for ch in s {
            if ch == "\\" {
                backslashes += 1
                continue
            }
            if ch == "\"" {
                current += String(repeating: "\\", count: backslashes / 2)
                if backslashes % 2 == 1 {
                    current.append("\"")
                } else {
                    inQuotes.toggle()
                }
                backslashes = 0
                hasArg = true
                continue
            }
            current += String(repeating: "\\", count: backslashes)
            backslashes = 0
            if (ch == " " || ch == "\t") && !inQuotes {
                if hasArg || !current.isEmpty { args.append(current) }
                current = ""
                hasArg = false
            } else {
                current.append(ch)
                hasArg = true
            }
        }
        current += String(repeating: "\\", count: backslashes)
        if hasArg || !current.isEmpty { args.append(current) }
        return args
    }
}
