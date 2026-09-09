import AppKit
import ScreenCaptureKit

/// Captures a single window to an image, including Metal-rendered content.
///
/// This exists because the obvious alternatives do not work here. `NSView.cacheDisplay` and
/// `CALayer.render(in:)` cannot read a `CAMetalLayer`, so the terminals would come out blank —
/// the same limitation that makes the sidebar thumbnails buffer-derived. `CGWindowListCreateImage`
/// did work, but it is deprecated as of macOS 14 and outright unavailable on current SDKs; this
/// package only saw a warning because it targets macOS 14.
///
/// ScreenCaptureKit needs Screen Recording permission. That is a fair trade for a screenshot tool,
/// but it is a stricter requirement than the old call had, so failures are reported loudly rather
/// than silently producing a misleading picture.
enum WindowCapture {
    enum Failure: LocalizedError {
        case windowNotShareable
        case timedOut

        var errorDescription: String? {
            switch self {
            case .windowNotShareable:
                return "the window was not offered by ScreenCaptureKit (is Screen Recording allowed for Termsie?)"
            case .timedOut:
                return "the capture did not finish in time"
            }
        }
    }

    /// Captures `window` at its backing scale, or scaled down to `maxWidth` when given.
    ///
    /// Capping the width matters for recording rather than for single shots: the
    /// per-frame cost is dominated by pixel count, so asking ScreenCaptureKit for
    /// the size actually needed roughly doubles the achievable frame rate.
    @MainActor
    static func image(of window: NSWindow, maxWidth: Int? = nil) async throws -> CGImage {
        let targetID = CGWindowID(window.windowNumber)
        let scale = window.backingScaleFactor

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == targetID }) else {
            throw Failure.windowNotShareable
        }

        var width = max(Int((target.frame.width * scale).rounded()), 1)
        var height = max(Int((target.frame.height * scale).rounded()), 1)
        if let maxWidth, width > maxWidth {
            height = max(Int((Double(height) * Double(maxWidth) / Double(width)).rounded()), 1)
            width = maxWidth
        }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        // Just this window, matching the old `.optionIncludingWindow` behaviour: whatever sits
        // behind it — including the desktop the window blurs — is not part of the capture.
        let filter = SCContentFilter(desktopIndependentWindow: target)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Captures and writes a PNG, returning its pixel size.
    @MainActor
    static func writePNG(of window: NSWindow, to path: String) async throws -> (width: Int, height: Int) {
        try await write(of: window, to: path, type: .png, properties: [:], maxWidth: nil)
    }

    /// Captures and writes a JPEG. Used for recording, where PNG encoding is the
    /// bottleneck on frame rate and the frames are an intermediate anyway.
    @MainActor
    static func writeJPEG(
        of window: NSWindow, to path: String, quality: Double = 0.92, maxWidth: Int? = nil
    ) async throws -> (width: Int, height: Int) {
        try await write(of: window, to: path, type: .jpeg,
                        properties: [.compressionFactor: quality], maxWidth: maxWidth)
    }

    @MainActor
    private static func write(
        of window: NSWindow, to path: String,
        type: NSBitmapImageRep.FileType,
        properties: [NSBitmapImageRep.PropertyKey: Any],
        maxWidth: Int?
    ) async throws -> (width: Int, height: Int) {
        let image = try await image(of: window, maxWidth: maxWidth)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: type, properties: properties) else {
            throw Failure.windowNotShareable
        }
        try data.write(to: URL(fileURLWithPath: path))
        return (image.width, image.height)
    }
}
