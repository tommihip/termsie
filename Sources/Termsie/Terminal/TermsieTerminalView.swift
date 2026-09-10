import AppKit
import SwiftTerm

/// SwiftTerm's local-process view plus the hooks Termsie needs: activity/bell signals,
/// focus tracking, input broadcast, "press any key to close" after the shell exits, and the
/// bookkeeping the copy tools read (command marks, screen clears, a surviving selection).
final class TermsieTerminalView: LocalProcessTerminalView {
    var onActivity: (() -> Void)?
    var onBell: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onMouseDown: (() -> Void)?
    /// Given a mouse-down, may claim it as a window-chrome gesture (Option-Command drag moves the
    /// terminal). Returning true suppresses SwiftTerm's own handling for that event.
    var onChromeDrag: ((NSEvent) -> Bool)?
    var onInputAfterExit: (() -> Void)?
    /// Other views that should receive the same keyboard input. Returns [] when not broadcasting.
    var broadcastTargets: (() -> [TermsieTerminalView])?
    /// Whether something other than the shell owns the terminal right now. Asked of the pane,
    /// which watches the pty's foreground process group, and only consulted for shells whose
    /// marks describe prompts but not commands.
    var foregroundJobRunning: (() -> Bool)?

    var hasExited = false
    /// True while the emulator (not the user) is producing bytes, e.g. replies to device queries.
    private var emulatorReplyInFlight = false
    private var lastActivityNotification: CFTimeInterval = 0

    // MARK: Copy state

    private let markScanner = CommandMarkScanner()
    private(set) var markState = CommandMarkState()
    /// Invariant row of the top of the screen when the last `clear` ran, so "everything" can mean
    /// everything since then. Nil until something clears.
    private var clearFloorInvariantRow: Int?
    /// Invariant row where the user last pressed Return, the fallback for a shell that marks
    /// nothing at all — an ssh session, or a shell Termsie could not shim.
    private var submittedInvariantRow: Int?
    /// The text last put on the clipboard by auto-copy, so holding a selection still does not
    /// rewrite the clipboard on every mouse-up.
    private var lastAutoCopied: String?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let hits = markScanner.scan(slice)
        if hits.isEmpty {
            feedPreservingSelection(slice)
        } else {
            // A clear has to be applied with the buffer in exactly the state it left behind, so
            // the stream is split there and the floor recorded between the halves. Everything
            // else only moves our own state machine and can be applied as it is passed.
            var cursor = slice.startIndex
            for hit in hits {
                markState.apply(hit.event)
                guard hit.event == .screenCleared || hit.event == .scrollbackCleared else { continue }
                let end = slice.startIndex + hit.end
                feedPreservingSelection(slice[cursor..<end])
                cursor = end
                if hit.event == .screenCleared { noteScreenCleared() } else { noteScrollbackCleared() }
            }
            if cursor < slice.endIndex { feedPreservingSelection(slice[cursor...]) }
        }

        let now = CACurrentMediaTime()
        if now - lastActivityNotification > 0.3 {
            lastActivityNotification = now
            onActivity?()
        }
    }

    /// Feeds one chunk with the selection carried across it.
    ///
    /// SwiftTerm drops the selection on *every* feed while mouse reporting is on, so text you
    /// highlighted vanishes the moment the next line of output lands. That is a real problem for
    /// a terminal you leave streaming, and turning mouse reporting off to avoid it would break
    /// every full-screen program. Instead the anchors are taken before the feed and put back
    /// after, shifted by whatever the scrollback trimmed in between.
    private func feedPreservingSelection(_ slice: ArraySlice<UInt8>) {
        let terminal = getTerminal()
        guard selection.active else {
            super.dataReceived(slice: slice)
            return
        }
        let start = selection.start
        let end = selection.end
        let pivot = selection.pivot
        let trimmedBefore = terminal.buffer.totalLinesTrimmed
        let wasAlternate = terminal.isCurrentBufferAlternate

        super.dataReceived(slice: slice)

        // A program that switched to the alternate screen has replaced everything the anchors
        // referred to, and a reset has renumbered the rows outright.
        guard !selection.active,
              terminal.isCurrentBufferAlternate == wasAlternate,
              terminal.buffer.totalLinesTrimmed >= trimmedBefore else { return }
        let shift = terminal.buffer.totalLinesTrimmed - trimmedBefore
        guard start.row - shift >= 0, end.row - shift >= 0 else { return }
        selection.setSelection(start: Position(col: start.col, row: start.row - shift),
                               end: Position(col: end.col, row: end.row - shift))
        selection.pivot = pivot.map { Position(col: $0.col, row: $0.row - shift) }
    }

    /// Records where post-clear content starts. Anything above is still in the scrollback, and
    /// "copy everything" deliberately leaves it there.
    private func noteScreenCleared() {
        let terminal = getTerminal()
        let capture = TerminalTextCapture(terminal)
        clearFloorInvariantRow = terminal.buffer.totalLinesTrimmed + capture.screenTopRow
    }

    /// Every row moved when the scrollback went, so nothing anchored to one still means what it
    /// did. A `clear` follows this with a screen clear that puts a correct floor straight back.
    private func noteScrollbackCleared() {
        clearFloorInvariantRow = nil
        submittedInvariantRow = nil
        selection.selectNone()
    }

    /// Forgets the clear floor, for when Termsie itself throws the scrollback away.
    func resetCopyAnchors() {
        clearFloorInvariantRow = nil
        submittedInvariantRow = nil
        markScanner.reset()
    }

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }

    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            onFocusChange?(newValue)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        if onChromeDrag?(event) == true { return }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        autoCopySelection()
    }

    /// Copies whatever selection a completed mouse gesture left behind, when the user has asked
    /// for that. Covers the drag, the double-click word and the triple-click line alike, because
    /// it looks at the result rather than at which gesture produced it.
    @discardableResult
    func autoCopySelection() -> Bool {
        guard ConfigStore.shared.config.copy.autoCopyOnSelect else { return false }
        guard let text = getSelection(), !text.isEmpty, text != lastAutoCopied else { return false }
        lastAutoCopied = text
        Self.writeToClipboard(text)
        return true
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        emulatorReplyInFlight = true
        super.send(source: source, data: data)
        emulatorReplyInFlight = false
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if hasExited {
            if !emulatorReplyInFlight { onInputAfterExit?() }
            return
        }
        if !emulatorReplyInFlight { noteUserInput(data) }
        super.send(source: source, data: data)
        guard !emulatorReplyInFlight, let targets = broadcastTargets?(), !targets.isEmpty else { return }
        for target in targets where target !== self && !target.hasExited {
            target.process?.send(data: data)
        }
    }

    /// Remembers the row a Return was pressed on. It is the only thing a shell that says nothing
    /// about its prompts leaves us to anchor "the last command" to.
    private func noteUserInput(_ data: ArraySlice<UInt8>) {
        guard data.contains(0x0d) else { return }
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return }
        let capture = TerminalTextCapture(terminal)
        let cursorRow = capture.screenTopRow + terminal.getCursorLocation().y
        submittedInvariantRow = terminal.buffer.totalLinesTrimmed + capture.logicalLineStart(of: cursorRow)
    }

    // MARK: Copy operations

    /// What the copy tools can do with this terminal right now. Deliberately cheap: it is asked
    /// every time the list repaints, so nothing here walks the buffer.
    struct Availability {
        var selection = false
        var lastCommandOutput = false
        var lastCommand = false
        var everything = false
    }

    var copyAvailability: Availability {
        var out = Availability()
        // `hasSelectionRange` rather than the selected text: this runs on every burst of output,
        // and building the string for a page-long selection just to ask whether it is empty would
        // be paid for over and over.
        out.selection = selection.active && selection.hasSelectionRange
        out.everything = true
        let anchored = markState.hasMarks || submittedInvariantRow != nil
        out.lastCommandOutput = anchored
        out.lastCommand = anchored
        return out
    }

    /// The buffer rows holding the last command: its prompt, the command itself, and everything
    /// it printed. Nil when nothing has told us where a command begins.
    private func lastCommandRows() -> ClosedRange<Int>? {
        let terminal = getTerminal()
        let capture = TerminalTextCapture(terminal)
        let bottom = capture.lastContentRow()

        if markState.hasMarks {
            let prompts = capture.promptRows(limit: 2)
            guard let newest = prompts.first else { return nil }
            let live = foregroundJobRunning?() ?? false
            if markState.newestPromptOwnsACommand(liveJob: live) {
                return newest...max(newest, bottom)
            }
            // The newest prompt is waiting for input, so the last command ran at the one before
            // it and ends where that fresh prompt begins.
            guard prompts.count > 1 else { return nil }
            return prompts[1]...max(prompts[1], newest - 1)
        }

        guard let invariant = submittedInvariantRow else { return nil }
        let row = invariant - terminal.buffer.totalLinesTrimmed
        guard row >= 0, row < capture.rowCount else { return nil }
        // With nothing running, the cursor is sitting on the prompt the shell drew *after* the
        // command, and that prompt is not part of what the command did.
        var end = bottom
        if !(foregroundJobRunning?() ?? false) {
            let cursorRow = capture.screenTopRow + terminal.getCursorLocation().y
            let promptRow = capture.logicalLineStart(of: cursorRow)
            if promptRow > row { end = min(end, promptRow - 1) }
        }
        return row...max(row, end)
    }

    /// The last command's prompt, the command, and its output.
    func lastCommandBlockText() -> String? {
        guard let rows = lastCommandRows() else { return nil }
        let capture = TerminalTextCapture(getTerminal())
        return nonEmpty(capture.text(rows: rows))
    }

    /// Just the command that was run, without the prompt in front of it.
    func lastCommandText() -> String? {
        guard let rows = lastCommandRows() else { return nil }
        let capture = TerminalTextCapture(getTerminal())
        // A shell that never says when a command starts leaves the terminal tagging its output
        // as more input, so in that case only the prompt's own line can be trusted.
        let tagged = markState.reportsCommandLifecycle
            ? rows
            : rows.lowerBound...min(rows.upperBound, capture.logicalLineEnd(of: rows.lowerBound))
        if markState.hasMarks, let input = capture.inputText(rows: tagged) {
            return input
        }
        // Nothing tagged the input, so fall back to the first line of the block with whatever
        // looks like a prompt taken off the front. `text` has already rejoined soft wraps, so the
        // first component is the whole command however far it ran on.
        let block = capture.text(rows: rows)
        guard let line = block.components(separatedBy: "\n").first else { return nil }
        return nonEmpty(TerminalTextCapture.strippingPromptPrefix(line))
    }

    /// Everything the terminal still holds, back to the last `clear`.
    func wholeTerminalText() -> String? {
        let terminal = getTerminal()
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

    /// Selects a rectangle of the visible screen, so selection behaviour can be driven from the
    /// headless test harness rather than only by a real mouse.
    func selectForTesting(fromRow: Int, fromCol: Int, toRow: Int, toCol: Int) {
        let top = getTerminal().getTopVisibleRow()
        selection.setSelection(start: Position(col: fromCol, row: top + fromRow),
                               end: Position(col: toCol, row: top + toRow))
    }

    /// A one-line description of the copy state, for headless assertions.
    var copyStateDescription: String {
        let a = copyAvailability
        return "marks=\(markState.hasMarks) lifecycle=\(markState.lifecycle) lifecycleMarks=\(markState.reportsCommandLifecycle)"
            + " autoCopy=\(ConfigStore.shared.config.copy.autoCopyOnSelect)"
            + " selection=\(a.selection) lastOutput=\(a.lastCommandOutput) lastCommand=\(a.lastCommand)"
    }

    static func writeToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
