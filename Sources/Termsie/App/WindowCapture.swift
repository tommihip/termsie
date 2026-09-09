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

    /// Captures `window` at its backing scale.
    @MainActor
    static func image(of window: NSWindow) async throws -> CGImage {
        let targetID = CGWindowID(window.windowNumber)
        let scale = window.backingScaleFactor

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == targetID }) else {
            throw Failure.windowNotShareable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(Int((target.frame.width * scale).rounded()), 1)
        configuration.height = max(Int((target.frame.height * scale).rounded()), 1)
        configuration.showsCursor = false
        // Just this window, matching the old `.optionIncludingWindow` behaviour: whatever sits
        // behind it — including the desktop the window blurs — is not part of the capture.
        let filter = SCContentFilter(desktopIndependentWindow: target)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Captures and writes a PNG, returning its pixel size.
    @MainActor
    static func writePNG(of window: NSWindow, to path: String) async throws -> (width: Int, height: Int) {
        let image = try await image(of: window)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure.windowNotShareable
        }
        try data.write(to: URL(fileURLWithPath: path))
        return (image.width, image.height)
    }
}
