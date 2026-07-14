import Foundation

// MARK: - Claude Desktop の Web チャット監視（CDP / opt-in）
//
// Claude Desktop を `--remote-debugging-port=<port>` 付きで起動している場合のみ有効。
// /json でページを探し、WebSocket で Network ドメインを購読して completion リクエストの
// ライフサイクル（送信→ストリーミング→完了）を検知する。ポートが開いていなければ静かに無効。

final class CDPWatcher {
    /// (sessionId, event) — Web チャットは "web-cdp" 固定
    private let emit: (String, PetEvent) -> Void
    let port: Int
    private let webSessionId = "web-cdp"

    private var ws: URLSessionWebSocketTask?
    private var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        return URLSession(configuration: c)
    }()
    private var msgId = 0
    private var connected = false
    private var timer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "clawn.cdp", qos: .utility)

    private var inflight = Set<String>()   // completion 中の requestId
    private var pageTitle: String?
    private(set) var active = false        // Web チャットセッションが観測されているか

    init(port: Int, emit: @escaping (String, PetEvent) -> Void) {
        self.port = port
        self.emit = { sid, event in DispatchQueue.main.async { emit(sid, event) } }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 15)
        t.setEventHandler { [weak self] in self?.ensureConnected() }
        timer = t
        t.resume()
    }

    // MARK: 接続

    private func ensureConnected() {
        if connected { return }
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        session.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            // claude.ai を開いているページ、なければ最初の page ターゲットを選ぶ
            let page = list.first { ($0["url"] as? String)?.contains("claude.ai") == true }
                ?? list.first { ($0["type"] as? String) == "page" }
            guard let page, let wsURL = page["webSocketDebuggerUrl"] as? String, let u = URL(string: wsURL) else { return }
            self.pageTitle = page["title"] as? String
            self.openSocket(u)
        }.resume()
    }

    private func openSocket(_ url: URL) {
        let task = session.webSocketTask(with: url)
        ws = task
        connected = true
        task.resume()
        send(["id": nextId(), "method": "Network.enable"])
        send(["id": nextId(), "method": "Page.enable"])
        receiveLoop()
    }

    private func nextId() -> Int { msgId += 1; return msgId }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        ws?.send(.string(str)) { _ in }
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.connected = false
                self.ws = nil
                if self.active { self.active = false }
            case .success(let msg):
                if case .string(let s) = msg { self.handle(s) }
                self.receiveLoop()
            }
        }
    }

    // MARK: CDP イベント処理

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = obj["method"] as? String,
              let params = obj["params"] as? [String: Any] else { return }

        switch method {
        case "Network.requestWillBeSent":
            guard let req = params["request"] as? [String: Any],
                  let url = req["url"] as? String,
                  let requestId = params["requestId"] as? String else { return }
            if isCompletion(url) {
                inflight.insert(requestId)
                active = true
                emit(webSessionId, .toolUse(name: "__web_completion__", project: webProject(), sidechain: false))
            }
        case "Network.loadingFinished", "Network.loadingFailed":
            guard let requestId = params["requestId"] as? String, inflight.contains(requestId) else { return }
            inflight.remove(requestId)
            if method == "Network.loadingFinished" {
                emit(webSessionId, .assistantText(snippet: "Web チャットの応答が完了", project: webProject()))
            }
        case "Page.frameNavigated", "Page.navigatedWithinDocument":
            // タイトル更新のため再取得（軽量に /json を叩き直す）
            refreshTitle()
        default:
            break
        }
    }

    private func isCompletion(_ url: String) -> Bool {
        guard url.contains("claude.ai") || url.contains("anthropic.com") else { return false }
        return url.contains("/completion") || url.contains("/retry_completion")
    }

    private func webProject() -> String {
        if let t = pageTitle, !t.isEmpty, t != "Claude" {
            return "Web: " + String(t.prefix(18))
        }
        return "claude.ai"
    }

    private func refreshTitle() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
                  let page = list.first(where: { ($0["url"] as? String)?.contains("claude.ai") == true }) else { return }
            self.pageTitle = page["title"] as? String
        }.resume()
    }
}
