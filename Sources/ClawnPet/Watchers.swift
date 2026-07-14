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
        if leftover.count > 4_000_000 { leftover.removeAll() }
        return lines
    }
}

// MARK: - 共通: バックグラウンドでポーリングする土台

class PollingWatcher {
    let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    init(label: String, interval: TimeInterval) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        self.timer = t
        t.resume()
    }

    func poll() {} // override

    deinit { timer?.cancel() }
}

// MARK: - 全アクティブ transcript (~/.claude/projects/**/*.jsonl) の並行ウォッチャー

final class MultiTranscriptWatcher: PollingWatcher {
    /// (sessionId, event) — sessionId は transcript のファイル名（拡張子なし）
    private let emit: (String, PetEvent) -> Void
    private let root: URL
    /// アクティブとみなす transcript の更新期限（秒）
    private let activeWindow: TimeInterval = 1800
    private let maxSessions = 6

    private struct Tracked {
        let reader: TailReader
        var project: String?
    }

    private var tracked: [String: Tracked] = [:] // key = file path
    private var scanCounter = 0
    private let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoParserNoFrac = ISO8601DateFormatter()

    init(root: URL, emit: @escaping (String, PetEvent) -> Void) {
        self.root = root
        self.emit = { sid, event in DispatchQueue.main.async { emit(sid, event) } }
        super.init(label: "clawn.transcripts", interval: 1.0)
    }

    override func poll() {
        scanCounter += 1
        if tracked.isEmpty || scanCounter % 5 == 1 {
            rescan()
        }
        for (path, t) in tracked {
            let lines = t.reader.readNewLines()
            guard !lines.isEmpty else { continue }
            let sid = sessionId(ofPath: path)
            for line in lines { parse(line, path: path, sid: sid) }
        }
    }

    private func sessionId(ofPath path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// アクティブ（30分以内に更新）な transcript を最大 maxSessions 件追跡する
    private func rescan() {
        let fm = FileManager.default
        var candidates: [(path: String, mtime: Date)] = []
        let projDirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for dir in projDirs {
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for entry in entries where entry.pathExtension == "jsonl" {
                guard let m = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                if m.timeIntervalSinceNow > -activeWindow {
                    candidates.append((entry.path, m))
                }
            }
        }
        candidates.sort { $0.mtime > $1.mtime }
        let selected = Set(candidates.prefix(maxSessions).map { $0.path })

        // 追跡終了
        for path in tracked.keys where !selected.contains(path) {
            tracked.removeValue(forKey: path)
        }
        // 新規追跡（直近 16KB を遡って現状把握。20秒より古い行は parse 側で無視）
        for path in selected where tracked[path] == nil {
            let url = URL(fileURLWithPath: path)
            tracked[path] = Tracked(reader: TailReader(url: url, tailBytes: 16_384), project: nil)
            let sid = sessionId(ofPath: path)
            let lines = tracked[path]!.reader.readNewLines()
            for line in lines { parse(line, path: path, sid: sid) }
        }
    }

    private func parse(_ line: String, path: String, sid: String) {
        guard line.first == "{",
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return }

        // 古い行は無視（追跡開始直後の遡り読み対策）
        if let ts = obj["timestamp"] as? String {
            let date = isoParser.date(from: ts) ?? isoParserNoFrac.date(from: ts)
            if let d = date, d.timeIntervalSinceNow < -20 { return }
        }

        if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
            tracked[path]?.project = URL(fileURLWithPath: cwd).lastPathComponent
        }
        let project = tracked[path]?.project
        let sidechain = obj["isSidechain"] as? Bool ?? false
        let isMeta = obj["isMeta"] as? Bool ?? false
        guard let message = obj["message"] as? [String: Any] else { return }

        switch type {
        case "user":
            if isMeta { return }
            if let content = message["content"] as? String {
                if content.hasPrefix("<") { return } // <command-name> 等のシステム由来
                if !sidechain { emit(sid, .userMessage(project: project)) }
            } else if let items = message["content"] as? [[String: Any]] {
                if items.contains(where: { $0["type"] as? String == "tool_result" }) {
                    emit(sid, .toolResult(project: project))
                } else if !sidechain,
                          items.contains(where: { ($0["type"] as? String == "text") && !((($0["text"] as? String) ?? "").hasPrefix("<")) }) {
                    emit(sid, .userMessage(project: project))
                }
            }
        case "assistant":
            guard let items = message["content"] as? [[String: Any]] else { return }
            for item in items {
                switch item["type"] as? String {
                case "tool_use":
                    if let name = item["name"] as? String {
                        emit(sid, .toolUse(name: name, project: project, sidechain: sidechain))
                    }
                case "text":
                    if let text = item["text"] as? String,
                       text.trimmingCharacters(in: .whitespacesAndNewlines).count > 2,
                       !sidechain {
                        emit(sid, .assistantText(snippet: text, project: project))
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
    /// (sessionId, プロンプト本文, プロジェクト名)
    private let emitPrompt: (String?, String, String?) -> Void
    private var reader: TailReader?
    private let file: URL

    init(file: URL, emitPrompt: @escaping (String?, String, String?) -> Void) {
        self.file = file
        self.emitPrompt = { sid, text, proj in DispatchQueue.main.async { emitPrompt(sid, text, proj) } }
        super.init(label: "clawn.history", interval: 1.0)
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
            let sid = obj["sessionId"] as? String
            emitPrompt(sid, display, project)
        }
    }
}

// MARK: - Claude Desktop 本体ログ (~/Library/Logs/Claude/main.log) ウォッチャー

final class DesktopLogWatcher: PollingWatcher {
    private let emit: (PetEvent) -> Void
    private var reader: TailReader?
    private let file: URL
    private var lastLine = ""
    private var lastLineAt = Date.distantPast

    private let sendRegex = try! NSRegularExpression(pattern: #"LocalSessions\.sendMessage: sessionId=[^,]+, messageLength=(\d+)"#)

    init(file: URL, emit: @escaping (PetEvent) -> Void) {
        self.file = file
        self.emit = { event in DispatchQueue.main.async { emit(event) } }
        super.init(label: "clawn.desktoplog", interval: 1.0)
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
    /// sessionId -> 表示名
    private(set) var names: [String: String] = [:]

    init(dir: URL) { self.dir = dir }

    func refresh() {
        let fm = FileManager.default
        var count = 0
        var names: [String: String] = [:]
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = obj["pid"] as? Int else { continue }
            if kill(pid_t(pid), 0) == 0 { // プロセス生存確認
                count += 1
                if let sid = obj["sessionId"] as? String, let name = obj["name"] as? String {
                    names[sid] = name
                }
            }
        }
        aliveCount = count
        self.names = names
    }

    func name(for sessionId: String) -> String? { names[sessionId] }
}
