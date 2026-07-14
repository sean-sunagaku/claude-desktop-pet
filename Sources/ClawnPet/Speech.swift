import AVFoundation
import Foundation

// MARK: - 音声実況（VOICEVOX 優先・システム音声フォールバック）

final class SpeechManager: NSObject {
    enum Engine: Int {
        case off = 0       // 喋らない
        case system = 1    // macOS 内蔵 (AVSpeechSynthesizer)
        case voicevox = 2  // ローカル VOICEVOX エンジン (http://127.0.0.1:50021)
    }

    var engine: Engine {
        get { Engine(rawValue: UserDefaults.standard.integer(forKey: "clawn.voice")) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "clawn.voice") }
    }

    /// VOICEVOX の話者 ID（3 = ずんだもん ノーマル）
    var voicevoxSpeaker: Int {
        get { let v = UserDefaults.standard.integer(forKey: "clawn.voice.speaker"); return v == 0 ? 3 : v }
        set { UserDefaults.standard.set(newValue, forKey: "clawn.voice.speaker") }
    }

    private(set) var voicevoxAlive = false
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var lastSpokeAt = Date.distantPast
    private let minInterval: TimeInterval = 7 // 連続発話の抑制
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        return URLSession(configuration: c)
    }()

    /// interrupt=true は再生中でも割り込んで必ず喋る（応答到着など）
    func speak(_ text: String, interrupt: Bool) {
        guard engine != .off, !text.isEmpty else { return }
        let now = Date()
        if !interrupt && now.timeIntervalSince(lastSpokeAt) < minInterval { return }
        lastSpokeAt = now
        if engine == .voicevox && voicevoxAlive {
            speakVoicevox(text)
        } else {
            speakSystem(text)
        }
    }

    /// VOICEVOX エンジンの死活確認（非同期）
    func checkVoicevox(_ completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "http://127.0.0.1:50021/version") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.2
        session.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                self?.voicevoxAlive = (data != nil)
                completion?(data != nil)
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

    private func speakVoicevox(_ text: String) {
        var query = URLComponents(string: "http://127.0.0.1:50021/audio_query")!
        query.queryItems = [
            URLQueryItem(name: "speaker", value: String(voicevoxSpeaker)),
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
            var synthURL = URLComponents(string: "http://127.0.0.1:50021/synthesis")!
            synthURL.queryItems = [URLQueryItem(name: "speaker", value: String(self.voicevoxSpeaker))]
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
