import UIKit
import GhosttyKit

/// One ghostty_app_t for the process. Ghostty calls `wakeup_cb` from any
/// thread when its app mailbox has work; the app is ticked on the main queue
/// (coalesced), which is where surface actions and clipboard requests land.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var tickPending = false
    private let tickLock = NSLock()

    /// Surface-level actions the host cares about, by surface userdata.
    var onAction: ((ghostty_target_s, ghostty_action_s) -> Bool)?

    private init() {}

    func start(configText: String) {
        guard app == nil else { return }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        // Configuration comes from a file the host writes: there is no
        // ~/.config on iOS and the default files are not loaded.
        let config = ghostty_config_new()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty.conf")
        try? configText.write(to: url, atomically: true, encoding: .utf8)
        url.path.withCString { ghostty_config_load_file(config, $0) }
        ghostty_config_finalize(config)
        let diagnostics = ghostty_config_diagnostics_count(config)
        for i in 0..<diagnostics {
            let d = ghostty_config_get_diagnostic(config, i)
            NSLog("[demo] config diagnostic: %@", String(cString: d.message))
        }

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { ud in
            guard let ud else { return }
            Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue().scheduleTick()
        }
        rt.action_cb = { app, target, action in
            guard let ud = ghostty_app_userdata(app) else { return false }
            let rt = Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
            return rt.onAction?(target, action) ?? false
        }
        // Clipboard: the surface's userdata is its HostedTerminalView.
        rt.read_clipboard_cb = { ud, location, state in
            guard let ud else { return false }
            let view = Unmanaged<HostedTerminalView>.fromOpaque(ud).takeUnretainedValue()
            return view.readClipboard(location: location, state: state)
        }
        rt.confirm_read_clipboard_cb = { ud, text, state, _ in
            guard let ud, let text else { return }
            let view = Unmanaged<HostedTerminalView>.fromOpaque(ud).takeUnretainedValue()
            view.completeClipboard(String(cString: text), state: state, confirmed: true)
        }
        rt.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0, let data = content[0].data else { return }
            UIPasteboard.general.string = String(cString: data)
        }
        rt.close_surface_cb = { _, _ in }

        app = ghostty_app_new(&rt, config)
        ghostty_config_free(config)
        guard app != nil else { fatalError("ghostty_app_new failed") }
    }

    func scheduleTick() {
        tickLock.lock()
        let already = tickPending
        tickPending = true
        tickLock.unlock()
        if already { return }
        DispatchQueue.main.async { [self] in
            tickLock.lock(); tickPending = false; tickLock.unlock()
            if let app { ghostty_app_tick(app) }
        }
    }
}
