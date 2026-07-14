import AVFoundation
import Foundation

// MARK: - 音声実況（VOICEVOX 優先・システム音声フォールバック）

final class SpeechManager: NSObject {
    enum Engine: Int {
        case off = 0       // 喋らない
        case system = 1    // macOS 内蔵 (AVSpeechSynthesizer)
        case voicevox = 2  // ローカル VOICEVOX エンジン (http://127.0.0.1:50021)
    }

    private let base = "http://127.0.0.1:50021"

    var engine: Engine {
        get { Engine(rawValue: UserDefaults.standard.integer(forKey: "clawn.voice")) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "clawn.voice") }
    }

    /// VOICEVOX の既定話者 ID（3 = ずんだもん ノーマル）
    var voicevoxSpeaker: Int {
        get { let v = UserDefaults.standard.integer(forKey: "clawn.voice.speaker"); return v == 0 ? 3 : v }
        set { UserDefaults.standard.set(newValue, forKey: "clawn.voice.speaker") }
    }

    /// セッション（プロジェクト）ごとに声を変えるか
    var perProjectVoice: Bool {
        get { UserDefaults.standard.object(forKey: "clawn.voice.perProject") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clawn.voice.perProject") }
    }

    private(set) var voicevoxAlive = false
    /// /speakers から得た「ノーマル」系スタイル ID のプール（プロジェクト割り当て用）
    private(set) var speakerPool: [Int] = [3, 2, 8, 13, 14, 16, 11, 9]
    /// スタイル ID → 話者名（実況ログ・デバッグ用）
    private(set) var speakerNames: [Int: String] = [:]

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var lastSpokeAt = Date.distantPast
    private let minInterval: TimeInterval = 7 // 連続発話の抑制
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        return URLSession(configuration: c)
    }()

    /// プロジェクト名から決定的に担当話者を選ぶ
    func speaker(for project: String?) -> Int {
        guard perProjectVoice, let p = project, !p.isEmpty, !speakerPool.isEmpty else {
            return voicevoxSpeaker
        }
        var hash: UInt64 = 1469598103934665603 // FNV-1a
        for b in p.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        return speakerPool[Int(hash % UInt64(speakerPool.count))]
    }

    func speakerName(_ id: Int) -> String { speakerNames[id] ?? "話者\(id)" }

    /// interrupt=true は再生中でも割り込んで必ず喋る（応答到着など）
    func speak(_ text: String, interrupt: Bool, project: String? = nil) {
        guard engine != .off, !text.isEmpty else { return }
        let now = Date()
        if !interrupt && now.timeIntervalSince(lastSpokeAt) < minInterval { return }
        lastSpokeAt = now
        if engine == .voicevox && voicevoxAlive {
            speakVoicevox(text, speaker: speaker(for: project))
        } else {
            speakSystem(text)
        }
    }

    /// VOICEVOX エンジンの死活確認 + 話者プールの取得（非同期）
    func checkVoicevox(_ completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(base)/version") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.2
        session.dataTask(with: req) { [weak self] data, _, _ in
            let alive = (data != nil)
            DispatchQueue.main.async {
                self?.voicevoxAlive = alive
                completion?(alive)
            }
            if alive { self?.loadSpeakers() }
        }.resume()
    }

    /// /speakers から各話者の「ノーマル/ふつう」系スタイルを 1 つずつ集めてプール化
    private func loadSpeakers() {
        guard speakerNames.isEmpty, let url = URL(string: "\(base)/speakers") else { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            var pool: [Int] = []
            var names: [Int: String] = [:]
            for sp in arr {
                guard let name = sp["name"] as? String,
                      let styles = sp["styles"] as? [[String: Any]] else { continue }
                // 「ノーマル」「ふつう」を優先、なければ先頭スタイル
                let chosen = styles.first { ($0["name"] as? String) == "ノーマル" || ($0["name"] as? String) == "ふつう" } ?? styles.first
                if let st = chosen, let id = st["id"] as? Int {
                    pool.append(id)
                    names[id] = name
                }
                for st in styles { if let id = st["id"] as? Int, let n = sp["name"] as? String { names[id] = n } }
            }
            DispatchQueue.main.async {
                if !pool.isEmpty { self.speakerPool = pool }
                self.speakerNames = names
            }
        }.resume()
    }

    // MARK: - システム音声

    private func speakSystem(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        u.rate = 0.52
        u.pitchMultiplier = 1.25
        synth.speak(u)
    }

    // MARK: - VOICEVOX

    private func speakVoicevox(_ text: String, speaker: Int) {
        var query = URLComponents(string: "\(base)/audio_query")!
        query.queryItems = [
            URLQueryItem(name: "speaker", value: String(speaker)),
            URLQueryItem(name: "text", value: text),
        ]
        var q = URLRequest(url: query.url!)
        q.httpMethod = "POST"
        session.dataTask(with: q) { [weak self] data, resp, _ in
            guard let self else { return }
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async { self.voicevoxAlive = false; self.speakSystem(text) }
                return
            }
            var synthURL = URLComponents(string: "\(self.base)/synthesis")!
            synthURL.queryItems = [URLQueryItem(name: "speaker", value: String(speaker))]
            var s = URLRequest(url: synthURL.url!)
            s.httpMethod = "POST"
            s.setValue("application/json", forHTTPHeaderField: "Content-Type")
            s.httpBody = data
            self.session.dataTask(with: s) { wav, resp2, _ in
                guard let wav, (resp2 as? HTTPURLResponse)?.statusCode == 200 else {
                    DispatchQueue.main.async { self.speakSystem(text) }
                    return
                }
                DispatchQueue.main.async {
                    self.player?.stop()
                    self.player = try? AVAudioPlayer(data: wav)
                    self.player?.play()
                }
            }.resume()
        }.resume()
    }
}
