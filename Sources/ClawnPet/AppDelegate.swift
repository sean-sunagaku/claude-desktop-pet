import AppKit

/// 1 セッション分の追跡情報
final class SessionTrack {
    let sessionId: String
    let brain = PetBrain()
    var project: String?
    var lastEvent = Date()
    init(sessionId: String) { self.sessionId = sessionId }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var petView: PetView!
    private var chevron: NSButton!
    private let defaultBrain = PetBrain() // セッションが 1 つもない時のメイン表示
    private var tracks: [String: SessionTrack] = [:]
    private var pendingPrompts: [String: (String, Date)] = [:] // sessionId -> (text, at)
    private let speech = SpeechManager()

    private var animTimer: Timer?
    private var brainTimer: Timer?
    private var voicevoxTimer: Timer?
    private var lastFrame: CFTimeInterval = CACurrentMediaTime()

    private var transcriptWatcher: MultiTranscriptWatcher?
    private var historyWatcher: HistoryWatcher?
    private var desktopWatcher: DesktopLogWatcher?
    private var registry: SessionsRegistry?
    private var sessionsTimer: Timer?

    private var statusItem: NSStatusItem?
    private var statusMenuInfoItem: NSMenuItem?
    private var voiceMenuItems: [NSMenuItem] = []
    private var collapseMenuItem: NSMenuItem?

    private var demoTimer: Timer?
    private var demoIndex = 0
    private var cardOrder: [String] = [] // 表示中カードの sessionId（表示順）
    private var signalSource: DispatchSourceSignal?
    private var signalSource2: DispatchSourceSignal?

    private let debug = ProcessInfo.processInfo.environment["CLAWN_DEBUG"] == "1"
    private let windowWidth: CGFloat = 280

    private var cardsOn: Bool {
        get { UserDefaults.standard.bool(forKey: "clawn.cards") }
        set { UserDefaults.standard.set(newValue, forKey: "clawn.cards") }
    }

    private var collapsed: Bool {
        get { UserDefaults.standard.bool(forKey: "clawn.collapsed") }
        set { UserDefaults.standard.set(newValue, forKey: "clawn.collapsed") }
    }

    // MARK: - 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "clawn.voice": SpeechManager.Engine.voicevox.rawValue,
            "clawn.cards": true,
        ])
        setupWindow()
        setupStatusItem()
        setupWatchers()
        setupSignalHandler()
        startTimers()
        wireBrain(defaultBrain, track: nil)

        speech.checkVoicevox { [weak self] ok in self?.log("VOICEVOX alive=\(ok)") }

        if ProcessInfo.processInfo.environment["CLAWN_DEMO"] == "1" {
            startDemo()
        }
        log("ClawnPet started (pid \(ProcessInfo.processInfo.processIdentifier))")
    }

    private func setupWindow() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.maxX - windowWidth - 24, y: screen.minY + 24)
        let d = UserDefaults.standard
        if let x = d.object(forKey: "clawn.x") as? Double, let y = d.object(forKey: "clawn.y") as? Double {
            origin = NSPoint(x: x, y: y)
        }

        let size = NSSize(width: windowWidth, height: PetView.petAreaHeight)
        window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false // ドラッグは PetView が判定して performDrag する
        window.delegate = self

        petView = PetView(frame: NSRect(origin: .zero, size: size))
        petView.onRightClick = { [weak self] event in self?.showContextMenu(event) }
        petView.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.primaryBrain().handle(.assistantText(snippet: "なでてくれて ありがと🦀", project: nil))
            self.applyStatus()
        }
        petView.onClick = { [weak self] in self?.toggleCollapsed() }
        petView.onCardClick = { [weak self] idx in self?.jumpToSession(index: idx) }
        window.contentView = petView

        // セッションカードの開閉ボタン
        chevron = NSButton(title: "▴", target: self, action: #selector(toggleCards))
        chevron.isBordered = false
        chevron.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        chevron.contentTintColor = NSColor(red: 0.62, green: 0.29, blue: 0.18, alpha: 0.85)
        chevron.frame = NSRect(x: windowWidth - 40, y: 290, width: 28, height: 20)
        chevron.toolTip = "セッションカードの表示/非表示"
        petView.addSubview(chevron)

        applyStatus()
        window.orderFrontRegardless()
    }

    func windowDidMove(_ notification: Notification) {
        let o = window.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: "clawn.x")
        UserDefaults.standard.set(Double(o.y), forKey: "clawn.y")
    }

    // MARK: - セッション追跡・イベントルーティング

    private func primaryTrack() -> SessionTrack? {
        tracks.values.max { $0.lastEvent < $1.lastEvent }
    }

    private func primaryBrain() -> PetBrain {
        primaryTrack()?.brain ?? defaultBrain
    }

    private func wireBrain(_ brain: PetBrain, track: SessionTrack?) {
        brain.onChange = { [weak self] _ in self?.applyStatus() }
        brain.onSpeak = { [weak self, weak track] text, interrupt in
            guard let self else { return }
            var prefix = ""
            if self.tracks.count >= 2, let t = track {
                prefix = "\(t.project ?? "セッション")、"
            }
            self.speech.speak(prefix + text, interrupt: interrupt)
        }
    }

    private func track(for sessionId: String) -> SessionTrack {
        if let t = tracks[sessionId] { return t }
        let t = SessionTrack(sessionId: sessionId)
        wireBrain(t.brain, track: t)
        tracks[sessionId] = t
        log("track added: \(sessionId)")
        return t
    }

    private static func project(of event: PetEvent) -> String? {
        switch event {
        case .userPrompt(_, let p), .userMessage(let p), .toolUse(_, let p, _),
             .toolResult(let p), .assistantText(_, let p), .sessionSwitch(let p):
            return p
        default:
            return nil
        }
    }

    private func routeTranscript(_ sessionId: String, _ event: PetEvent) {
        let t = track(for: sessionId)
        t.lastEvent = Date()
        if let p = Self.project(of: event) { t.project = p }
        self.log("event[\(t.project ?? sessionId.prefix(8).description)]: \(event)")

        // history.jsonl のプロンプト本文が先に届いていたら昇格させる
        if case .userMessage(let proj) = event,
           let pending = pendingPrompts[sessionId],
           Date().timeIntervalSince(pending.1) < 15 {
            pendingPrompts.removeValue(forKey: sessionId)
            t.brain.handle(.userPrompt(text: pending.0, project: proj ?? t.project))
        } else {
            t.brain.handle(event)
        }
        applyStatus()
    }

    private func routePrompt(sessionId: String?, text: String, project: String?) {
        log("prompt[\(sessionId?.prefix(8).description ?? "-")]: \(PetBrain.trim(text, 30))")
        if let sid = sessionId {
            if let t = tracks[sid] {
                t.lastEvent = Date()
                if t.project == nil { t.project = project }
                t.brain.handle(.userPrompt(text: text, project: project ?? t.project))
            } else {
                // transcript がまだ追跡されていない新規セッション: 少し待って昇格させる
                pendingPrompts[sid] = (text, Date())
            }
        } else {
            primaryBrain().handle(.userPrompt(text: text, project: project))
        }
        applyStatus()
    }

    private func routeDesktop(_ event: PetEvent) {
        log("desktop event: \(event)")
        primaryBrain().handle(event)
        applyStatus()
    }

    // MARK: - セッションへジャンプ（カードクリック）

    private let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    /// claude://resume?session=<uuid> で Claude Desktop 上にそのセッションを開く
    private func jumpToSession(index: Int) {
        guard index < cardOrder.count else { return }
        let sid = cardOrder[index]
        let range = NSRange(sid.startIndex..., in: sid)
        guard uuidRegex.firstMatch(in: sid, range: range) != nil,
              let url = URL(string: "claude://resume?session=\(sid)") else {
            log("jump: not a claude session id: \(sid)")
            return
        }
        log("jump: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
        speech.speak("セッションをひらくよ！", interrupt: false)
    }

    // MARK: - メニューバー

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🦀"
        let menu = NSMenu()
        let info = NSMenuItem(title: "Clawn: 起動中", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        statusMenuInfoItem = info
        menu.addItem(.separator())

        // 音声エンジン選択
        let voiceMenu = NSMenu()
        let engines: [(String, SpeechManager.Engine)] = [
            ("オフ", .off), ("システム音声", .system), ("VOICEVOX（ずんだもん）", .voicevox),
        ]
        for (title, engine) in engines {
            let mi = NSMenuItem(title: title, action: #selector(setVoice(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = engine.rawValue
            voiceMenu.addItem(mi)
            voiceMenuItems.append(mi)
        }
        voiceMenu.addItem(.separator())
        let test = NSMenuItem(title: "こえテスト", action: #selector(voiceTest), keyEquivalent: "")
        test.target = self
        voiceMenu.addItem(test)
        let voiceRoot = NSMenuItem(title: "こえ（実況ボイス）", action: nil, keyEquivalent: "")
        menu.addItem(voiceRoot)
        menu.setSubmenu(voiceMenu, for: voiceRoot)

        let collapse = NSMenuItem(title: "とじる（ミニ表示）", action: #selector(toggleCollapsedMenu), keyEquivalent: "o")
        collapse.target = self
        menu.addItem(collapse)
        collapseMenuItem = collapse

        let cards = NSMenuItem(title: "セッションカード", action: #selector(toggleCards), keyEquivalent: "c")
        cards.target = self
        menu.addItem(cards)

        menu.addItem(.separator())
        menu.addItem(withTitle: "デモ再生（全モーション確認）", action: #selector(toggleDemo), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "スナップショット保存", action: #selector(saveSnapshot), keyEquivalent: "s").target = self
        menu.addItem(withTitle: "位置をリセット", action: #selector(resetPosition), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clawn を終了", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
        updateVoiceMenu()
    }

    private func updateVoiceMenu() {
        for mi in voiceMenuItems {
            mi.state = (mi.tag == speech.engine.rawValue) ? .on : .off
        }
    }

    private func showContextMenu(_ event: NSEvent) {
        guard let menu = statusItem?.menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: petView)
    }

    @objc private func setVoice(_ sender: NSMenuItem) {
        speech.engine = SpeechManager.Engine(rawValue: sender.tag) ?? .off
        updateVoiceMenu()
        if speech.engine == .voicevox {
            speech.checkVoicevox { [weak self] ok in
                self?.speech.speak(ok ? "ずんだもんで じっきょうするのだ！" : "ボイスボックスが みつからないから、システム音声で実況するね", interrupt: true)
            }
        } else if speech.engine == .system {
            speech.speak("システム音声で実況するね！", interrupt: true)
        }
    }

    @objc private func voiceTest() {
        speech.checkVoicevox { [weak self] _ in
            self?.speech.speak("こんにちは！クラウンだよ！きょうも いっしょに がんばろうね", interrupt: true)
        }
    }

    @objc private func toggleCards() {
        cardsOn.toggle()
        applyStatus()
    }

    @objc private func toggleCollapsedMenu() { toggleCollapsed() }

    private func toggleCollapsed() {
        collapsed.toggle()
        applyStatus()
    }

    @objc private func toggleDemo() {
        if demoTimer == nil { startDemo() } else { stopDemo() }
    }

    @objc private func saveSnapshot() {
        let url = snapshotURL()
        petView.snapshotPNG(to: url)
        log("snapshot saved: \(url.path)")
    }

    @objc private func resetPosition() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: screen.maxX - windowWidth - 24, y: screen.minY + 24))
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - ウォッチャー

    private func setupWatchers() {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser

        let projectsDir = env["CLAWN_WATCH_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude/projects")
        let historyFile = env["CLAWN_HISTORY"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude/history.jsonl")
        let mainLog = env["CLAWN_MAINLOG"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Logs/Claude/main.log")

        transcriptWatcher = MultiTranscriptWatcher(root: projectsDir) { [weak self] sid, event in
            self?.routeTranscript(sid, event)
        }
        historyWatcher = HistoryWatcher(file: historyFile) { [weak self] sid, text, project in
            self?.routePrompt(sessionId: sid, text: text, project: project)
        }
        desktopWatcher = DesktopLogWatcher(file: mainLog) { [weak self] event in
            self?.routeDesktop(event)
        }

        let reg = SessionsRegistry(dir: home.appendingPathComponent(".claude/sessions"))
        registry = reg
        sessionsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                reg.refresh()
                DispatchQueue.main.async { self?.applyStatus() }
            }
        }
        sessionsTimer?.fire()
    }

    // MARK: - タイマー

    private func startTimers() {
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.petView.tick(now - self.lastFrame)
            self.lastFrame = now
        }
        RunLoop.main.add(animTimer!, forMode: .common)

        brainTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.defaultBrain.tick()
            var pruned = false
            for (sid, t) in self.tracks {
                t.brain.tick()
                if t.lastEvent.timeIntervalSinceNow < -1800 {
                    self.tracks.removeValue(forKey: sid)
                    pruned = true
                }
            }
            for (sid, p) in self.pendingPrompts where p.1.timeIntervalSinceNow < -30 {
                self.pendingPrompts.removeValue(forKey: sid)
            }
            if pruned { self.log("tracks pruned -> \(self.tracks.count)") }
            self.applyStatus()
        }

        voicevoxTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.speech.checkVoicevox(nil)
        }
    }

    // MARK: - 表示反映

    private func applyStatus() {
        let sorted = tracks.values.sorted { $0.lastEvent > $1.lastEvent }
        let primary = sorted.first
        let status = (primary?.brain ?? defaultBrain).status

        petView.mood = status.mood
        petView.statusLine = status.statusLine
        petView.contextLine = status.contextLine

        cardOrder = sorted.prefix(6).map { $0.sessionId }
        petView.sessionCards = sorted.prefix(6).enumerated().map { i, t in
            SessionCard(
                title: t.project ?? registry?.name(for: t.sessionId) ?? String(t.sessionId.prefix(8)),
                statusLine: t.brain.status.statusLine,
                mood: t.brain.status.mood,
                ageText: PetBrain.ageText(t.lastEvent),
                isPrimary: i == 0
            )
        }
        petView.cardsVisible = cardsOn
        petView.collapsed = collapsed

        if let reg = registry, reg.aliveCount > 0 {
            petView.sessionsInfo = "session ×\(reg.aliveCount)"
        } else {
            petView.sessionsInfo = ""
        }
        statusMenuInfoItem?.title = "Clawn: \(status.statusLine)"
        collapseMenuItem?.title = collapsed ? "ひらく" : "とじる（ミニ表示）"
        chevron.title = cardsOn ? "▾" : "▴"
        chevron.isHidden = tracks.isEmpty || collapsed
        updateWindowLayout()
    }

    private func updateWindowLayout() {
        let target: NSSize
        if collapsed {
            target = PetView.collapsedSize
        } else {
            let n = cardsOn ? min(tracks.count, 6) : 0
            let h = PetView.petAreaHeight + (n > 0 ? CGFloat(n) * (PetView.cardHeight + PetView.cardGap) + 8 : 0)
            target = NSSize(width: windowWidth, height: h)
        }
        guard abs(window.frame.height - target.height) > 0.5 || abs(window.frame.width - target.width) > 0.5 else { return }
        var f = window.frame
        f.origin.x += f.size.width - target.width // 右端を固定して伸縮
        f.size = target
        if let vis = window.screen?.visibleFrame {
            if f.maxY > vis.maxY { f.origin.y = max(vis.minY, vis.maxY - f.height) }
            if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width }
            if f.origin.x < vis.minX { f.origin.x = vis.minX }
        }
        window.setFrame(f, display: true, animate: false)
    }

    // MARK: - デモ（全モーションを順に再生）

    private func startDemo() {
        demoIndex = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.demoStep()
        }
        demoTimer?.fire()
        log("demo started")
    }

    private func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        tracks.removeValue(forKey: "demo-session") // デモ用カードを片付ける
        applyStatus()
        log("demo stopped")
    }

    private func demoStep() {
        let steps: [PetEvent] = [
            .userPrompt(text: "Clawn くんのペットアプリを作って！", project: "demo"),
            .toolUse(name: "Bash", project: "demo", sidechain: false),
            .toolUse(name: "Edit", project: "demo", sidechain: false),
            .assistantText(snippet: "できたよ！ClawnPet が完成！", project: "demo"),
            .desktopSessionPaused,
        ]
        if demoIndex < steps.count {
            routeTranscript("demo-session", steps[demoIndex])
        }
        if demoIndex >= steps.count { stopDemo() }
        demoIndex += 1
    }

    // MARK: - スナップショット（SIGUSR1）/ デモトグル（SIGUSR2）

    private func snapshotURL() -> URL {
        if let p = ProcessInfo.processInfo.environment["CLAWN_SNAPSHOT_PATH"] {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("clawn_snapshot.png")
    }

    private func setupSignalHandler() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let url = self.snapshotURL()
            self.petView.snapshotPNG(to: url)
            self.log("SIGUSR1 -> snapshot: \(url.path) mood=\(self.primaryBrain().status.mood.rawValue) tracks=\(self.tracks.count)")
        }
        source.resume()
        signalSource = source

        signal(SIGUSR2, SIG_IGN)
        let demoSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        demoSource.setEventHandler { [weak self] in self?.toggleDemo() }
        demoSource.resume()
        signalSource2 = demoSource
    }

    // MARK: -

    private func log(_ message: String) {
        guard debug else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
    }
}
