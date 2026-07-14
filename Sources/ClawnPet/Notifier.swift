import Foundation
import UserNotifications

// MARK: - 応答完了の通知（通知センター連携）

/// UNUserNotificationCenter を第一候補に、使えない環境では osascript にフォールバックする。
/// ClawnPet は LSUIElement + ad-hoc 署名なので、環境により通知許可が下りないことがある。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "clawn.notify") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clawn.notify") }
    }

    /// 通知タップで開くセッションを解決するためのコールバック（title → sessionId）
    var resolveSession: ((String) -> String?)?
    var onOpenSession: ((String) -> Void)?

    private var center: UNUserNotificationCenter?
    private var useUN = false
    private var lastNotifiedAt = Date.distantPast
    private let minInterval: TimeInterval = 4
    private let debug = ProcessInfo.processInfo.environment["CLAWN_DEBUG"] == "1"
    private func log(_ m: String) {
        guard debug else { return }
        FileHandle.standardError.write("[notifier] \(m)\n".data(using: .utf8)!)
    }

    func bootstrap() {
        // バンドルから起動していないと UNUserNotificationCenter は例外を投げるため回避
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, err in
            DispatchQueue.main.async { self?.useUN = granted }
            self?.log("requestAuthorization granted=\(granted) err=\(String(describing: err))")
        }
        center = c
    }

    /// project = カード名, session = 対応 sessionId（タップ時のジャンプ用）
    func notifyReply(project: String?, snippet: String, sessionId: String?) {
        guard enabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastNotifiedAt) > minInterval else { return }
        lastNotifiedAt = now

        let title = "🦀 " + (project.map { "\($0) から返信" } ?? "Claude から返信")
        if useUN, let center = center {
            log("deliver via UN: \(title)")
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = snippet
            content.sound = .default
            if let sid = sessionId { content.userInfo = ["sessionId": sid] }
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(req)
        } else {
            log("deliver via osascript (useUN=\(useUN)): \(title)")
            notifyOsascript(title: title, body: snippet)
        }
    }

    /// フォールバック: osascript の display notification
    private func notifyOsascript(title: String, body: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    // MARK: UNUserNotificationCenterDelegate

    // アプリが前面（accessory）でも通知バナーを出す
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // 通知タップ → セッションへジャンプ
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sid = response.notification.request.content.userInfo["sessionId"] as? String {
            DispatchQueue.main.async { self.onOpenSession?(sid) }
        }
        completionHandler()
    }
}
