import Foundation
import SwiftTerm

/// Pulls copyable text out of a terminal's character buffer: one command and its output, the
/// command line on its own, or everything the terminal is still holding.
///
/// Two coordinate systems are in play and mixing them is the easy mistake. *Buffer rows* run
/// `0 ..< rowCount` with the scrollback first, and are what `getText` and the semantic marks take.
/// *Invariant rows* are those plus `totalLinesTrimmed`, so they keep naming the same text after
/// the scrollback has trimmed; only anchors that outlive a call are stored that way.
struct TerminalTextCapture {
    let terminal: Terminal

    init(_ terminal: Terminal) {
        self.terminal = terminal
    }

    /// How many rows the buffer holds, scrollback included.
    ///
    /// SwiftTerm keeps `buffer.lines` internal and `getScrollInvariantLine` is the only public
    /// window onto it — it answers nil past the end. So double until that happens and then bisect,
    /// which costs a couple of dozen bounds checks rather than a walk over the scrollback.
    var rowCount: Int {
        let top = terminal.buffer.totalLinesTrimmed
        guard terminal.getScrollInvariantLine(row: top) != nil else { return 0 }
        var known = 1
        var beyond = 2
        // The ceiling is the emulator's own cap; without one a buffer that answered every probe
        // would spin here forever.
        let ceiling = max(terminal.rows, 1) + max(ConfigStore.shared.config.scrollback, 0) + 2
        while beyond <= ceiling, terminal.getScrollInvariantLine(row: top + beyond - 1) != nil {
            known = beyond
            beyond *= 2
        }
        beyond = min(beyond, ceiling + 1)
        while known + 1 < beyond {
            let mid = (known + beyond) / 2
            if terminal.getScrollInvariantLine(row: top + mid - 1) != nil { known = mid } else { beyond = mid }
        }
        return known
    }

    func line(at row: Int) -> BufferLine? {
        terminal.getScrollInvariantLine(row: terminal.buffer.totalLinesTrimmed + row)
    }

    /// The buffer row of the top of the visible screen, which is where a `clear` leaves the
    /// content that follows it.
    var screenTopRow: Int {
        max(0, rowCount - terminal.rows)
    }

    /// The last row holding anything, so a copy stops at the content rather than running on
    /// through the blank remainder of the screen.
    func lastContentRow(notBefore floor: Int = 0) -> Int {
        var row = rowCount - 1
        while row > floor {
            if line(at: row)?.hasAnyContent() == true { return row }
            row -= 1
        }
        return max(floor, 0)
    }

    /// Buffer rows carrying an OSC 133 prompt mark, newest first, found by walking back from the
    /// bottom. Stops at `limit` marks so a full scrollback is never scanned for the common case of
    /// wanting the last one or two.
    func promptRows(limit: Int) -> [Int] {
        var found: [Int] = []
        var row = rowCount - 1
        while row >= 0, found.count < limit {
            if terminal.semanticPromptMarks(at: row).contains(where: { $0.kind == .initial || $0.kind == .secondary }) {
                found.append(row)
            }
            row -= 1
        }
        return found
    }

    /// The text of a row range, with wrapped rows rejoined into the single line they came from.
    func text(rows: ClosedRange<Int>) -> String {
        let last = min(rows.upperBound, rowCount - 1)
        guard rows.lowerBound >= 0, last >= rows.lowerBound else { return "" }
        return terminal.getText(start: Position(col: 0, row: rows.lowerBound),
                                end: Position(col: terminal.cols, row: last))
    }

    /// The command typed at a prompt, taken from the cells the shell tagged as input.
    ///
    /// Reading the tags rather than the row text is what keeps the prompt out of the result
    /// without having to guess how wide it was. Only the run that starts at the first input cell
    /// on each row is taken, so a right-hand prompt redrawn while the line was being edited does
    /// not get swept up with it.
    ///
    /// Returns nil when the tags cannot be describing input, which is the caller's cue to guess
    /// instead. The giveaway is a run that starts at column zero of the prompt's own row: a line
    /// editor that repaints the whole line writes the prompt again *after* the shell said input
    /// had begun, and the prompt ends up tagged as part of the command. Readline does this; ZLE
    /// does not.
    func inputText(rows: ClosedRange<Int>) -> String? {
        var pieces: [String] = []
        var sawInput = false
        for row in rows.lowerBound...min(rows.upperBound, rowCount - 1) {
            guard row >= 0, let line = line(at: row) else { continue }
            let width = min(line.count, terminal.cols)
            var start = -1
            var end = -1
            for col in 0..<width {
                if line[col].semanticContent == .input {
                    if start < 0 { start = col }
                    end = col
                } else if start >= 0 {
                    break
                }
            }
            guard start >= 0 else {
                // A gap in the middle of a wrapped command would mean the tags no longer describe
                // one contiguous line; stop rather than splice unrelated text together.
                if sawInput { break } else { continue }
            }
            if !sawInput, row == rows.lowerBound, start == 0 { return nil }
            sawInput = true
            let text = line.translateToString(trimRight: true, startCol: start, endCol: end + 1,
                                              skipNullCellsFollowingWide: true)
            pieces.append(pieces.isEmpty || line.isWrapped ? text : "\n" + text)
        }
        guard sawInput else { return nil }
        let joined = pieces.joined()
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The last row of the logical line starting at `row`, walking forward over soft wraps.
    func logicalLineEnd(of row: Int) -> Int {
        let count = rowCount
        var end = min(max(row, 0), max(count - 1, 0))
        while end + 1 < count, line(at: end + 1)?.isWrapped == true { end += 1 }
        return end
    }

    /// The first row of the logical line containing `row`, walking back over soft wraps.
    func logicalLineStart(of row: Int) -> Int {
        var start = min(max(row, 0), max(rowCount - 1, 0))
        while start > 0, line(at: start)?.isWrapped == true { start -= 1 }
        return start
    }

    /// Everything after the last shell prompt character on a line, for shells that mark nothing.
    /// A guess by construction: it exists so the buttons still do something useful over ssh.
    static func strippingPromptPrefix(_ line: String) -> String {
        let markers = ["❯ ", "➜ ", "$ ", "% ", "# ", "> "]
        var best: String.Index?
        for marker in markers {
            if let range = line.range(of: marker, options: .backwards), best == nil || range.upperBound > best! {
                best = range.upperBound
            }
        }
        let body = best.map { String(line[$0...]) } ?? line
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// Tidies text taken off a terminal grid: rows are padded to the full width and the screen
    /// below the content is blank, neither of which anyone wants on the clipboard.
    static func tidied(_ text: String, enabled: Bool) -> String {
        guard enabled else { return text }
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var out = line
            while let last = out.last, last == " " || last == "\t" || last == "\u{0}" { out.removeLast() }
            return out
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }
}
