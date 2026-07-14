import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var petView: PetView!
    private let brain = PetBrain()
    private var animTimer: Timer?
    private var brainTimer: Timer?
    private var lastFrame: CFTimeInterval = CACurrentMediaTime()

    private var ccWatcher: ClaudeCodeWatcher?
    private var historyWatcher: HistoryWatcher?
    private var desktopWatcher: DesktopLogWatcher?
    private var sessions: SessionsRegistry?
    private var sessionsTimer: Timer?

    private var statusItem: NSStatusItem?
    private var statusMenuInfoItem: NSMenuItem?

    private var demoTimer: Timer?
    private var demoIndex = 0
    private var signalSource: DispatchSourceSignal?
    private var signalSource2: DispatchSourceSignal?

    private let debug = ProcessInfo.processInfo.environment["CLAWN_DEBUG"] == "1"
    private let windowSize = NSSize(width: 280, height: 320)

    // MARK: - 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupStatusItem()
        setupWatchers()
        setupSignalHandler()
        startTimers()

        if ProcessInfo.processInfo.environment["CLAWN_DEMO"] == "1" {
            startDemo()
        }
        log("ClawnPet started (pid \(ProcessInfo.processInfo.processIdentifier))")
    }

    private func setupWindow() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.maxX - windowSize.width - 24, y: screen.minY + 24)
        // 保存された位置を復元
        let d = UserDefaults.standard
        if let x = d.object(forKey: "clawn.x") as? Double, let y = d.object(forKey: "clawn.y") as? Double {
            origin = NSPoint(x: x, y: y)
        }

        window = NSWindow(contentRect: NSRect(origin: origin, size: windowSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.delegate = self

        petView = PetView(frame: NSRect(origin: .zero, size: windowSize))
        petView.onRightClick = { [weak self] event in self?.showContextMenu(event) }
        petView.onDoubleClick = { [weak self] in
            self?.brain.handle(.assistantText(snippet: "なでてくれて ありがと🦀", project: nil))
            self?.applyStatus()
        }
        window.contentView = petView

        brain.onChange = { [weak self] _ in self?.applyStatus() }
        applyStatus()
        window.orderFrontRegardless()
    }

    func windowDidMove(_ notification: Notification) {
        let o = window.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: "clawn.x")
        UserDefaults.standard.set(Double(o.y), forKey: "clawn.y")
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
        menu.addItem(withTitle: "デモ再生（全モーション確認）", action: #selector(toggleDemo), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "スナップショット保存", action: #selector(saveSnapshot), keyEquivalent: "s").target = self
        menu.addItem(withTitle: "位置をリセット", action: #selector(resetPosition), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clawn を終了", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    private func showContextMenu(_ event: NSEvent) {
        guard let menu = statusItem?.menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: petView)
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
        window.setFrameOrigin(NSPoint(x: screen.maxX - windowSize.width - 24, y: screen.minY + 24))
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

        let handler: (PetEvent) -> Void = { [weak self] event in
            guard let self else { return }
            self.log("event: \(event)")
            self.brain.handle(event)
            self.applyStatus()
        }

        ccWatcher = ClaudeCodeWatcher(root: projectsDir, emit: handler)
        historyWatcher = HistoryWatcher(file: historyFile, emit: handler)
        desktopWatcher = DesktopLogWatcher(file: mainLog, emit: handler)

        let registry = SessionsRegistry(dir: home.appendingPathComponent(".claude/sessions"))
        sessions = registry
        sessionsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                registry.refresh()
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
            self?.brain.tick()
            self?.applyStatus()
        }
    }

    private func applyStatus() {
        let s = brain.status
        petView.mood = s.mood
        petView.statusLine = s.statusLine
        petView.contextLine = s.contextLine
        if let reg = sessions, reg.aliveCount > 0 {
            petView.sessionsInfo = "session ×\(reg.aliveCount)"
        } else {
            petView.sessionsInfo = ""
        }
        statusMenuInfoItem?.title = "Clawn: \(s.statusLine)"
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
        log("demo stopped")
    }

    private func demoStep() {
        let steps: [PetEvent] = [
            .userPrompt(text: "Clawn くんのペットアプリを作って！", project: "pet"),
            .toolUse(name: "Bash", project: "pet", sidechain: false),
            .toolUse(name: "Edit", project: "pet", sidechain: false),
            .assistantText(snippet: "できたよ！ClawnPet が完成！", project: "pet"),
            .desktopSessionPaused,
        ]
        if demoIndex < steps.count {
            brain.handle(steps[demoIndex])
        } else if demoIndex == steps.count {
            // 眠りのデモは直接気分を上書きできないため sleeping 相当の見た目にする
            brain.handle(.desktopSessionPaused)
        }
        applyStatus()
        if demoIndex == steps.count { stopDemo() }
        demoIndex += 1
    }

    // MARK: - スナップショット（SIGUSR1）

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
            self.log("SIGUSR1 -> snapshot: \(url.path) mood=\(self.brain.status.mood.rawValue) status=\(self.brain.status.statusLine)")
        }
        source.resume()
        signalSource = source

        // SIGUSR2 でデモの開始/停止をトグル（外部からの動作確認用）
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
