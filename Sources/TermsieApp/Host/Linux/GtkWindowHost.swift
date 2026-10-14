import Foundation
import CTermsieHost
import TermsieCore

/// The GTK window under a `MainWindow`: turns the C layer's callbacks into the controller's
/// calls, and does the few things only the platform can (showing, full screen, cursors, where
/// the input method composes).
final class LinuxWindowHost: HostWindow {
    unowned let controller: MainWindow
    private var window: OpaquePointer?
    private var width = 1280
    private var height = 820
    private var scaleFactor = 1
    private var focused = false
    private var cursor: CursorShape = .arrow
    private var titleText = ""

    init(controller: MainWindow) {
        self.controller = controller
    }

    private static func host(_ ctx: UnsafeMutableRawPointer?) -> LinuxWindowHost {
        Unmanaged<LinuxWindowHost>.fromOpaque(ctx!).takeUnretainedValue()
    }

    // MARK: HostWindow

    var ref: WindowRef? { window.map { UnsafeMutableRawPointer($0) } }
    var renderTarget: UnsafeMutableRawPointer? { ref }
    var clientPixelSize: (width: Int, height: Int) { (width * scaleFactor, height * scaleFactor) }
    var dpi: Float { Float(96 * scaleFactor) }
    var scale: Double { Double(scaleFactor) }
    var isVisible: Bool { tw_window_is_visible(window) != 0 }
    var isFocused: Bool { focused }
    var isFullScreen: Bool { tw_window_is_fullscreen(window) != 0 }
    var title: String {
        get { titleText }
        set {
            titleText = newValue
            withWide(newValue) { tw_window_set_title(window, $0) }
        }
    }
    /// Wayland gives a window no position, so only the size is kept.
    var frame: [Double] { [0, 0, Double(width * scaleFactor), Double(height * scaleFactor)] }

    func open(frame: [Double]?) -> Bool {
        if let f = frame, f.count == 4, f[2] >= 400, f[3] >= 300 {
            width = Int(f[2])
            height = Int(f[3])
        }
        var cb = TWWindowCallbacks()
        cb.context = Unmanaged.passUnretained(self).toOpaque()
        cb.draw = { ctx in LinuxWindowHost.host(ctx).controller.paint() }
        cb.resize = { ctx, w, h, s in
            let me = LinuxWindowHost.host(ctx)
            me.width = Int(w)
            me.height = Int(h)
            me.scaleFactor = max(1, Int(s))
            me.controller.windowResized()
        }
        cb.mouse_down = { ctx, x, y, button, mods in
            LinuxWindowHost.host(ctx).controller.mouseDown(CGPoint(x: x, y: y), button: Int(button), isDouble: false, modifiers: Modifiers(mods))
        }
        cb.mouse_up = { ctx, x, y, button, mods in
            let me = LinuxWindowHost.host(ctx)
            me.controller.mouseUp(CGPoint(x: x, y: y), button: Int(button), modifiers: Modifiers(mods))
            me.updateCursor(at: CGPoint(x: x, y: y), modifiers: Modifiers(mods))
        }
        cb.mouse_move = { ctx, x, y, mods in
            let me = LinuxWindowHost.host(ctx)
            me.controller.mouseMoved(CGPoint(x: x, y: y), modifiers: Modifiers(mods))
            me.updateCursor(at: CGPoint(x: x, y: y), modifiers: Modifiers(mods))
        }
        cb.mouse_leave = { ctx in LinuxWindowHost.host(ctx).controller.mouseLeft() }
        cb.scroll = { ctx, x, y, stepsX, stepsY, mods in
            let me = LinuxWindowHost.host(ctx)
            let p = CGPoint(x: x, y: y)
            if stepsY != 0 { me.controller.wheel(p, steps: stepsY, horizontal: false, modifiers: Modifiers(mods)) }
            if stepsX != 0 { me.controller.wheel(p, steps: stepsX, horizontal: true, modifiers: Modifiers(mods)) }
        }
        cb.key_down = { ctx, keyval, base, unicode, mods in
            LinuxWindowHost.host(ctx).keyDown(keyval: keyval, base: base, unicode: unicode, modifiers: Modifiers(mods)) ? 1 : 0
        }
        cb.text = { ctx, utf8 in
            guard let utf8 else { return }
            LinuxWindowHost.host(ctx).controller.insertText(String(cString: utf8), meta: false)
        }
        cb.focus = { ctx, focused in
            let me = LinuxWindowHost.host(ctx)
            me.focused = focused != 0
            me.controller.focusChanged()
        }
        cb.close_request = { ctx in
            LinuxWindowHost.host(ctx).controller.requestClose()
            return 0
        }
        cb.destroyed = { ctx in
            let me = LinuxWindowHost.host(ctx)
            me.window = nil
            me.controller.windowDestroyed()
        }
        window = withWide(AppInfo.name) { tw_window_create(&cb, $0, Int32(width), Int32(height)) }
        return window != nil
    }

    func show(activate: Bool) {
        tw_window_show(window, activate ? 1 : 0)
    }

    func destroy() {
        tw_window_destroy(window)
    }

    func applyChrome() -> Bool {
        tw_window_set_icon(ref, nil)
        return false
    }

    func requestPaint() {
        tw_window_queue_draw(window)
    }

    func toggleFullScreen() {
        tw_window_set_fullscreen(window, isFullScreen ? 0 : 1)
    }

    // GDK keeps pointer events coming to the pressed widget on its own.
    func setCapture() {}
    func releaseCapture() {}

    func setIMEPosition(x: Int, y: Int, lineHeight: Int) {
        tw_ime_set_position(ref, Int32(x), Int32(y), Int32(lineHeight))
    }

    // MARK: Cursor

    private func updateCursor(at p: CGPoint, modifiers: Modifiers) {
        let shape = controller.cursorShape(at: p, modifiers: modifiers)
        guard shape != cursor else { return }
        cursor = shape
        tw_window_set_cursor(window, shape.cssName)
    }

    // MARK: Keyboard

    /// A key the input method left alone. Shortcuts and the terminal's special keys come first;
    /// what is left is typed as text, Alt making it a meta key.
    private func keyDown(keyval: UInt32, base: UInt32, unicode: UInt32, modifiers m: Modifiers) -> Bool {
        if let key = Key(keyval: base) ?? Key(keyval: keyval) {
            if controller.keyDown(key, modifiers: m) { return true }
        }
        guard unicode != 0, let scalar = UnicodeScalar(unicode) else { return false }
        if m.contains(.control) && !m.contains(.alt) {
            // Ctrl with a letter or one of @ [ \ ] ^ _ is its control character; anything else
            // with Ctrl means nothing to a terminal.
            let upper = Character(scalar).uppercased().unicodeScalars.first!.value
            guard (0x40...0x5F).contains(upper) else { return false }
            controller.insertText(String(UnicodeScalar(UInt8(upper & 0x1f))), meta: false)
            return true
        }
        let value = scalar.value
        let typeable = value >= 0x20 || value == 0x0d || value == 0x09 || value == 0x1b
        guard typeable, value != 0x7f else { return false }
        controller.insertText(String(scalar), meta: m.contains(.alt))
        return true
    }
}

func makeHostWindow(for controller: MainWindow) -> HostWindow {
    LinuxWindowHost(controller: controller)
}

extension Modifiers {
    /// From the C layer's bits: 1 shift, 2 alt, 4 control, the same values.
    init(_ bits: UInt32) { self.init(rawValue: Int(bits)) }
}

extension CursorShape {
    var cssName: String {
        switch self {
        case .arrow: return "default"
        case .ibeam: return "text"
        case .hand: return "pointer"
        case .sizeWE: return "ew-resize"
        case .sizeNS: return "ns-resize"
        case .sizeNWSE: return "nwse-resize"
        case .sizeNESW: return "nesw-resize"
        case .sizeAll: return "move"
        case .wait: return "wait"
        }
    }
}

extension Key {
    /// GDK keyvals as the shared front end names them. Letters are upper-cased, so a shortcut
    /// table written once matches whatever Shift did.
    init?(keyval: UInt32) {
        switch keyval {
        case 0xff52, 0xff97: self = .up
        case 0xff54, 0xff99: self = .down
        case 0xff51, 0xff96: self = .left
        case 0xff53, 0xff98: self = .right
        case 0xff50, 0xff95: self = .home
        case 0xff57, 0xff9c: self = .end
        case 0xff55, 0xff9a: self = .pageUp
        case 0xff56, 0xff9b: self = .pageDown
        case 0xff63, 0xff9e: self = .insert
        case 0xffff, 0xff9f: self = .delete
        case 0xff08: self = .backspace
        case 0xff0d, 0xff8d: self = .enter
        case 0xff1b: self = .escape
        case 0xff09, 0xfe20: self = .tab
        case 0x20: self = .space
        case 0xffbe...0xffc9: self = .f(Int(keyval - 0xffbe) + 1)
        case 0xffab: self = .char("+")
        case 0xffad: self = .char("-")
        case 0xffaa: self = .char("*")
        case 0xffaf: self = .char("/")
        case 0xffae: self = .char(".")
        case 0xffb0...0xffb9: self = .char(Character(UnicodeScalar(UInt8(keyval - 0xffb0) + 0x30)))
        case 0x21...0x7e:
            self = .char(Character(String(UnicodeScalar(UInt8(keyval))).uppercased()))
        default:
            return nil
        }
    }
}
