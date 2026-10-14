import Foundation
import WinSDK
import CTermsieHost
import TermsieCore

/// What each terminal is running, read from the process list.
///
/// Windows has no foreground process group for a console, so "the job in front" is taken to be
/// the newest process below the shell: a console hands its keyboard to whatever the shell
/// started last and is waiting on. Console hosts are skipped; they are plumbing, not programs.
struct ProcessSnapshot {
    struct Entry {
        let pid: Int
        let parent: Int
        let name: String
    }

    let entries: [Entry]
    private let children: [Int: [Int]]

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
            list.append(Entry(pid: Int(info.pid), parent: Int(info.parentPid), name: name))
        }
        entries = list
        var map: [Int: [Int]] = [:]
        for (i, e) in list.enumerated() where e.pid != e.parent {
            map[e.parent, default: []].append(i)
        }
        children = map
    }

    private static let plumbing: Set<String> = ["conhost.exe", "openconsole.exe"]

    /// The program the user is running in the terminal whose shell is `shell`, or nil when the
    /// shell itself is in front.
    func foreground(below shell: Int, ptyFd: Int32) -> Entry? {
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

    /// Windows shells report their folder through OSC 7; nothing is read from the kernel.
    func currentDirectory(of pid: Int) -> String? { nil }

    func name(of pid: Int) -> String? {
        entries.first { $0.pid == pid }?.name
    }
}

enum ProcessInfoReader {
    /// The command line of a program, shortened the way the macOS app shows one: the executable's
    /// name without its folder, and `node C:\...\npm-cli.js run dev` as `npm run dev`.
    static func commandLine(of pid: Int) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let n = Int(tw_process_command_line(DWORD(pid), &buffer, Int32(buffer.count)))
        guard n > 0 else { return nil }
        let raw = String(decoding: buffer.prefix(n), as: UTF16.self)
        var args = CommandLineText.split(raw)
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
}
