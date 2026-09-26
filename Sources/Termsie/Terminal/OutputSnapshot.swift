import Foundation
import SwiftTerm

/// The tail of a terminal's output, kept when the terminal closes and shown again when it
/// reopens — so closing a terminal, a workspace or Termsie itself does not wipe what was on screen.
///
/// Stored beside the terminal's shell history, keyed the same way, as the text plus the SGR
/// sequences that colour it. Only the last few lines are kept, never the whole scrollback: this is
/// for picking up where you left off, not an archive.
///
/// What is saved is re-encoded from the character buffer rather than recorded from the pty, which
/// is what keeps it small and self-contained: no cursor movement, no alt-screen, no half-drawn
/// progress bars, and soft-wrapped rows are rejoined so the text rewraps at whatever width the
/// terminal reopens with.
enum OutputSnapshot {
    /// Starts the dim rule drawn under restored output.
    static let ruleMarker = "── restored from"
    static func url(for key: String) -> URL {
        PaneStateStore.directory(for: key).appendingPathComponent("output.ansi")
    }

    // MARK: Saving

    /// Writes the last `lines` rows of the terminal's output. 0 deletes anything kept before.
    ///
    /// While a full-screen program (an editor, `less`, `top`) is running, the screen that program
    /// replaced cannot be read, so the previous snapshot is left alone rather than overwritten
    /// with the program's own display.
    static func save(_ terminal: Terminal, key: String, lines: Int, atPrompt: Bool) {
        guard lines > 0 else { discard(key: key); return }
        guard let text = capture(terminal, lines: lines, dropIdlePrompt: atPrompt) else { return }
        guard !text.isEmpty else { discard(key: key); return }
        let dir = PaneStateStore.directory(for: key)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let target = url(for: key)
            try Data(text.utf8).write(to: target, options: .atomic)
            // Terminal output can hold anything that was printed, so only the user may read it.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            NSLog("Termsie: could not save output for \(key): \(error)")
        }
    }

    static func discard(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    /// The saved output, and when it was saved. Nil when there is none.
    static func load(key: String) -> (text: String, saved: Date?)? {
        let target = url(for: key)
        guard let data = try? Data(contentsOf: target), !data.isEmpty else { return nil }
        let saved = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (String(decoding: data, as: UTF8.self), saved)
    }

    /// Everything a reopening terminal feeds itself before its shell starts: the saved output,
    /// then a dim rule saying when it was from, so old output never passes for new.
    static func replay(key: String, now: Date = Date()) -> String? {
        guard let saved = load(key: key) else { return nil }
        var out = saved.text
        out += "\u{1b}[0m\r\n"
        let stamp = saved.saved.map { " " + stampFormatter(for: $0, now: now).string(from: $0) } ?? ""
        out += "\u{1b}[2m\(ruleMarker)\(stamp.isEmpty ? " an earlier session" : stamp) ──\u{1b}[0m\r\n"
        return out
    }

    private static func stampFormatter(for date: Date, now: Date) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = Calendar.current.isDate(date, inSameDayAs: now) ? .none : .medium
        f.timeStyle = .short
        return f
    }

    // MARK: Capturing

    /// The last `lines` buffer rows holding output, re-encoded as text and SGR. Nil while the
    /// alternate screen is up, "" when there is nothing worth keeping.
    ///
    /// `dropIdlePrompt` is for a shell sitting at its prompt. While a command runs, the rows after
    /// the last prompt are that command and its output, and are kept.
    static func capture(_ terminal: Terminal, lines: Int, dropIdlePrompt: Bool = true) -> String? {
        guard !terminal.isCurrentBufferAlternate else { return nil }
        let cap = TerminalTextCapture(terminal)
        let count = cap.rowCount
        guard count > 0, lines > 0 else { return "" }
        var last = cap.lastContentRow()
        guard cap.line(at: last)?.hasAnyContent() == true else { return "" }

        // The prompt the terminal was left sitting at is not output. The reopened shell draws a
        // fresh one, and keeping the old would show two prompts one above the other. Only a
        // prompt the shell itself marked (OSC 133) is dropped, from the first row it drew, so a
        // two-line prompt goes as a whole; without marks nothing is guessed.
        if dropIdlePrompt, let start = cap.promptRows(limit: 1).first, start <= last {
            last = start - 1
            while last >= 0, cap.line(at: last)?.hasAnyContent() != true { last -= 1 }
            guard last >= 0 else { return "" }
        }

        // Nor is a rule from the last restore with nothing printed under it: reopening a terminal
        // to glance at it and closing it again must not stack up rules.
        while last >= 0, let line = cap.line(at: last),
              line.translateToString(trimRight: true).hasPrefix(ruleMarker) {
            last -= 1
            while last >= 0, cap.line(at: last)?.hasAnyContent() != true { last -= 1 }
        }
        guard last >= 0 else { return "" }

        // Start on a real line, not halfway through one that wrapped.
        var first = max(0, last - lines + 1)
        while first < last, cap.line(at: first)?.isWrapped == true { first += 1 }

        var out = ""
        var pen = Pen()
        for row in first...last {
            guard let line = cap.line(at: row) else { continue }
            if row > first, !line.isWrapped {
                // Colours are closed before the line break so a background never bleeds across
                // the rest of the next row.
                if pen.isStyled { out += "\u{1b}[0m"; pen = Pen() }
                out += "\r\n"
            }
            let continues = row < last && cap.line(at: row + 1)?.isWrapped == true
            encode(line, terminal: terminal, keepTrailing: continues, into: &out, pen: &pen)
        }
        if pen.isStyled { out += "\u{1b}[0m" }
        return out
    }

    /// One row. Trailing blanks are dropped unless the row soft-wraps into the next, where they
    /// are part of the text.
    private static func encode(_ line: BufferLine, terminal: Terminal, keepTrailing: Bool,
                               into out: inout String, pen: inout Pen) {
        let width = min(line.count, max(terminal.cols, 1))
        var end = width
        if !keepTrailing {
            while end > 0, isBlank(line[end - 1]) { end -= 1 }
        }
        var col = 0
        while col < end {
            let cell = line[col]
            let next = Pen(cell.attribute)
            if next != pen {
                out += next.sgr
                pen = next
            }
            let ch = terminal.getCharacter(for: cell)
            out.append(ch == "\u{0}" ? " " : ch)
            // A wide character's second cell is a placeholder; writing it again would double it.
            col += max(Int(cell.width), 1)
        }
    }

    private static func isBlank(_ cell: CharData) -> Bool {
        let ch = cell.getCharacter()
        guard ch == " " || ch == "\u{0}" else { return false }
        let a = cell.attribute
        return !a.style.contains(.inverse) && (a.bg == .defaultColor || a.bg == .defaultInvertedColor)
    }

    /// The attributes that survive into the saved text: colours and the common styles. Underline
    /// colour, hyperlinks and semantic marks do not.
    private struct Pen: Equatable {
        var fg: Attribute.Color = .defaultColor
        var bg: Attribute.Color = .defaultInvertedColor
        var style: CharacterStyle = []

        init() {}
        init(_ a: Attribute) {
            fg = a.fg
            bg = a.bg == .defaultColor ? .defaultInvertedColor : a.bg
            style = a.style.intersection([.bold, .dim, .italic, .underline, .blink, .inverse, .invisible, .crossedOut])
        }

        var isStyled: Bool { self != Pen() }

        var sgr: String {
            var codes = ["0"]
            let styles: [(CharacterStyle, String)] = [(.bold, "1"), (.dim, "2"), (.italic, "3"), (.underline, "4"),
                                                      (.blink, "5"), (.inverse, "7"), (.invisible, "8"),
                                                      (.crossedOut, "9")]
            for (s, code) in styles where style.contains(s) { codes.append(code) }
            if let c = Self.color(fg, foreground: true) { codes.append(c) }
            if let c = Self.color(bg, foreground: false) { codes.append(c) }
            return "\u{1b}[" + codes.joined(separator: ";") + "m"
        }

        private static func color(_ c: Attribute.Color, foreground: Bool) -> String? {
            switch c {
            case .ansi256(let code):
                if code < 8 { return String(Int(code) + (foreground ? 30 : 40)) }
                if code < 16 { return String(Int(code) - 8 + (foreground ? 90 : 100)) }
                return (foreground ? "38;5;" : "48;5;") + String(code)
            case .trueColor(let r, let g, let b):
                return (foreground ? "38;2;" : "48;2;") + "\(r);\(g);\(b)"
            case .defaultColor, .defaultInvertedColor:
                return nil
            }
        }
    }
}
