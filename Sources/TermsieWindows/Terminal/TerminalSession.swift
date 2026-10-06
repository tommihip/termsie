import Foundation
import WinSDK
import CTermsieWin
import SwiftTerm
import TermsieCore

/// One terminal's emulator and process, without any drawing: SwiftTerm's `Terminal`, the
/// pseudo console it talks to, and the bookkeeping the copy tools read. The Windows
/// counterpart of the macOS `TermsieTerminalView`, minus the view.
///
/// Everything here runs on the UI thread.
final class TerminalSession: TerminalDelegate {
    private(set) var terminal: Terminal!
    private(set) var selection: SelectionService!
    private(set) var pty: ConPty?

    // MARK: Events

    /// Output was applied. Not throttled.
    var onOutput: (() -> Void)?
    /// Output arrived, at most every 0.3 s: the activity badge's signal.
    var onActivity: (() -> Void)?
    var onBell: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectory: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// Anything that changes what is drawn without new output: cursor, mode, selection.
    var onNeedsDisplay: (() -> Void)?
    /// Other sessions that receive the same keyboard input. Empty when not broadcasting.
    var broadcastTargets: (() -> [TerminalSession])?
    /// Whether something other than the shell owns the terminal right now.
    var foregroundJobRunning: (() -> Bool)?
    /// The user typed into a session whose shell has exited.
    var onInputAfterExit: (() -> Void)?

    private(set) var hasExited = false
    private(set) var exitCode: Int32?
    private(set) var cursorVisible = true
    private(set) var cursorStyle: CursorStyle
    private(set) var title = ""
    /// When synchronized output (DECSET 2026) began, so a program that never ends it cannot
    /// freeze the display.
    private(set) var synchronizedSince: Double?
    private var lastActivity: Double = 0
    private var emulatorReplyInFlight = false
    private(set) var startedAt: Double = 0

    // MARK: Copy state

    private let markScanner = CommandMarkScanner()
    private(set) var markState = CommandMarkState()
    private var clearFloorInvariantRow: Int?
    private var submittedInvariantRow: Int?
    private var lastAutoCopied: String?

    // MARK: Viewport

    /// The invariant row shown at the top while scrolled back; nil follows the output.
    private(set) var scrollAnchor: Int?

    init(cols: Int, rows: Int, config: TermsieConfig) {
        cursorStyle = config.terminalCursorStyle
        let options = TerminalOptions(cols: max(cols, 2), rows: max(rows, 1), cursorStyle: config.terminalCursorStyle,
                                      scrollback: config.scrollback)
        terminal = Terminal(delegate: self, options: options)
        selection = SelectionService(terminal: terminal)
        terminal.installPalette(colors: config.ansiColors)
    }

    // MARK: Process

    func start(executable: String, arguments: [String], environment: [String: String], directory: String?) throws {
        let pty = try ConPty.spawn(executable: executable, arguments: arguments, environment: environment,
                                   directory: directory, cols: terminal.cols, rows: terminal.rows)
        pty.onData = { [weak self] bytes in self?.receive(bytes) }
        pty.onExit = { [weak self] code in self?.processExited(code) }
        self.pty = pty
        startedAt = Clock.now
        pty.start()
    }

    var pid: DWORD { pty?.pid ?? 0 }
    var isRunning: Bool { pty?.isRunning ?? false }

    func terminate() {
        pty?.close()
    }

    private func processExited(_ code: DWORD) {
        guard !hasExited else { return }
        hasExited = true
        exitCode = Int32(bitPattern: code)
        onExit?(exitCode ?? 0)
        onNeedsDisplay?()
    }

    // MARK: Output

    /// Feeds pty output to the emulator, splitting it at screen clears so the clear floor is
    /// recorded with the buffer exactly as the clear left it.
    func receive(_ bytes: [UInt8]) {
        let slice = bytes[...]
        let hits = markScanner.scan(slice)
        if hits.isEmpty {
            terminal.feed(buffer: slice)
        } else {
            var cursor = slice.startIndex
            for hit in hits {
                markState.apply(hit.event)
                guard hit.event == .screenCleared || hit.event == .scrollbackCleared else { continue }
                let end = slice.startIndex + hit.end
                terminal.feed(buffer: slice[cursor..<end])
                cursor = end
                if hit.event == .screenCleared { noteScreenCleared() } else { noteScrollbackCleared() }
            }
            if cursor < slice.endIndex { terminal.feed(buffer: slice[cursor...]) }
        }
        clampScrollAnchor()
        onOutput?()
        let now = Clock.now
        if now - lastActivity > 0.3 {
            lastActivity = now
            onActivity?()
        }
    }

    /// Writes text straight into the emulator: restored output, notices.
    func feed(text: String) {
        terminal.feed(text: text)
        onOutput?()
    }

    private func noteScreenCleared() {
        let capture = TerminalTextCapture(terminal)
        clearFloorInvariantRow = terminal.buffer.totalLinesTrimmed + capture.screenTopRow
    }

    private func noteScrollbackCleared() {
        clearFloorInvariantRow = nil
        submittedInvariantRow = nil
        selection.selectNone()
        scrollAnchor = nil
    }

    func resetCopyAnchors() {
        clearFloorInvariantRow = nil
        submittedInvariantRow = nil
        markScanner.reset()
    }

    func clearScrollback() {
        terminal.clearScrollback()
        resetCopyAnchors()
        scrollAnchor = nil
        selection.selectNone()
        if !hasExited { send(user: [0x0C]) }
        onNeedsDisplay?()
    }

    // MARK: Input

    /// Bytes the user produced: keys, a paste. Broadcast to the other terminals when that is on.
    func send(user data: [UInt8]) {
        if hasExited {
            onInputAfterExit?()
            return
        }
        guard !data.isEmpty else { return }
        noteUserInput(data)
        // Typing returns the view to the live screen, as every terminal does.
        if scrollAnchor != nil {
            scrollAnchor = nil
            onNeedsDisplay?()
        }
        pty?.write(data)
        guard let targets = broadcastTargets?(), !targets.isEmpty else { return }
        for target in targets where target !== self && !target.hasExited {
            target.pty?.write(data)
        }
    }

    func send(text: String) {
        send(user: Array(text.utf8))
    }

    /// A paste, bracketed when the program asked for that, with line endings as a terminal sends
    /// Return.
    func paste(_ text: String) {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if terminal.bracketedPasteMode {
            normalized = normalized.replacingOccurrences(of: "\u{1b}[201~", with: "")
            send(user: Array("\u{1b}[200~".utf8) + Array(normalized.utf8) + Array("\u{1b}[201~".utf8))
        } else {
            send(user: Array(normalized.utf8))
        }
    }

    private func noteUserInput(_ data: [UInt8]) {
        guard data.contains(0x0d), !terminal.isCurrentBufferAlternate else { return }
        let capture = TerminalTextCapture(terminal)
        let cursorRow = capture.screenTopRow + terminal.getCursorLocation().y
        submittedInvariantRow = terminal.buffer.totalLinesTrimmed + capture.logicalLineStart(of: cursorRow)
    }

    // MARK: Size

    func resize(cols: Int, rows: Int) {
        let c = max(cols, 2), r = max(rows, 1)
        guard c != terminal.cols || r != terminal.rows else { return }
        terminal.resize(cols: c, rows: r)
        pty?.resize(cols: c, rows: r)
        clampScrollAnchor()
        onNeedsDisplay?()
    }

    // MARK: Viewport

    /// Line index (into the buffer's lines, scrollback first) of the top visible row.
    var viewTopLine: Int {
        if let anchor = scrollAnchor { return max(0, anchor - terminal.buffer.totalLinesTrimmed) }
        return terminal.getTopVisibleRow()
    }

    var isScrolledBack: Bool { scrollAnchor != nil }

    /// The line shown on screen row `row`.
    func visibleLine(_ row: Int) -> BufferLine? {
        guard scrollAnchor != nil else { return terminal.getLine(row: row) }
        return terminal.getScrollInvariantLine(row: terminal.buffer.totalLinesTrimmed + viewTopLine + row)
    }

    /// Scrolls the view by `lines` (negative is back into the scrollback).
    func scroll(by lines: Int) {
        guard !terminal.isCurrentBufferAlternate else { return }
        let bottom = terminal.getTopVisibleRow()
        let target = min(max(viewTopLine + lines, 0), bottom)
        scrollAnchor = target >= bottom ? nil : terminal.buffer.totalLinesTrimmed + target
        onNeedsDisplay?()
    }

    func scrollToBottom() {
        guard scrollAnchor != nil else { return }
        scrollAnchor = nil
        onNeedsDisplay?()
    }

    func scroll(toLine line: Int) {
        let bottom = terminal.getTopVisibleRow()
        let target = min(max(line, 0), bottom)
        scrollAnchor = target >= bottom ? nil : terminal.buffer.totalLinesTrimmed + target
        onNeedsDisplay?()
    }

    /// How far back the view can go and where it is, for the scroll bar.
    var scrollPosition: (top: Int, maxTop: Int, rows: Int) {
        (viewTopLine, terminal.getTopVisibleRow(), terminal.rows)
    }

    private func clampScrollAnchor() {
        guard let anchor = scrollAnchor else { return }
        if terminal.isCurrentBufferAlternate { scrollAnchor = nil; return }
        let trimmed = terminal.buffer.totalLinesTrimmed
        if anchor < trimmed { scrollAnchor = trimmed }
        if viewTopLine >= terminal.getTopVisibleRow() { scrollAnchor = nil }
    }

    /// The buffer position of a screen cell.
    func bufferPosition(col: Int, row: Int) -> Position {
        Position(col: min(max(col, 0), terminal.cols), row: viewTopLine + row)
    }

    // MARK: Copy

    struct Availability {
        var selection = false
        var lastCommandOutput = false
        var lastCommand = false
        var everything = false
    }

    var copyAvailability: Availability {
        var out = Availability()
        out.selection = selection.active && selection.hasSelectionRange
        out.everything = true
        let anchored = markState.hasMarks || submittedInvariantRow != nil
        out.lastCommandOutput = anchored
        out.lastCommand = anchored
        return out
    }

    var selectedText: String? {
        guard selection.active, selection.hasSelectionRange else { return nil }
        let text = selection.getSelectedText()
        return text.isEmpty ? nil : text
    }

    /// Copies a finished mouse selection when auto-copy is on, once per distinct selection.
    @discardableResult
    func autoCopySelection(owner: HWND?) -> Bool {
        guard ConfigStore.shared.config.copy.autoCopyOnSelect, let text = selectedText, text != lastAutoCopied else {
            return false
        }
        lastAutoCopied = text
        Clipboard.set(text, owner: owner)
        return true
    }

    private func lastCommandRows() -> ClosedRange<Int>? {
        let capture = TerminalTextCapture(terminal)
        let bottom = capture.lastContentRow()
        if markState.hasMarks {
            let prompts = capture.promptRows(limit: 2)
            guard let newest = prompts.first else { return nil }
            let live = foregroundJobRunning?() ?? false
            if markState.newestPromptOwnsACommand(liveJob: live) {
                return newest...max(newest, bottom)
            }
            guard prompts.count > 1 else { return nil }
            return prompts[1]...max(prompts[1], newest - 1)
        }
        guard let invariant = submittedInvariantRow else { return nil }
        let row = invariant - terminal.buffer.totalLinesTrimmed
        guard row >= 0, row < capture.rowCount else { return nil }
        var end = bottom
        if !(foregroundJobRunning?() ?? false) {
            let cursorRow = capture.screenTopRow + terminal.getCursorLocation().y
            let promptRow = capture.logicalLineStart(of: cursorRow)
            if promptRow > row { end = min(end, promptRow - 1) }
        }
        return row...max(row, end)
    }

    func lastCommandBlockText() -> String? {
        guard let rows = lastCommandRows() else { return nil }
        return nonEmpty(TerminalTextCapture(terminal).text(rows: rows))
    }

    func lastCommandText() -> String? {
        guard let rows = lastCommandRows() else { return nil }
        let capture = TerminalTextCapture(terminal)
        let tagged = markState.reportsCommandLifecycle
            ? rows
            : rows.lowerBound...min(rows.upperBound, capture.logicalLineEnd(of: rows.lowerBound))
        if markState.hasMarks, let input = capture.inputText(rows: tagged) {
            return input
        }
        let block = capture.text(rows: rows)
        guard let line = block.components(separatedBy: "\n").first else { return nil }
        return nonEmpty(TerminalTextCapture.strippingPromptPrefix(line))
    }

    func wholeTerminalText() -> String? {
        let capture = TerminalTextCapture(terminal)
        var floor = 0
        if let invariant = clearFloorInvariantRow {
            floor = max(0, invariant - terminal.buffer.totalLinesTrimmed)
        }
        let bottom = capture.lastContentRow(notBefore: floor)
        guard bottom >= floor else { return nil }
        return nonEmpty(capture.text(rows: floor...bottom))
    }

    private func nonEmpty(_ text: String) -> String? {
        let tidied = TerminalTextCapture.tidied(text, enabled: ConfigStore.shared.config.copy.trimCopiedText)
        return tidied.isEmpty ? nil : tidied
    }

    var copyStateDescription: String {
        let a = copyAvailability
        return "marks=\(markState.hasMarks) lifecycle=\(markState.lifecycle) lifecycleMarks=\(markState.reportsCommandLifecycle)"
            + " autoCopy=\(ConfigStore.shared.config.copy.autoCopyOnSelect)"
            + " selection=\(a.selection) lastOutput=\(a.lastCommandOutput) lastCommand=\(a.lastCommand)"
    }

    /// The visible screen as plain text, for headless assertions.
    var screenText: String {
        (0..<terminal.rows).map { visibleLine($0)?.translateToString(trimRight: true) ?? "" }.joined(separator: "\n")
    }

    // MARK: TerminalDelegate

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Replies the emulator makes itself (device attributes, cursor position): they go to the
        // program and are never broadcast or counted as typing.
        guard !hasExited else { return }
        pty?.write(data)
    }

    func setTerminalTitle(source: Terminal, title: String) {
        self.title = title
        onTitle?(title)
    }

    func sizeChanged(source: Terminal) {}

    func scrolled(source: Terminal, yDisp: Int) {}

    func bell(source: Terminal) {
        onBell?()
    }

    func showCursor(source: Terminal) {
        cursorVisible = true
        onNeedsDisplay?()
    }

    func hideCursor(source: Terminal) {
        cursorVisible = false
        onNeedsDisplay?()
    }

    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        cursorStyle = newStyle
        onNeedsDisplay?()
    }

    func bufferActivated(source: Terminal) {
        scrollAnchor = nil
        onNeedsDisplay?()
    }

    func synchronizedOutputChanged(source: Terminal, active: Bool) {
        synchronizedSince = active ? Clock.now : nil
        if !active { onNeedsDisplay?() }
    }

    func hostCurrentDirectoryUpdated(source: Terminal) {
        guard let raw = source.hostCurrentDirectory, let path = TerminalSession.path(fromDirectoryReport: raw) else { return }
        onDirectory?(path)
    }

    func clipboardCopy(source: Terminal, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        Clipboard.set(text, owner: nil)
    }

    func mouseModeChanged(source: Terminal) {
        onNeedsDisplay?()
    }

    /// The display waits for a program's synchronized update to finish, but never more than a
    /// second, whatever the program does.
    var displayIsHeld: Bool {
        guard let since = synchronizedSince else { return false }
        return Clock.now - since < 1.0
    }

    /// Reads an OSC 7 report: `file://host/C:/path`, percent-encoded, or a bare path.
    static func path(fromDirectoryReport raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("file://") {
            s.removeFirst("file://".count)
            // Drop the host: everything up to the next slash.
            if let slash = s.firstIndex(of: "/") { s = String(s[slash...]) } else { return nil }
            s = s.removingPercentEncoding ?? s
            // "/C:/Users/x" → "C:\Users\x"; "//server/share" stays a UNC path.
            if s.count >= 3, s.first == "/", s.dropFirst().first?.isLetter == true, s.dropFirst(2).first == ":" {
                s.removeFirst()
            }
            if s.hasPrefix("//") { s = "/" + s }
            s = s.replacingOccurrences(of: "/", with: "\\")
            if s.count == 2, s.hasSuffix(":") { s += "\\" }
            return s
        }
        return s
    }
}
