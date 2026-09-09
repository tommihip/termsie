import AppKit

/// The fixed-pitch font families offered anywhere Termsie lets you pick a font.
///
/// Proportional fonts are filtered out rather than merely discouraged: a terminal renders on a
/// character grid, so a variable-width font would misalign every column.
enum FontCatalog {
    private static var cached: [String]?

    static var monospacedFamilies: [String] {
        if let cached { return cached }
        let manager = NSFontManager.shared
        var families: Set<String> = []
        for family in manager.availableFontFamilies {
            // `isFixedPitch` is only trustworthy on a concrete font, not a family name.
            guard let font = NSFont(name: family, size: 12) else { continue }
            if font.isFixedPitch || manager.traits(of: font).contains(.fixedPitchFontMask) {
                families.insert(family)
            }
        }
        // Some genuinely fixed-pitch faces report the wrong metrics flags — Monaco among them —
        // so fall back to measuring two glyphs of very different natural width.
        for family in manager.availableFontFamilies where !families.contains(family) {
            guard nameSuggestsMonospace(family), let font = NSFont(name: family, size: 12),
                  advance(of: "i", in: font) == advance(of: "W", in: font) else { continue }
            families.insert(family)
        }
        // Internal families are dot-prefixed and would show as ".AppleSystemUIFontMonospaced".
        families = families.filter { !$0.hasPrefix(".") }
        var list = Array(families)
        if list.isEmpty { list = ["Menlo", "Monaco", "Courier"] }
        list.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        cached = list
        return list
    }

    private static func nameSuggestsMonospace(_ family: String) -> Bool {
        let needles = ["mono", "code", "courier", "consol", "menlo", "monaco", "terminal", "typewriter"]
        let lower = family.lowercased()
        return needles.contains { lower.contains($0) }
    }

    private static func advance(of character: String, in font: NSFont) -> CGFloat {
        (character as NSString).size(withAttributes: [.font: font]).width
    }

    /// Ensures a family the user already has configured stays selectable even if it is not
    /// detected as fixed-pitch, or has since been uninstalled.
    static func families(including current: String?) -> [String] {
        var list = monospacedFamilies
        if let current, !current.isEmpty, !list.contains(current) {
            list.insert(current, at: 0)
        }
        return list
    }

    /// A menu item showing the family name rendered in that family, the way font pickers do.
    static func menuItem(for family: String, sampleSize: CGFloat = 12) -> NSMenuItem {
        let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
        if let font = NSFont(name: family, size: sampleSize) {
            item.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
        }
        item.representedObject = family
        return item
    }
}
