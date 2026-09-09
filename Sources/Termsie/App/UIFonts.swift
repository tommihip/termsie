import AppKit

/// Cached interface fonts for drawing code.
///
/// `NSFont.systemFont(ofSize:weight:)` and its monospaced siblings are declared non-null, so Swift
/// types them non-optional — but they have been observed returning nil when called repeatedly from
/// a draw loop. Swift stores that nil in a reference it believes cannot be nil, nothing complains,
/// and the process dies much later inside CoreText with "attempt to insert nil object" while
/// measuring a string. Resolving each face once, up front, removes both the repeated descriptor
/// lookups and the window in which they can fail.
enum UIFonts {
    private static var cache: [Key: NSFont] = [:]

    private struct Key: Hashable {
        var size: CGFloat
        var weight: CGFloat
        var kind: Int
    }

    static func system(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(size: size, weight: weight, kind: 0)
    }

    static func monospaced(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(size: size, weight: weight, kind: 1)
    }

    static func monospacedDigit(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(size: size, weight: weight, kind: 2)
    }

    private static func font(size: CGFloat, weight: NSFont.Weight, kind: Int) -> NSFont {
        let key = Key(size: size, weight: weight.rawValue, kind: kind)
        if let cached = cache[key] { return cached }
        let made: NSFont
        switch kind {
        case 1: made = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case 2: made = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        default: made = NSFont.systemFont(ofSize: size, weight: weight)
        }
        let resolved = isUsable(made) ? made : fallback(size: size, monospaced: kind != 0)
        cache[key] = resolved
        return resolved
    }

    /// The whole point: a reference AppKit promised is non-nil may not be.
    static func isUsable(_ font: NSFont) -> Bool {
        unsafeBitCast(font, to: UnsafeRawPointer?.self) != nil
    }

    private static func fallback(size: CGFloat, monospaced: Bool) -> NSFont {
        let names = monospaced ? ["Menlo", "Monaco", "Courier"] : ["Helvetica Neue", "Helvetica", "Arial"]
        for name in names {
            if let font = NSFont(name: name, size: size), isUsable(font) { return font }
        }
        // Last resort; if even this is nil the drawing helpers skip the text rather than crash.
        NSLog("Termsie: no usable \(monospaced ? "monospaced" : "interface") font at \(size)pt")
        return NSFont.systemFont(ofSize: size)
    }
}
