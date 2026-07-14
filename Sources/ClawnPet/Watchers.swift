import Foundation

// MARK: - ファイル追記を差分で読むリーダー（ローテーション対応）

final class TailReader {
    let url: URL
    private var offset: UInt64
    private var leftover = Data()

    /// tailBytes > 0 なら末尾からその分だけ遡って開始（起動直後に直近の状態を拾う用）
    init(url: URL, tailBytes: UInt64 = 0) {
        self.url = url
        let size = TailReader.fileSize(url)
        self.offset = size > tailBytes ? size - tailBytes : 0
    }

    static func fileSize(_ url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// 新しく追記された「完全な行」を返す
    func readNewLines(maxBytes: Int = 2_000_000) -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { // ローテーション/トランケート
            offset = 0
            leftover.removeAll()
        }
        guard size > offset else { return [] }
        try? fh.seek(toOffset: offset)
        let toRead = min(Int(size - offset), maxBytes)
        guard let data = try? fh.read(upToCount: toRead), !data.isEmpty else { return [] }
        offset += UInt64(data.count)

        var buf = leftover
        buf.append(data)
        var lines: [String] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let lineData = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                lines.append(s)
            }
        }
        leftover = buf
        // 行が終わらないまま溜まりすぎたら捨てる（バイナリ等の保険）
        if leftover.count > 4_000_000 { leftover.removeAll() }
        return lines
    }
}

// MARK: - 共通: バックグラウンドでポーリングして main にイベントを流す土台

class PollingWatcher {
    let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    let emit: (PetEvent) -> Void

    init(label: String, interval: TimeInterval, emit: @escaping (PetEvent) -> Void) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.emit = { event in DispatchQueue.main.async { emit(event) } }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        self.timer = t
        t.resume()
    }

    func poll() {} // override

    deinit { timer?.cancel() }
}

// MARK: - Claude Code transcript (~/.claude/projects/**/*.jsonl) ウォッチャー

final class ClaudeCodeWatcher: PollingWatcher {
    private let root: URL
    private var reader: TailReader?
    private var activeFile: URL?
    private var scanCounter = 0
    private var currentProject: String?
    private let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoParserNoFrac = ISO8601DateFormatter()

    /// 自分自身（ClawnPet を作っているセッション等）を除外したい場合に設定
    var ignoreSessionIds: Set<String> = []

    init(root: URL, emit: @escaping (PetEvent) -> Void) {
        self.root = root
        super.init(label: "clawn.ccwatcher", interval: 1.0, emit: emit)
    }

    override func poll() {
        scanCounter += 1
        if activeFile == nil || scanCounter % 5 == 1 {
            scanForNewestTranscript()
        }
        guard let reader else { return }
        let lines = reader.readNewLines()
        for line in lines { parse(line) }
    }

    /// projects/<proj>/**.jsonl を走査して直近更新のファイルを選ぶ（深さ2まで）
    private func scanForNewestTranscript() {
        let fm = FileManager.default
        var newest: (url: URL, mtime: Date)? = nil
        let projDirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for dir in projDirs {
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                if entry.pathExtension == "jsonl" {
                    if let m = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                        if newest == nil || m > newest!.mtime { newest = (entry, m) }
                    }
                }
            }
        }
        guard let best = newest else { return }
        // 24時間以上前のファイルしかないなら監視しない
        guard best.mtime.timeIntervalSinceNow > -86_400 else { return }
        let sessionId = best.url.deletingPathExtension().lastPathComponent
        if ignoreSessionIds.contains(sessionId) { return }
        if activeFile != best.url {
            activeFile = best.url
            // 切替時: 直近 32KB を遡って読み、20秒以内のイベントだけ発火する
            reader = TailReader(url: best.url, tailBytes: 32_768)
            currentProject = nil
            emit(.sessionSwitch(project: currentProject))
        }
    }

    private func parse(_ line: String) {
        guard line.first == "{",
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return }

        // 古い行は無視（ファイル切替直後の遡り読み対策）
        if let ts = obj["timestamp"] as? String {
            let date = isoParser.date(from: ts) ?? isoParserNoFrac.date(from: ts)
            if let d = date, d.timeIntervalSinceNow < -20 { return }
        }

        if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
            currentProject = URL(fileURLWithPath: cwd).lastPathComponent
        }
        let sidechain = obj["isSidechain"] as? Bool ?? false
        let isMeta = obj["isMeta"] as? Bool ?? false
        guard let message = obj["message"] as? [String: Any] else { return }

        switch type {
        case "user":
            if isMeta { return }
            if let content = message["content"] as? String {
                // <command-name> 等のシステム由来テキストは除外
                if content.hasPrefix("<") { return }
                if !sidechain { emit(.userMessage(project: currentProject)) }
            } else if let items = message["content"] as? [[String: Any]] {
                if items.contains(where: { $0["type"] as? String == "tool_result" }) {
                    emit(.toolResult(project: currentProject))
                } else if !sidechain,
                          items.contains(where: { ($0["type"] as? String == "text") && !((($0["text"] as? String) ?? "").hasPrefix("<")) }) {
                    emit(.userMessage(project: currentProject))
                }
            }
        case "assistant":
            guard let items = message["content"] as? [[String: Any]] else { return }
            for item in items {
                switch item["type"] as? String {
                case "tool_use":
                    if let name = item["name"] as? String {
                        emit(.toolUse(name: name, project: currentProject, sidechain: sidechain))
                    }
                case "text":
                    if let text = item["text"] as? String,
                       text.trimmingCharacters(in: .whitespacesAndNewlines).count > 2,
                       !sidechain {
                        emit(.assistantText(snippet: text, project: currentProject))
                    }
                default: break
                }
            }
        default:
            break
        }
    }
}

// MARK: - ユーザープロンプト履歴 (~/.claude/history.jsonl) ウォッチャー

final class HistoryWatcher: PollingWatcher {
    private var reader: TailReader?
    private let file: URL

    init(file: URL, emit: @escaping (PetEvent) -> Void) {
        self.file = file
        super.init(label: "clawn.history", interval: 1.0, emit: emit)
    }

    override func poll() {
        if reader == nil {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            reader = TailReader(url: file) // 末尾から開始（過去分は再生しない）
        }
        for line in reader!.readNewLines() {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let display = obj["display"] as? String else { continue }
            let project = (obj["project"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            emit(.userPrompt(text: display, project: project))
        }
    }
}

// MARK: - Claude Desktop 本体ログ (~/Library/Logs/Claude/main.log) ウォッチャー

final class DesktopLogWatcher: PollingWatcher {
    private var reader: TailReader?
    private let file: URL
    private var lastLine = ""
    private var lastLineAt = Date.distantPast

    private let sendRegex = try! NSRegularExpression(pattern: #"LocalSessions\.sendMessage: sessionId=[^,]+, messageLength=(\d+)"#)

    init(file: URL, emit: @escaping (PetEvent) -> Void) {
        self.file = file
        super.init(label: "clawn.desktoplog", interval: 1.0, emit: emit)
    }

    override func poll() {
        if reader == nil {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            reader = TailReader(url: file)
        }
        for line in reader!.readNewLines() {
            // main.log は同一行が二重に出るので 2 秒以内の同一行は無視
            let now = Date()
            if line == lastLine && now.timeIntervalSince(lastLineAt) < 2 { continue }
            lastLine = line
            lastLineAt = now

            let range = NSRange(line.startIndex..., in: line)
            if let m = sendRegex.firstMatch(in: line, range: range),
               let lenRange = Range(m.range(at: 1), in: line),
               let len = Int(line[lenRange]) {
                emit(.desktopSendMessage(length: len))
            } else if line.contains("[CCD] Pausing session") {
                emit(.desktopSessionPaused)
            } else if line.contains("Window focused") {
                emit(.desktopWindowFocused)
            }
        }
    }
}

// MARK: - 稼働中セッションレジストリ (~/.claude/sessions/*.json)

final class SessionsRegistry {
    private let dir: URL
    private(set) var aliveCount = 0
    private(set) var names: [String] = []

    init(dir: URL) { self.dir = dir }

    func refresh() {
        let fm = FileManager.default
        var count = 0
        var names: [String] = []
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = obj["pid"] as? Int else { continue }
            if kill(pid_t(pid), 0) == 0 { // プロセス生存確認
                count += 1
                if let name = obj["name"] as? String { names.append(name) }
            }
        }
        aliveCount = count
        self.names = names
    }
}
