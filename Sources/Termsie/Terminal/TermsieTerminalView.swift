import AppKit
import SwiftTerm

/// SwiftTerm's local-process view plus the hooks Termsie needs: activity/bell signals,
/// focus tracking, input broadcast, and "press any key to close" after the shell exits.
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

    var hasExited = false
    /// True while the emulator (not the user) is producing bytes, e.g. replies to device queries.
    private var emulatorReplyInFlight = false
    private var lastActivityNotification: CFTimeInterval = 0

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let now = CACurrentMediaTime()
        if now - lastActivityNotification > 0.3 {
            lastActivityNotification = now
            onActivity?()
        }
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
        super.send(source: source, data: data)
        guard !emulatorReplyInFlight, let targets = broadcastTargets?(), !targets.isEmpty else { return }
        for target in targets where target !== self && !target.hasExited {
            target.process?.send(data: data)
        }
    }
}
