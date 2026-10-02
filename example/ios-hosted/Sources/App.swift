import UIKit
import GhosttyKit

func say(_ s: String) { NSLog("[demo] %@", s) }

/// Launch arguments:
///   -ws <url>        WebSocket to connect to (default ws://127.0.0.1:8765/terminal)
///   -scenario 1      run the scripted input/resize scenario (for tests)
final class TerminalViewController: UIViewController {
    let term = HostedTerminalView(frame: .zero)
    var stream: WebSocketTerminalStream?
    var heightConstraint: NSLayoutConstraint!
    private var opened = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // Lighter than the terminal, so the resize shows where it ends.
        view.backgroundColor = UIColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1)
        term.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(term)
        let safe = view.safeAreaLayoutGuide
        heightConstraint = term.heightAnchor.constraint(equalTo: safe.heightAnchor, multiplier: 1)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: safe.topAnchor),
            term.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            heightConstraint,
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard term.surface == nil else { return }
        term.attach(fontSize: 13)
        let args = UserDefaults.standard
        let url = URL(string: args.string(forKey: "ws") ?? "ws://127.0.0.1:8765/terminal")!
        let stream = WebSocketTerminalStream(url: url)
        self.stream = stream
        stream.onReceive = { [weak self] data in self?.term.feed(data) }
        stream.onEnd = { say("stream ended: \($0)") }
        term.onOutput = { [weak self] data in
            say("terminal emitted \(data.count) bytes: \(data.map { String(format: "%02x", $0) }.joined())")
            self?.stream?.send(data)
        }
        term.onResize = { [weak self] cols, rows in
            guard let self else { return }
            say("grid \(cols)x\(rows)")
            if !self.opened {
                self.opened = true
                stream.open(columns: cols, rows: rows)
            } else {
                stream.resize(columns: cols, rows: rows)
            }
        }
        // The scripted scenario types through the same calls the keyboard
        // uses, without raising the on-screen keyboard.
        if args.integer(forKey: "scenario") == 1 { runScenario() } else { term.becomeFirstResponder() }
    }

    /// Typed input through the same paths a user's keyboard takes, then a
    /// query whose reply comes from Ghostty itself, then a resize.
    func runScenario() {
        let t = term
        func at(_ s: Double, _ f: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
        }
        at(2.0) {
            say("scenario: typing via UIKeyInput")
            t.insertText("echo héllo ✓")
            t.deleteBackward()           // drop the ✓
            t.insertText("ok\n")
        }
        at(2.6) {
            say("scenario: ctrl-c and arrow-up via hardware-style key events")
            _ = t.sendKey(usage: 0x06, text: nil, mods: GHOSTTY_MODS_CTRL, unshifted: "c")  // ctrl-c
            _ = t.sendKey(usage: 0x52, text: nil)                                         // arrow up
        }
        at(3.0) {
            say("scenario: DA1 query from the host, the reply comes from ghostty")
            t.feed(Data("\u{1b}[c".utf8))
        }
        at(4.0) {
            say("screen text: \(t.screenText().debugDescription)")
            say("scenario: READY-1")
        }
        at(6.0) {
            say("scenario: resizing the view to 55% height")
            self.heightConstraint.isActive = false
            self.heightConstraint = t.heightAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.55)
            self.heightConstraint.isActive = true
        }
        at(7.5) {
            let g = t.gridSize
            say("grid after resize \(g.columns)x\(g.rows)")
            say("scenario: READY-2")
        }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        GhosttyRuntime.shared.start(configText: """
        font-size = 13
        cursor-style = block
        cursor-style-blink = false
        window-padding-x = 4
        window-padding-y = 4
        background = #15171c
        foreground = #d8dee9
        """)
        GhosttyRuntime.shared.onAction = { _, action in
            say("action \(action.tag.rawValue)")
            return false
        }
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = TerminalViewController()
        window?.makeKeyAndVisible()
        return true
    }
}
