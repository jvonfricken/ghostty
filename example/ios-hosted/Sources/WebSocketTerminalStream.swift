import Foundation

/// A terminal session over a WebSocket in Infinite's /terminal framing: the
/// opening text frame gives the size, binary frames carry bytes both ways,
/// `{"resize":{"cols","rows"}}` text frames resize, `{"exit":{...}}` ends.
/// Callbacks come on the main queue.
final class WebSocketTerminalStream {
    var onReceive: ((Data) -> Void)?
    var onEnd: ((String) -> Void)?

    private let url: URL
    private var task: URLSessionWebSocketTask?

    init(url: URL) { self.url = url }

    func open(columns: Int, rows: Int) {
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        sendJSON(["id": "demo", "columns": columns, "rows": rows, "term": "xterm-ghostty"])
        receive()
    }

    func send(_ data: Data) {
        task?.send(.data(data)) { error in
            if let error { NSLog("[demo] ws send failed: %@", "\(error)") }
        }
    }

    func resize(columns: Int, rows: Int) {
        sendJSON(["resize": ["cols": columns, "rows": rows]])
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error { NSLog("[demo] ws send failed: %@", "\(error)") }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(.data(let d)):
                    self.onReceive?(d)
                case .success(.string(let s)):
                    if s.contains("\"exit\"") { self.onEnd?(s); return }
                case .success:
                    break
                case .failure(let error):
                    self.onEnd?("\(error)")
                    return
                }
                self.receive()
            }
        }
    }
}
