import Foundation
import SwiftTerm

/// Turns keys into what a terminal program reads.
///
/// Characters come from the platform's text input, which already applied the keyboard layout,
/// dead keys and AltGr. `keyDown` supplies only what text input cannot: cursor and editing keys,
/// function keys, and the Ctrl combinations that produce no character. Alt+key is sent as ESC
/// followed by the key, the xterm "meta sends escape" convention that `optionAsMeta` gives on
/// macOS; the hosts do that from their own text events.
enum KeyEncoder {
    /// The bytes for a non-character key, or nil when text input will deliver it (or it means
    /// nothing to a terminal).
    static func keyDown(key: Key, modifiers m: Modifiers, applicationCursor: Bool) -> [UInt8]? {
        let csi: [UInt8] = [0x1b, 0x5b]
        let mod = m.xtermParameter

        func cursor(_ final: UInt8) -> [UInt8] {
            if m.isEmpty { return applicationCursor ? [0x1b, 0x4f, final] : csi + [final] }
            return csi + Array("1;\(mod)".utf8) + [final]
        }
        func tilde(_ code: Int) -> [UInt8] {
            m.isEmpty ? csi + Array("\(code)~".utf8) : csi + Array("\(code);\(mod)~".utf8)
        }

        switch key {
        case .up: return cursor(0x41)
        case .down: return cursor(0x42)
        case .right: return cursor(0x43)
        case .left: return cursor(0x44)
        case .home: return cursor(0x48)
        case .end: return cursor(0x46)
        case .insert: return tilde(2)
        case .delete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .f(let n) where n >= 1 && n <= 12:
            if n <= 4 {
                let final = UInt8(0x50 + n - 1)   // P Q R S
                return m.isEmpty ? [0x1b, 0x4f, final] : csi + Array("1;\(mod)".utf8) + [final]
            }
            let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
            return tilde(codes[n] ?? 15)
        case .tab where m.contains(.shift):
            return csi + [0x5a]                       // CSI Z, back-tab
        case .backspace:
            // Backspace is DEL (^?), as every Unix-style program expects; Ctrl+Backspace is ^H and
            // Alt+Backspace deletes a word.
            if m.contains(.control) { return [0x08] }
            return m.contains(.alt) ? [0x1b, 0x7f] : [0x7f]
        case .enter where m.contains(.alt):
            return [0x1b, 0x0d]
        case .space where m.contains(.control):
            return [0x00]                             // Ctrl+Space is NUL
        case .char("/") where m.contains(.control) && !m.contains(.alt):
            return [0x1f]                             // Ctrl+/ is ^_
        case .char("2") where m == .control:          // Ctrl+2 is NUL
            return [0x00]
        case .char("6") where m.contains(.control) && !m.contains(.alt):
            return [0x1e]                             // Ctrl+6 is ^^
        case .char(let c) where m.contains(.control) && !m.contains(.alt) && !m.contains(.shift):
            // Ctrl+letter: the control character. Windows delivers these through WM_CHAR as
            // well, but a consumed key never reaches it, so both hosts agree.
            if let ascii = c.asciiValue, (0x41...0x5A).contains(ascii) { return [ascii & 0x1f] }
            switch c {
            case "[": return [0x1b]
            case "\\": return [0x1c]
            case "]": return [0x1d]
            default: return nil
            }
        default:
            return nil
        }
    }
}
