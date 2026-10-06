import Foundation
import WinSDK
import SwiftTerm

/// Turns Windows keyboard messages into what a terminal program reads.
///
/// Characters come from WM_CHAR, which already applied the keyboard layout, dead keys, AltGr and
/// Ctrl+letter. WM_KEYDOWN supplies only what WM_CHAR cannot: cursor and editing keys, function
/// keys, and the few Ctrl combinations that produce no character. Alt+key arrives as WM_SYSCHAR
/// and is sent as ESC followed by the key, the xterm "meta sends escape" convention that
/// `optionAsMeta` gives on macOS.
enum KeyEncoder {
    struct Modifiers: OptionSet {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let alt = Modifiers(rawValue: 2)
        static let control = Modifiers(rawValue: 4)

        static var current: Modifiers {
            var m: Modifiers = []
            if Keys.shift { m.insert(.shift) }
            if Keys.alt { m.insert(.alt) }
            if Keys.control { m.insert(.control) }
            return m
        }

        /// The xterm modifier parameter: 1 + shift + 2·alt + 4·ctrl.
        var xtermParameter: Int { 1 + rawValue }
    }

    /// The bytes for a non-character key, or nil when WM_CHAR will deliver it (or it means
    /// nothing to a terminal).
    static func keyDown(vk: Int32, modifiers m: Modifiers, applicationCursor: Bool) -> [UInt8]? {
        let csi: [UInt8] = [0x1b, 0x5b]
        let mod = m.xtermParameter

        func cursor(_ final: UInt8) -> [UInt8] {
            if m.isEmpty { return applicationCursor ? [0x1b, 0x4f, final] : csi + [final] }
            return csi + Array("1;\(mod)".utf8) + [final]
        }
        func tilde(_ code: Int) -> [UInt8] {
            m.isEmpty ? csi + Array("\(code)~".utf8) : csi + Array("\(code);\(mod)~".utf8)
        }

        switch vk {
        case Win.VK_UP: return cursor(0x41)
        case Win.VK_DOWN: return cursor(0x42)
        case Win.VK_RIGHT: return cursor(0x43)
        case Win.VK_LEFT: return cursor(0x44)
        case Win.VK_HOME: return cursor(0x48)
        case Win.VK_END: return cursor(0x46)
        case Win.VK_INSERT: return tilde(2)
        case Win.VK_DELETE: return tilde(3)
        case Win.VK_PRIOR: return tilde(5)
        case Win.VK_NEXT: return tilde(6)
        case Win.VK_F1...Win.VK_F12:
            let n = Int(vk - Win.VK_F1) + 1
            if n <= 4 {
                let final = UInt8(0x50 + n - 1)   // P Q R S
                return m.isEmpty ? [0x1b, 0x4f, final] : csi + Array("1;\(mod)".utf8) + [final]
            }
            let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
            return tilde(codes[n] ?? 15)
        case Win.VK_TAB where m.contains(.shift):
            return csi + [0x5a]                       // CSI Z, back-tab
        case Win.VK_BACK:
            // Backspace is DEL (^?), as every Unix-style program expects; Ctrl+Backspace is ^H and
            // Alt+Backspace deletes a word.
            if m.contains(.control) { return [0x08] }
            return m.contains(.alt) ? [0x1b, 0x7f] : [0x7f]
        case Win.VK_RETURN where m.contains(.alt):
            return [0x1b, 0x0d]
        case Win.VK_SPACE where m.contains(.control):
            return [0x00]                             // Ctrl+Space is NUL
        case Win.VK_OEM_2 where m.contains(.control) && !m.contains(.alt):
            return [0x1f]                             // Ctrl+/ is ^_
        case 0x32 where m == .control:                 // Ctrl+2 is NUL
            return [0x00]
        case 0x36 where m.contains(.control) && !m.contains(.alt):
            return [0x1e]                             // Ctrl+6 is ^^
        default:
            return nil
        }
    }
}

/// Assembles WM_CHAR units into text: characters outside the Basic Multilingual Plane arrive as
/// two messages, one per surrogate.
struct SurrogateAssembler {
    private var high: UInt16?

    mutating func add(_ unit: UInt16) -> String? {
        if (0xD800...0xDBFF).contains(unit) {
            high = unit
            return nil
        }
        if (0xDC00...0xDFFF).contains(unit) {
            guard let h = high else { return nil }
            high = nil
            return String(decoding: [h, unit], as: UTF16.self)
        }
        high = nil
        return String(decoding: [unit], as: UTF16.self)
    }
}
