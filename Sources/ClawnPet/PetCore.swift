import Foundation

// MARK: - ペットの気分（状態マシンの状態）

enum PetMood: String {
    case idle        // 待機
    case thinking    // ユーザーがメッセージを送って考え中
    case working     // ツール実行中（コーディング作業中）
    case celebrating // 返答が来た！
    case sleeping    // しばらく何もない
}

// MARK: - ウォッチャーが発するイベント

enum PetEvent {
    case userPrompt(text: String, project: String?)        // history.jsonl: ユーザーがプロンプト送信
    case userMessage(project: String?)                      // transcript: user 行（テキスト）
    case toolUse(name: String, project: String?, sidechain: Bool) // transcript: tool_use
    case toolResult(project: String?)                       // transcript: tool_result
    case assistantText(snippet: String, project: String?)   // transcript: アシスタントの本文
    case desktopSendMessage(length: Int)                    // main.log: Desktop からの送信
    case desktopSessionPaused                               // main.log: セッション一時停止
    case desktopWindowFocused                               // main.log: ウィンドウフォーカス
    case sessionSwitch(project: String?)                    // 監視対象 transcript の切替
}

// MARK: - 表示ステータス

struct PetStatus {
    var mood: PetMood = .idle
    var statusLine: String = "こんにちは！Clawn だよ"
    var contextLine: String = "Claude の作業を見守るね"
}

// MARK: - 状態マシン

final class PetBrain {
    private(set) var status = PetStatus()
    private var lastEventAt = Date()
    private var moodChangedAt = Date()
    private var thinkingSince: Date?
    var onChange: ((PetStatus) -> Void)?

    // 調整パラメータ
    private let celebrateDuration: TimeInterval = 7
    private let sleepAfter: TimeInterval = 480      // 8分イベントなしで就寝
    private let thinkingTimeout: TimeInterval = 900 // 15分応答なしなら待機に戻る

    private func set(_ mood: PetMood, _ statusLine: String, _ contextLine: String) {
        let moodChanged = (status.mood != mood)
        status.mood = mood
        status.statusLine = statusLine
        status.contextLine = contextLine
        if moodChanged { moodChangedAt = Date() }
        onChange?(status)
    }

    private func projectTag(_ project: String?) -> String {
        guard let p = project, !p.isEmpty else { return "" }
        return "[\(p)] "
    }

    func handle(_ event: PetEvent) {
        lastEventAt = Date()
        switch event {
        case .userPrompt(let text, let project):
            thinkingSince = Date()
            let t = Self.trim(text, 30)
            set(.thinking, "うーん、かんがえ中", projectTag(project) + "「\(t)」")
        case .userMessage(let project):
            // history.jsonl 側が本文付きで拾うので、こちらは thinking への遷移だけ担保
            if status.mood != .thinking {
                thinkingSince = Date()
                set(.thinking, "うーん、かんがえ中", projectTag(project) + "メッセージを受けとったよ")
            }
        case .toolUse(let name, let project, let sidechain):
            thinkingSince = nil
            let label = Self.toolLabel(name)
            let sub = sidechain ? "(サブエージェント) " : ""
            set(.working, "\(label)中", sub + projectTag(project) + "カタカタ🦀")
        case .toolResult:
            break // working 継続
        case .assistantText(let snippet, let project):
            thinkingSince = nil
            set(.celebrating, "へんじが きたよ！", projectTag(project) + "「\(Self.trim(snippet, 32))」")
        case .desktopSendMessage(let length):
            thinkingSince = Date()
            set(.thinking, "うーん、かんがえ中", "Desktop から \(length) 文字そうしん！")
        case .desktopSessionPaused:
            if status.mood == .working || status.mood == .thinking {
                thinkingSince = nil
                set(.idle, "ひとやすみ〜", "セッションが一段落したよ")
            }
        case .desktopWindowFocused:
            if status.mood == .sleeping {
                set(.idle, "おはよう！", "Claude Desktop がひらいたよ")
            }
        case .sessionSwitch(let project):
            if let p = project, !p.isEmpty, status.mood == .idle || status.mood == .sleeping {
                set(.idle, "みてるよ〜", "[\(p)] のセッションを見守り中")
            }
        }
    }

    /// 定期呼び出し（気分の自動遷移）
    func tick() {
        let now = Date()
        switch status.mood {
        case .celebrating:
            if now.timeIntervalSince(moodChangedAt) > celebrateDuration {
                set(.idle, "まったり中〜", "つぎのおしごと待ち")
            }
        case .thinking:
            if let since = thinkingSince, now.timeIntervalSince(since) > thinkingTimeout {
                thinkingSince = nil
                set(.idle, "まったり中〜", "つぎのおしごと待ち")
            }
        case .idle:
            if now.timeIntervalSince(lastEventAt) > sleepAfter {
                set(.sleeping, "すやすや…", "イベントが来たら起きるよ")
            }
        case .sleeping, .working:
            // working は次のイベント（assistantText 等）で解除される
            // 長時間 working のまま止まった場合の保険
            if status.mood == .working, now.timeIntervalSince(lastEventAt) > sleepAfter {
                set(.idle, "あれ、おわったのかな？", "しばらく動きがないみたい")
            }
        }
    }

    // MARK: - ヘルパー

    static func trim(_ s: String, _ max: Int) -> String {
        let cleaned = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= max { return cleaned }
        return String(cleaned.prefix(max)) + "…"
    }

    static func toolLabel(_ name: String) -> String {
        switch name {
        case "Bash": return "ターミナルで作業"
        case "Read": return "ファイルをよみよみ"
        case "Edit", "Write", "NotebookEdit": return "コードをカキカキ"
        case "Grep", "Glob": return "コードをさがし"
        case "Task", "Agent": return "サブエージェントに おねがい"
        case "WebFetch", "WebSearch": return "Web でしらべもの"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList": return "タスクをせいり"
        case "AskUserQuestion": return "しつもんを準備"
        case "SendMessage": return "メッセージを送信"
        case "Workflow": return "ワークフローを実行"
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_").filter { !$0.isEmpty }
                let last = parts.last.map(String.init) ?? name
                return "\(last) を実行"
            }
            return "\(name) を実行"
        }
    }
}
