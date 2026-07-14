import AppKit

// MARK: - Clawn くん本体の描画ビュー

final class PetView: NSView {
    // 表示状態
    var mood: PetMood = .idle { didSet { if oldValue != mood { moodChangedAt = CACurrentMediaTime() } } }
    var sessionCards: [SessionCard] = []
    var collapsed = false
    var sessionCount = 0 // バッジ用のアクティブセッション数

    // カニは開閉どちらも同じサイズ（右下の 116×112 領域に 0.52 倍描画）。
    // 開いたときはその上にカードスタックと閉じるボタン（˅）が乗るだけ。
    static let petAreaHeight: CGFloat = 146 // カニ領域 112 + 閉じるボタン域 34
    static let cardHeight: CGFloat = 48
    static let cardGap: CGFloat = 6
    static let collapsedSize = NSSize(width: 116, height: 112)
    private static let crabScale: CGFloat = 0.52

    // アニメーション用
    private var t: CFTimeInterval = 0
    private var moodChangedAt: CFTimeInterval = CACurrentMediaTime()
    private var nextBlinkAt: CFTimeInterval = CACurrentMediaTime() + 2.5
    private var blinkUntil: CFTimeInterval = 0
    var onRightClick: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClick: (() -> Void)?
    var onCardClick: ((Int) -> Void)?
    var onBadgeClick: (() -> Void)?  // 閉時の数字バッジ → ひらく
    var onCloseClick: (() -> Void)?  // 開時の ˅ ボタン → とじる
    private var dragStartPoint: NSPoint?
    private var dragMoved = false

    // 移動方向を向く演出: -1(左) 〜 0(正面) 〜 +1(右)
    private var facing: CGFloat = 0
    private var lastWinMaxX: CGFloat?
    private let testFacing = CGFloat(Double(ProcessInfo.processInfo.environment["CLAWN_TEST_FACING"] ?? "") ?? 0)
    private var pendingClick: DispatchWorkItem?

    // カラーパレット
    private let bodyColor    = NSColor(red: 0.910, green: 0.512, blue: 0.365, alpha: 1) // #E8825D
    private let bodyDark     = NSColor(red: 0.620, green: 0.294, blue: 0.184, alpha: 1) // #9E4B2F
    private let clawColor    = NSColor(red: 0.851, green: 0.427, blue: 0.278, alpha: 1) // #D96D47
    private let bellyColor   = NSColor(red: 0.965, green: 0.769, blue: 0.659, alpha: 1) // #F6C4A8
    private let blushColor   = NSColor(red: 0.961, green: 0.627, blue: 0.549, alpha: 0.85)
    private let pupilColor   = NSColor(red: 0.227, green: 0.165, blue: 0.133, alpha: 1)
    // ダーク UI（吹き出し・カード）の配色。ChatGPT Desktop のタスクカード風
    private let panelColor    = NSColor(red: 0.125, green: 0.125, blue: 0.13, alpha: 0.96)
    private let panelStroke   = NSColor(white: 1, alpha: 0.10)
    private let textColor     = NSColor(white: 0.96, alpha: 1)
    private let subTextColor  = NSColor(white: 0.62, alpha: 1)
    private let doneGreen     = NSColor(red: 0.20, green: 0.78, blue: 0.38, alpha: 1)
    private let busyOrange    = NSColor(red: 0.94, green: 0.60, blue: 0.23, alpha: 1)

    override var mouseDownCanMoveWindow: Bool { false } // ドラッグは自前実装（クリック判定のため）
    override var isFlipped: Bool { false }

    private let debugEvents = ProcessInfo.processInfo.environment["CLAWN_DEBUG"] == "1"
    private func dlog(_ m: String) {
        guard debugEvents else { return }
        FileHandle.standardError.write("[petview] \(m)\n".data(using: .utf8)!)
    }

    func tick(_ dt: CFTimeInterval) {
        t += dt
        updateFacing()
        let now = CACurrentMediaTime()
        if now >= nextBlinkAt {
            blinkUntil = now + 0.13
            nextBlinkAt = now + CFTimeInterval.random(in: 2.2...5.5)
        }
        needsDisplay = true
    }

    /// ウィンドウの水平移動速度から向きを更新（ドラッグ中は performDrag に委譲していて
    /// マウスイベントが来ないため、フレームごとの位置差分で検出する）。
    /// 右端 (maxX) を追うのは、開閉の伸縮では origin.x が変わっても右端は固定のため
    /// （開閉を「移動」と誤検知してカニが振り向くのを防ぐ）。
    private func updateFacing() {
        guard let x = window?.frame.maxX else { return }
        let dx = x - (lastWinMaxX ?? x)
        lastWinMaxX = x
        let target = max(-1, min(1, dx / 6)) // 6px/フレームで全振り
        // 動き出しは素早く向き、止まるとゆっくり正面へ戻る
        let rate: CGFloat = abs(target) > abs(facing) ? 0.35 : 0.10
        facing += (target - facing) * rate
        if abs(facing) < 0.01 { facing = 0 }
        if testFacing != 0 { facing = testFacing }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    // クリック（開閉）/ ダブルクリック（なでる）/ ドラッグ（移動）を判別する
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pendingClick?.cancel()
            pendingClick = nil
            dragStartPoint = nil
            onDoubleClick?()
            return
        }
        dragStartPoint = event.locationInWindow
        dragMoved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint, !dragMoved else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 3 {
            dragMoved = true
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStartPoint = nil }
        dlog("mouseUp loc=\(event.locationInWindow) dragStart=\(String(describing: dragStartPoint)) moved=\(dragMoved) collapsed=\(collapsed) sessions=\(sessionCount) badge=\(badgeRect())")
        guard dragStartPoint != nil, !dragMoved else { return }
        let p = convert(event.locationInWindow, from: nil)
        if collapsed, sessionCount > 0, badgeRect().insetBy(dx: -4, dy: -4).contains(p) {
            onBadgeClick?() // バッジ → セッション情報をひらく
            return
        }
        if !collapsed, closeButtonRect().insetBy(dx: -4, dy: -4).contains(p) {
            onCloseClick?() // ˅ → とじる
            return
        }
        if let idx = cardIndex(at: p) {
            onCardClick?(idx) // カードは即時反応（セッションへジャンプ）
            return
        }
        // ダブルクリック猶予を待ってからシングルクリック扱いにする
        let work = DispatchWorkItem { [weak self] in self?.onClick?() }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.imageInterpolation = .high

        let cx: CGFloat = 140 // モデル座標系（幅 280 前提）の中心
        let phase = CACurrentMediaTime() - moodChangedAt

        // 気分ごとの体の上下動
        var bob: CGFloat = 0
        var jump: CGFloat = 0
        var breatheY: CGFloat = 1
        switch mood {
        case .idle:        bob = sin(t * 2.2) * 3
        case .thinking:    bob = sin(t * 1.7) * 2
        case .working:     bob = sin(t * 8.0) * 1.6
        case .celebrating:
            let p = min(phase, 1.6)
            jump = abs(sin(p * .pi * 1.9)) * 24 * max(0, 1.2 - p * 0.55)
            bob = sin(t * 3.0) * 2
        case .sleeping:
            breatheY = 1 + sin(t * 1.15) * 0.022
            bob = 0
        }

        let baseY: CGFloat = 68 + bob + jump  // 体の中心 Y

        // カニは開閉共通: 右下の 116×112 領域に同じ縮尺で描く（開閉でサイズが変わらない）
        let crabOriginX = bounds.width - Self.collapsedSize.width
        NSGraphicsContext.saveGraphicsState()
        let tf = NSAffineTransform()
        tf.translateX(by: crabOriginX + Self.collapsedSize.width / 2 - cx * Self.crabScale, yBy: 4)
        tf.scale(by: Self.crabScale)
        tf.concat()
        drawCrab(cx: cx, baseY: baseY, breatheY: breatheY, jump: jump, phase: phase)
        NSGraphicsContext.restoreGraphicsState()

        if collapsed {
            drawCollapsedBadge()
        } else {
            drawCloseButton()
            drawSessionCards()
        }
    }

    // MARK: 開閉コントロール（バッジ / ˅ ボタン）

    /// 閉時の数字バッジの矩形（カニ領域の右上）
    private func badgeRect() -> NSRect {
        let d: CGFloat = 26
        let ox = bounds.width - Self.collapsedSize.width
        return NSRect(x: ox + Self.collapsedSize.width - d - 8, y: Self.collapsedSize.height - d - 4,
                      width: d, height: d)
    }

    /// 開時の閉じるボタン（˅）の矩形。閉時のバッジと同じ場所に置く:
    /// 右下角アンカーと合わせて、開閉しても画面上の同一座標に「開閉コントロール」が留まる
    private func closeButtonRect() -> NSRect { badgeRect() }

    /// カニの右肩上の丸い ˅ ボタン（クリックでとじる）
    private func drawCloseButton() {
        let rect = closeButtonRect()
        panelColor.setFill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.shadowBlurRadius = 4
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSBezierPath(ovalIn: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
        panelStroke.setStroke()
        let ring = NSBezierPath(ovalIn: rect)
        ring.lineWidth = 1
        ring.stroke()

        let mark = NSBezierPath()
        mark.lineWidth = 2
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: rect.midX - 4.5, y: rect.midY + 2.2))
        mark.line(to: NSPoint(x: rect.midX, y: rect.midY - 2.4))
        mark.line(to: NSPoint(x: rect.midX + 4.5, y: rect.midY + 2.2))
        NSColor(white: 0.92, alpha: 1).setStroke()
        mark.stroke()
    }

    private func drawCrab(cx: CGFloat, baseY: CGFloat, breatheY: CGFloat, jump: CGFloat, phase: CGFloat) {
        drawShadow(cx: cx, jump: jump)
        // 移動方向へ体ごと少し傾く（影は傾けない）
        let tilted = abs(facing) >= 0.01
        if tilted {
            NSGraphicsContext.saveGraphicsState()
            let tf = NSAffineTransform()
            tf.translateX(by: cx, yBy: baseY - 30)
            tf.rotate(byDegrees: -facing * 6)
            tf.translateX(by: -cx, yBy: -(baseY - 30))
            tf.concat()
        }
        drawLegs(cx: cx, y: baseY)
        drawClaws(cx: cx, y: baseY, phase: phase)
        drawBody(cx: cx, y: baseY, breatheY: breatheY)
        drawFace(cx: cx, y: baseY)
        if tilted { NSGraphicsContext.restoreGraphicsState() }
        drawExtras(cx: cx, y: baseY, phase: phase)
    }

    /// ミニ表示時の右上バッジ。
    /// セッションがあれば数字バッジ（通知ドット風・気分で色が変わる）、なければ気分絵文字のみ。
    private func drawCollapsedBadge() {
        // バッジはカニの呼吸・上下動に追従させず固定（インジケーターが揺れると煩わしい）
        if sessionCount > 0 {
            let color: NSColor
            switch mood {
            case .working, .thinking: color = busyOrange
            case .sleeping:           color = NSColor(white: 0.58, alpha: 1)
            default:                  color = doneGreen
            }
            let rect = badgeRect()
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)
            shadow.shadowBlurRadius = 3
            shadow.set()
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSGraphicsContext.restoreGraphicsState()

            let label = sessionCount > 9 ? "9+" : "\(sessionCount)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: label.count > 1 ? 11 : 14, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                     withAttributes: attrs)
            return
        }
        let badge: String
        switch mood {
        case .thinking: badge = "💭"
        case .working: badge = "🔧"
        case .celebrating: badge = "🎉"
        case .sleeping: badge = "💤"
        case .idle: return
        }
        (badge as NSString).draw(at: NSPoint(x: Self.collapsedSize.width - 30, y: Self.collapsedSize.height - 28),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 15)])
    }

    // MARK: セッションカード（アクティブな全セッションのスタック表示）

    /// カード i（0 = 最新/最上段）の矩形
    private func cardRect(_ i: Int) -> NSRect {
        let y = bounds.height - 8 - Self.cardHeight - CGFloat(i) * (Self.cardHeight + Self.cardGap)
        return NSRect(x: 8, y: y, width: bounds.width - 16, height: Self.cardHeight)
    }

    /// クリック位置がどのカードか（カード外なら nil）
    func cardIndex(at point: NSPoint) -> Int? {
        guard !collapsed else { return nil }
        for i in 0..<sessionCards.count {
            let r = cardRect(i)
            if r.minY < Self.petAreaHeight { break }
            if r.contains(point) { return i }
        }
        return nil
    }

    private func drawSessionCards() {
        guard !sessionCards.isEmpty,
              bounds.height > Self.petAreaHeight + Self.cardHeight else { return }
        for (i, card) in sessionCards.enumerated() {
            let rect = cardRect(i)
            if rect.minY < Self.petAreaHeight { break }
            drawCard(card, in: rect)
        }
    }

    private func drawCard(_ card: SessionCard, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
        panelColor.setFill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.shadowBlurRadius = 5
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (card.isPrimary ? NSColor(white: 1, alpha: 0.22) : panelStroke).setStroke()
        path.lineWidth = card.isPrimary ? 1.4 : 1
        path.stroke()

        // ミニカニ
        drawMiniCrab(at: NSPoint(x: rect.minX + 25, y: rect.midY - 3), mood: card.mood)

        // 状態バッジ（右上の丸アイコン: 完了=緑チェック / 作業中=オレンジ… / 就寝=グレー z）
        drawStateBadge(for: card.mood, at: NSPoint(x: rect.maxX - 18, y: rect.maxY - 18))

        // 経過時間（右下）
        let age = card.ageText as NSString
        let ageAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: subTextColor
        ]
        let ageSize = age.size(withAttributes: ageAttrs)
        age.draw(at: NSPoint(x: rect.maxX - 10 - ageSize.width, y: rect.minY + 6), withAttributes: ageAttrs)

        // タイトル + 状態
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: textColor, .paragraphStyle: para
        ]
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: subTextColor, .paragraphStyle: para
        ]
        let textX = rect.minX + 46
        let textW = rect.width - 46 - 34
        (card.title as NSString).draw(in: NSRect(x: textX, y: rect.midY + 3, width: textW, height: 15), withAttributes: titleAttrs)
        (card.statusLine as NSString).draw(in: NSRect(x: textX, y: rect.minY + 5, width: textW + 12, height: 14), withAttributes: statusAttrs)
    }

    /// 丸い状態バッジ（ChatGPT のタスクカード右上の ✓ 風）
    private func drawStateBadge(for mood: PetMood, at center: NSPoint) {
        let color: NSColor
        switch mood {
        case .celebrating, .idle: color = doneGreen
        case .working, .thinking: color = busyOrange
        case .sleeping:           color = NSColor(white: 0.42, alpha: 1)
        }
        let r: CGFloat = 8
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()

        let mark = NSBezierPath()
        mark.lineWidth = 1.9
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        NSColor.white.setStroke()
        switch mood {
        case .celebrating, .idle:
            // チェックマーク
            mark.move(to: NSPoint(x: center.x - 3.6, y: center.y + 0.2))
            mark.line(to: NSPoint(x: center.x - 1.1, y: center.y - 2.6))
            mark.line(to: NSPoint(x: center.x + 3.8, y: center.y + 2.8))
            mark.stroke()
        case .working, .thinking:
            // 進行中ドット
            for dx in [CGFloat(-4), 0, 4] {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x + dx - 1.1, y: center.y - 1.1, width: 2.2, height: 2.2)).fill()
            }
        case .sleeping:
            let z = "z" as NSString
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white]
            let s = z.size(withAttributes: a)
            z.draw(at: NSPoint(x: center.x - s.width / 2, y: center.y - s.height / 2), withAttributes: a)
        }
    }

    /// カード用のちいさい Clawn（体+目+ハサミだけ）
    private func drawMiniCrab(at c: NSPoint, mood: PetMood) {
        let wiggle: CGFloat = (mood == .working) ? sin(t * 9) * 2 : 0
        let clawLift: CGFloat = (mood == .celebrating) ? 7 : (mood == .working ? 3 + wiggle : 0)

        // ハサミ
        for side in [CGFloat(-1), 1] {
            let claw = NSBezierPath(ovalIn: NSRect(x: c.x + side * 15 - 5, y: c.y + clawLift - 4, width: 10, height: 10))
            clawColor.setFill()
            claw.fill()
        }
        // 体
        let body = NSBezierPath(ovalIn: NSRect(x: c.x - 14, y: c.y - 10, width: 28, height: 21))
        bodyColor.setFill()
        body.fill()
        bodyDark.withAlphaComponent(0.5).setStroke()
        body.lineWidth = 1.2
        body.stroke()
        // 目
        for side in [CGFloat(-1), 1] {
            let ex = c.x + side * 5
            if mood == .sleeping {
                let lid = NSBezierPath()
                lid.lineWidth = 1.4
                lid.lineCapStyle = .round
                lid.move(to: NSPoint(x: ex - 2.5, y: c.y + 3))
                lid.line(to: NSPoint(x: ex + 2.5, y: c.y + 3))
                pupilColor.setStroke()
                lid.stroke()
            } else {
                let eye = NSBezierPath(ovalIn: NSRect(x: ex - 3, y: c.y + 0.5, width: 6, height: 6))
                NSColor.white.setFill()
                eye.fill()
                let pupil = NSBezierPath(ovalIn: NSRect(x: ex - 1.4, y: c.y + 2, width: 2.8, height: 2.8))
                pupilColor.setFill()
                pupil.fill()
            }
        }
        // くち
        let mouth = NSBezierPath()
        mouth.lineWidth = 1.2
        mouth.lineCapStyle = .round
        mouth.appendArc(withCenter: NSPoint(x: c.x, y: c.y - 3.5), radius: 2.2, startAngle: 200, endAngle: 340, clockwise: false)
        pupilColor.withAlphaComponent(0.75).setStroke()
        mouth.stroke()
    }

    private func drawShadow(cx: CGFloat, jump: CGFloat) {
        let squish = max(0.55, 1 - jump / 40)
        let w = 118 * squish
        let shadow = NSBezierPath(ovalIn: NSRect(x: cx - w / 2, y: 12, width: w, height: 16 * squish))
        NSColor.black.withAlphaComponent(0.13).setFill()
        shadow.fill()
    }

    private func drawLegs(cx: CGFloat, y: CGFloat) {
        bodyDark.setStroke()
        for side in [CGFloat(-1), 1] {
            for i in 0..<3 {
                let path = NSBezierPath()
                path.lineWidth = 5
                path.lineCapStyle = .round
                let bx = cx + side * (30 + CGFloat(i) * 13)
                let wiggle = (mood == .working) ? sin(t * 10 + CGFloat(i) * 1.4) * 2.5 : sin(t * 2.4 + CGFloat(i)) * 1.2
                path.move(to: NSPoint(x: bx, y: y - 26))
                path.line(to: NSPoint(x: bx + side * 9, y: y - 41 + wiggle))
                path.stroke()
            }
        }
    }

    /// ハサミ（パックマン型の欠けのある円）
    private func drawClaws(cx: CGFloat, y: CGFloat, phase: CGFloat) {
        for side in [CGFloat(-1), 1] {
            var lift: CGFloat = 0
            var mouthAngle: CGFloat = side < 0 ? 125 : 55 // 欠け口の向き（度・上向きに開く）
            switch mood {
            case .working:
                lift = max(0, sin(t * 9 + (side < 0 ? 0 : .pi))) * 12
            case .celebrating:
                lift = 26 + sin(t * 6) * 4
                mouthAngle = side < 0 ? 120 : 60
            case .thinking:
                lift = side < 0 ? 18 : 0 // 左手をあごに
            case .sleeping:
                lift = -4
            case .idle:
                lift = sin(t * 2.2 + (side < 0 ? 0.4 : 0)) * 2
            }

            let armX = cx + side * 56
            let armY = y - 2 + lift * 0.35
            // 腕
            let arm = NSBezierPath()
            arm.lineWidth = 8
            arm.lineCapStyle = .round
            arm.move(to: NSPoint(x: cx + side * 40, y: y - 6))
            arm.line(to: NSPoint(x: armX, y: armY + lift * 0.4))
            clawColor.setStroke()
            arm.stroke()

            // ハサミ本体
            let clawCenter = NSPoint(x: cx + side * 72, y: y + 2 + lift)
            let r: CGFloat = 21
            let half: CGFloat = 24 // 欠け口の半分の角度
            let a0 = mouthAngle + half
            let a1 = mouthAngle - half
            let claw = NSBezierPath()
            claw.move(to: clawCenter)
            claw.appendArc(withCenter: clawCenter, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
            claw.close()
            clawColor.setFill()
            claw.fill()
            bodyDark.withAlphaComponent(0.5).setStroke()
            claw.lineWidth = 2
            claw.stroke()
        }
    }

    private func drawBody(cx: CGFloat, y: CGFloat, breatheY: CGFloat) {
        let bw: CGFloat = 118
        let bh: CGFloat = 92 * breatheY
        let bodyRect = NSRect(x: cx - bw / 2, y: y - bh / 2, width: bw, height: bh)
        let body = NSBezierPath(ovalIn: bodyRect)
        bodyColor.setFill()
        body.fill()
        bodyDark.withAlphaComponent(0.65).setStroke()
        body.lineWidth = 2.5
        body.stroke()

        // おなかの模様（向いた方向へ少し寄せて立体感を出す）
        let belly = NSBezierPath(ovalIn: NSRect(x: cx - 34 + facing * 5, y: y - bh / 2 + 6, width: 68, height: 36))
        bellyColor.withAlphaComponent(0.9).setFill()
        belly.fill()
    }

    private func drawFace(cx rawCx: CGFloat, y: CGFloat) {
        let cx = rawCx + facing * 7 // 顔全体が移動方向へ寄る
        let now = CACurrentMediaTime()
        let blinking = now < blinkUntil || mood == .sleeping

        // 目の位置（体の上部・目玉は柄付き）
        for side in [CGFloat(-1), 1] {
            let ex = cx + side * 22
            let stalkTop = NSPoint(x: ex + facing * 4, y: y + 52) // 柄の先が向く方向へ倒れる
            // 柄
            let stalk = NSBezierPath()
            stalk.lineWidth = 6
            stalk.lineCapStyle = .round
            stalk.move(to: NSPoint(x: ex, y: y + 30))
            stalk.line(to: stalkTop)
            bodyColor.setStroke()
            stalk.stroke()

            if blinking {
                // 閉じ目（にっこり線）
                let lid = NSBezierPath()
                lid.lineWidth = 3
                lid.lineCapStyle = .round
                lid.appendArc(withCenter: NSPoint(x: stalkTop.x, y: stalkTop.y + 2), radius: 8,
                              startAngle: 200, endAngle: 340, clockwise: false)
                pupilColor.setStroke()
                lid.stroke()
            } else {
                // 白目
                let eye = NSBezierPath(ovalIn: NSRect(x: stalkTop.x - 11, y: stalkTop.y - 9, width: 22, height: 22))
                NSColor.white.setFill()
                eye.fill()
                bodyDark.withAlphaComponent(0.35).setStroke()
                eye.lineWidth = 1.5
                eye.stroke()

                // 視線
                var look = NSPoint(x: 0, y: 0)
                switch mood {
                case .thinking: look = NSPoint(x: -3, y: 3.5)
                case .working:  look = NSPoint(x: 0, y: -2.5)
                case .celebrating: look = NSPoint(x: 0, y: 1.5)
                default: look = NSPoint(x: sin(t * 0.7) * 1.8, y: 0)
                }
                look.x += facing * 3.5 // 移動方向を見る
                let pupil = NSBezierPath(ovalIn: NSRect(x: stalkTop.x - 4.5 + look.x, y: stalkTop.y - 2.5 + look.y, width: 9, height: 9))
                pupilColor.setFill()
                pupil.fill()
                let hi = NSBezierPath(ovalIn: NSRect(x: stalkTop.x - 3 + look.x, y: stalkTop.y + 2.5 + look.y, width: 3.4, height: 3.4))
                NSColor.white.withAlphaComponent(0.95).setFill()
                hi.fill()
            }
        }

        // ほっぺ
        for side in [CGFloat(-1), 1] {
            let blush = NSBezierPath(ovalIn: NSRect(x: cx + side * 36 - 8, y: y + 8, width: 16, height: 8))
            blushColor.setFill()
            blush.fill()
        }

        // くち
        let mouth = NSBezierPath()
        mouth.lineWidth = 2.6
        mouth.lineCapStyle = .round
        pupilColor.withAlphaComponent(0.85).setStroke()
        let my = y + 14
        switch mood {
        case .celebrating:
            // 大きく開けた口
            let open = NSBezierPath()
            open.appendArc(withCenter: NSPoint(x: cx, y: my), radius: 8, startAngle: 180, endAngle: 360, clockwise: false)
            open.close()
            pupilColor.withAlphaComponent(0.9).setFill()
            open.fill()
        case .thinking:
            let o = NSBezierPath(ovalIn: NSRect(x: cx - 3, y: my - 6, width: 6, height: 6))
            o.lineWidth = 2
            pupilColor.withAlphaComponent(0.8).setStroke()
            o.stroke()
        case .working:
            mouth.move(to: NSPoint(x: cx - 6, y: my - 2))
            mouth.line(to: NSPoint(x: cx + 6, y: my - 2))
            mouth.stroke()
        case .sleeping:
            let o = NSBezierPath(ovalIn: NSRect(x: cx - 2.5, y: my - 6, width: 5, height: 5))
            pupilColor.withAlphaComponent(0.6).setFill()
            o.fill()
        case .idle:
            mouth.appendArc(withCenter: NSPoint(x: cx - 4, y: my), radius: 4.5, startAngle: 180, endAngle: 320, clockwise: false)
            mouth.appendArc(withCenter: NSPoint(x: cx + 4, y: my), radius: 4.5, startAngle: 220, endAngle: 360, clockwise: false)
            mouth.stroke()
        }
    }

    /// 気分ごとの飾り（汗・キラキラ・Zzz）
    private func drawExtras(cx: CGFloat, y: CGFloat, phase: CGFloat) {
        switch mood {
        case .thinking:
            if phase > 20 {
                // 汗
                let sx = cx + 52
                let sy = y + 42 - sin(t * 3) * 2
                let drop = NSBezierPath()
                drop.move(to: NSPoint(x: sx, y: sy + 8))
                drop.curve(to: NSPoint(x: sx, y: sy - 6),
                           controlPoint1: NSPoint(x: sx + 7, y: sy + 2),
                           controlPoint2: NSPoint(x: sx + 5, y: sy - 6))
                drop.curve(to: NSPoint(x: sx, y: sy + 8),
                           controlPoint1: NSPoint(x: sx - 5, y: sy - 6),
                           controlPoint2: NSPoint(x: sx - 7, y: sy + 2))
                NSColor(red: 0.42, green: 0.68, blue: 0.94, alpha: 0.9).setFill()
                drop.fill()
            }
        case .celebrating:
            let offsets: [(CGFloat, CGFloat)] = [(-62, 46), (58, 58), (-30, 78), (66, 16), (-70, 8)]
            for (i, off) in offsets.enumerated() {
                let alpha = (sin(t * 5 + CGFloat(i) * 1.3) + 1) / 2
                drawStar(at: NSPoint(x: cx + off.0, y: y + off.1), size: 6 + CGFloat(i % 3) * 2,
                         color: NSColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 0.35 + alpha * 0.6))
            }
        case .sleeping:
            for i in 0..<3 {
                let drift = fmod(t * 9 + CFTimeInterval(i) * 15, 46)
                let alpha = max(0, 1 - drift / 46)
                let size = 11 + CGFloat(i) * 4
                let p = NSPoint(x: cx + 42 + drift * 0.55, y: y + 42 + drift)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: size),
                    .foregroundColor: NSColor(red: 0.48, green: 0.42, blue: 0.66, alpha: alpha)
                ]
                ("Z" as NSString).draw(at: p, withAttributes: attrs)
            }
        default:
            break
        }
    }

    private func drawStar(at p: NSPoint, size: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: p.x, y: p.y + size))
        path.curve(to: NSPoint(x: p.x + size, y: p.y),
                   controlPoint1: NSPoint(x: p.x + size * 0.18, y: p.y + size * 0.18),
                   controlPoint2: NSPoint(x: p.x + size * 0.18, y: p.y + size * 0.18))
        path.curve(to: NSPoint(x: p.x, y: p.y - size),
                   controlPoint1: NSPoint(x: p.x + size * 0.18, y: p.y - size * 0.18),
                   controlPoint2: NSPoint(x: p.x + size * 0.18, y: p.y - size * 0.18))
        path.curve(to: NSPoint(x: p.x - size, y: p.y),
                   controlPoint1: NSPoint(x: p.x - size * 0.18, y: p.y - size * 0.18),
                   controlPoint2: NSPoint(x: p.x - size * 0.18, y: p.y - size * 0.18))
        path.curve(to: NSPoint(x: p.x, y: p.y + size),
                   controlPoint1: NSPoint(x: p.x - size * 0.18, y: p.y + size * 0.18),
                   controlPoint2: NSPoint(x: p.x - size * 0.18, y: p.y + size * 0.18))
        path.close()
        color.setFill()
        path.fill()
    }

    // MARK: スナップショット（自己検証用）

    func snapshotPNG(to url: URL) {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
