import UIKit
import GhosttyKit

/// A UIKit view over one host-managed Ghostty surface: no process, no pty.
/// The host feeds the bytes the remote program wrote with `feed(_:)` and
/// gets back what the terminal emits (keys, query replies) via `onOutput`,
/// and every grid size change via `onResize`. Both callbacks come on the
/// main queue.
final class HostedTerminalView: UIView, UIKeyInput {
    private(set) var surface: ghostty_surface_t?
    var onOutput: ((Data) -> Void)?
    var onResize: ((_ columns: Int, _ rows: Int) -> Void)?
    fileprivate var lastGrid: (Int, Int) = (0, 0)

    /// Bytes are parsed off the main thread, in order.
    private let feedQueue = DispatchQueue(label: "ghostty.hosted.feed")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: Surface

    func attach(fontSize: Float = 13) {
        guard surface == nil, let app = GhosttyRuntime.shared.app else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_IOS
        cfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(uiview: me))
        cfg.userdata = me
        cfg.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        cfg.receive_userdata = me
        cfg.receive_buffer = { ud, bytes, len in
            guard let ud, let bytes, len > 0 else { return }
            let data = Data(bytes: bytes, count: len)
            let view = Unmanaged<HostedTerminalView>.fromOpaque(ud).takeUnretainedValue()
            DispatchQueue.main.async { view.onOutput?(data) }
        }
        cfg.receive_resize = { ud, cols, rows, _, _ in
            guard let ud else { return }
            let view = Unmanaged<HostedTerminalView>.fromOpaque(ud).takeUnretainedValue()
            DispatchQueue.main.async {
                // Ghostty also reports pixel-only changes; the host's
                // protocol carries columns and rows, so report grid changes.
                guard view.lastGrid != (Int(cols), Int(rows)) else { return }
                view.lastGrid = (Int(cols), Int(rows))
                view.onResize?(Int(cols), Int(rows))
            }
        }
        cfg.scale_factor = Double(traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale)
        cfg.font_size = fontSize
        surface = ghostty_surface_new(app, &cfg)
        guard let surface else { NSLog("[demo] ghostty_surface_new failed"); return }
        syncSize()
        ghostty_surface_set_focus(surface, true)
        ghostty_surface_set_occlusion(surface, true)
    }

    /// Bytes the remote program wrote. Any thread; they may split escape
    /// sequences or UTF-8 anywhere.
    func feed(_ data: Data) {
        guard let surface else { return }
        feedQueue.async {
            data.withUnsafeBytes { raw in
                guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_surface_write_buffer(surface, p, UInt(raw.count))
            }
        }
    }

    var gridSize: (columns: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let s = ghostty_surface_size(surface)
        return (Int(s.columns), Int(s.rows))
    }

    /// The whole screen as text (for tests).
    func screenText() -> String {
        guard let surface else { return "" }
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text), let p = text.text else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(text.text_len)), as: UTF8.self)
    }

    private func syncSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32((bounds.width * scale).rounded(.down)),
                                 UInt32((bounds.height * scale).rounded(.down)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncSize()
        if let surface { ghostty_surface_set_occlusion(surface, window != nil) }
    }

    // MARK: Keyboard (soft keyboard via UIKeyInput, hardware via presses)

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        for ch in text {
            if ch == "\n" || ch == "\r" {
                sendKey(usage: 0x28, text: nil)  // Return
            } else if ch == "\t" {
                sendKey(usage: 0x2B, text: nil)  // Tab
            } else {
                sendKey(usage: 0, text: String(ch))
            }
        }
    }

    func deleteBackward() {
        sendKey(usage: 0x2A, text: nil)  // Backspace
    }

    /// One key press and release. `usage` is the USB HID usage (UIKey.keyCode
    /// on iOS), 0 when only the text is known.
    @discardableResult
    func sendKey(usage: UInt32, text: String?, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
                 unshifted: Character? = nil) -> Bool {
        guard let surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        ev.mods = mods
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.keycode = usage
        ev.composing = false
        ev.unshifted_codepoint = unshifted?.unicodeScalars.first?.value
            ?? text?.unicodeScalars.first?.value ?? 0
        let handled: Bool
        if let text {
            handled = text.withCString { p in ev.text = p; return ghostty_surface_key(surface, ev) }
        } else {
            handled = ghostty_surface_key(surface, ev)
        }
        ev.action = GHOSTTY_ACTION_RELEASE
        ev.text = nil
        _ = ghostty_surface_key(surface, ev)
        return handled
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            var mods: UInt32 = 0
            if key.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
            if key.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
            if key.modifierFlags.contains(.alternate) { mods |= GHOSTTY_MODS_ALT.rawValue }
            if key.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
            let text = key.modifierFlags.contains(.control) ? nil : key.characters
            sendKey(usage: UInt32(key.keyCode.rawValue), text: text?.isEmpty == false ? text : nil,
                    mods: ghostty_input_mods_e(rawValue: mods),
                    unshifted: key.charactersIgnoringModifiers.first)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    // MARK: Clipboard (host side of ghostty's clipboard callbacks)

    func readClipboard(location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard let surface, location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
        let text = UIPasteboard.general.string ?? ""
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }

    func completeClipboard(_ text: String, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        guard let surface else { return }
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, confirmed) }
    }

    func paste(text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }
}
