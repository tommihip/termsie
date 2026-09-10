import Foundation

/// Watches the pty byte stream for the two things the copy tools need and SwiftTerm does not
/// hand back: the OSC 133 marks a shell emits around each prompt, and screen clears.
///
/// It is a byte-level state machine rather than a search over each chunk because the pty delivers
/// arbitrary slices — a sequence routinely arrives split across two reads. Anything it does not
/// recognise it ignores; nothing here can alter what the emulator sees.
final class CommandMarkScanner {
    enum Event: Equatable {
        /// OSC 133;A or ;N — a new prompt is about to be drawn.
        case promptStart
        /// OSC 133;B or ;I — the prompt is written and the shell is taking input.
        case inputStart
        /// OSC 133;C — the command was submitted and output begins.
        case commandStart
        /// OSC 133;D — the command finished.
        case commandEnd
        /// CSI 2 J — the screen was blanked; the scrollback above it survives.
        case screenCleared
        /// CSI 3 J — the scrollback itself was thrown away, so every row moved.
        case scrollbackCleared
    }

    /// An event and the offset just past the sequence that produced it, so a caller that needs to
    /// know the buffer state at that exact point can split its feed there.
    struct Hit {
        let event: Event
        let end: Int
    }

    private enum Phase {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
    }

    private var phase: Phase = .ground
    private var params: [UInt8] = []
    /// Past this length a sequence is not one of ours, so stop growing the buffer but keep
    /// consuming until its terminator. A hostile stream cannot make this allocate.
    private static let maxParams = 64

    func reset() {
        phase = .ground
        params.removeAll(keepingCapacity: true)
    }

    /// Scans one chunk, returning the marks it found in stream order.
    func scan(_ bytes: ArraySlice<UInt8>) -> [Hit] {
        var hits: [Hit] = []
        var offset = 0
        for byte in bytes {
            offset += 1
            switch phase {
            case .ground:
                if byte == 0x1b { phase = .escape }
            case .escape:
                switch byte {
                case 0x5b: phase = .csi; params.removeAll(keepingCapacity: true)      // [
                case 0x5d: phase = .osc; params.removeAll(keepingCapacity: true)      // ]
                case 0x1b: break                                                       // ESC ESC
                default: phase = .ground
                }
            case .csi:
                // Parameter and intermediate bytes, then one final byte ends the sequence.
                if byte >= 0x20 && byte <= 0x3f {
                    if params.count < Self.maxParams { params.append(byte) }
                } else if byte >= 0x40 && byte <= 0x7e {
                    if byte == 0x4a, let event = screenClearEvent() {                   // J
                        hits.append(Hit(event: event, end: offset))
                    }
                    phase = .ground
                } else {
                    phase = .ground
                }
            case .osc:
                switch byte {
                case 0x07, 0x9c:                                                       // BEL, C1 ST
                    if let event = oscEvent() { hits.append(Hit(event: event, end: offset)) }
                    phase = .ground
                case 0x1b:
                    phase = .oscEscape
                default:
                    if params.count < Self.maxParams { params.append(byte) }
                }
            case .oscEscape:
                if byte == 0x5c {                                                      // ESC \
                    if let event = oscEvent() { hits.append(Hit(event: event, end: offset)) }
                    phase = .ground
                } else {
                    // Anything else aborts the OSC. Re-read this byte as a fresh one so an
                    // immediately following sequence is not swallowed.
                    phase = byte == 0x1b ? .escape : .ground
                }
            }
        }
        return hits
    }

    /// `CSI 2 J` and `CSI 3 J` are the two that wipe content. `CSI 0 J` and `CSI 1 J` erase only
    /// part of the screen around the cursor and are ordinary redraw traffic.
    private func screenClearEvent() -> Event? {
        if params == [0x32] { return .screenCleared }
        if params == [0x33] { return .scrollbackCleared }
        return nil
    }

    private func oscEvent() -> Event? {
        // "133;<action>…"
        guard params.count >= 5,
              params[0] == 0x31, params[1] == 0x33, params[2] == 0x33, params[3] == 0x3b else {
            return nil
        }
        switch params[4] {
        case 0x41, 0x4e: return .promptStart     // A, N
        case 0x42, 0x49: return .inputStart      // B, I
        case 0x43: return .commandStart          // C
        case 0x44: return .commandEnd            // D
        default: return nil
        }
    }
}

/// Where the shell is in the prompt → command → output cycle, as far as its marks have said.
///
/// A shell that emits no marks at all leaves this at `.unknown`, which is the signal to fall back
/// to what Termsie itself saw the user type.
enum CommandLifecycle {
    case unknown
    case atPrompt
    case running
    case finished
}

/// The running conclusion drawn from the mark stream: where the shell is, and whether it says
/// anything about commands starting and ending at all.
struct CommandMarkState {
    private(set) var lifecycle: CommandLifecycle = .unknown
    /// True once a C or D has been seen. A shell that only marks its prompts (bash, without a
    /// DEBUG trap) never sets this, and the caller decides "is a command running" another way.
    private(set) var reportsCommandLifecycle = false
    /// True once any mark has been seen, so prompt rows in the buffer can be trusted.
    var hasMarks: Bool { lifecycle != .unknown }

    mutating func apply(_ event: CommandMarkScanner.Event) {
        switch event {
        case .promptStart, .inputStart:
            lifecycle = .atPrompt
        case .commandStart:
            lifecycle = .running
            reportsCommandLifecycle = true
        case .commandEnd:
            lifecycle = .finished
            reportsCommandLifecycle = true
        case .screenCleared, .scrollbackCleared:
            break
        }
    }

    /// Whether the newest prompt in the buffer is the one a command was launched from, rather than
    /// a fresh one waiting for input. `liveJob` covers shells that mark prompts but not commands.
    func newestPromptOwnsACommand(liveJob: Bool) -> Bool {
        switch lifecycle {
        case .running, .finished: return true
        case .atPrompt: return !reportsCommandLifecycle && liveJob
        case .unknown: return false
        }
    }
}
