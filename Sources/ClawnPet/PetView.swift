import AppKit

// MARK: - Clawn くん本体の描画ビュー

final class PetView: NSView {
    // 表示状態
    var mood: PetMood = .idle { didSet { if oldValue != mood { moodChangedAt = CACurrentMediaTime() } } }
    var statusLine: String = "こんにちは！Clawn だよ"
    var contextLine: String = "Claude の作業を見守るね"
    var sessionsInfo: String = ""
    var sessionCards: [SessionCard] = []
    var cardsVisible = true
    var collapsed = false
    var sessionCount = 0 // ミニ表示バッジ用のアクティブセッション数

    static let petAreaHeight: CGFloat = 320 // ペット+吹き出しの基本領域
    static let cardHeight: CGFloat = 48
    static let cardGap: CGFloat = 6
    static let collapsedSize = NSSize(width: 116, height: 112)
    private static let collapsedScale: CGFloat = 0.52

    // アニメーション用
    private var t: CFTimeInterval = 0
    private var moodChangedAt: CFTimeInterval = CACurrentMediaTime()
    private var nextBlinkAt: CFTimeInterval = CACurrentMediaTime() + 2.5
    private var blinkUntil: CFTimeInterval = 0
    var onRightClick: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClick: (() -> Void)?
    var onCardClick: ((Int) -> Void)?
    private var dragStartPoint: NSPoint?
    private var dragMoved = false
    private var pendingClick: DispatchWorkItem?

    // カラーパレット
    private let bodyColor    = NSColor(red: 0.910, green: 0.512, blue: 0.365, alpha: 1) // #E8825D
    private let bodyDark     = NSColor(red: 0.620, green: 0.294, blue: 0.184, alpha: 1) // #9E4B2F
    private let clawColor    = NSColor(red: 0.851, green: 0.427, blue: 0.278, alpha: 1) // #D96D47
    private let bellyColor   = NSColor(red: 0.965, green: 0.769, blue: 0.659, alpha: 1) // #F6C4A8
    private let blushColor   = NSColor(red: 0.961, green: 0.627, blue: 0.549, alpha: 0.85)
    private let pupilColor   = NSColor(red: 0.227, green: 0.165, blue: 0.133, alpha: 1)
    private let textColor    = NSColor(red: 0.290, green: 0.227, blue: 0.196, alpha: 1)
    private let subTextColor = NSColor(red: 0.541, green: 0.478, blue: 0.439, alpha: 1)

    override var mouseDownCanMoveWindow: Bool { false } // ドラッグは自前実装（クリック判定のため）
    override var isFlipped: Bool { false }

    func tick(_ dt: CFTimeInterval) {
        t += dt
        let now = CACurrentMediaTime()
        if now >= nextBlinkAt {
            blinkUntil = now + 0.13
            nextBlinkAt = now + CFTimeInterval.random(in: 2.2...5.5)
        }
        needsDisplay = true
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
        guard dragStartPoint != nil, !dragMoved else { return }
        let p = convert(event.locationInWindow, from: nil)
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

        if collapsed {
            // ミニ表示: カニだけを縮小描画（吹き出し・カードなし）
            NSGraphicsContext.saveGraphicsState()
            let tf = NSAffineTransform()
            tf.translateX(by: Self.collapsedSize.width / 2 - cx * Self.collapsedScale, yBy: 4)
            tf.scale(by: Self.collapsedScale)
            tf.concat()
            drawCrab(cx: cx, baseY: baseY, breatheY: breatheY, jump: jump, phase: phase)
            NSGraphicsContext.restoreGraphicsState()
            drawCollapsedBadge()
            return
        }

        drawCrab(cx: cx, baseY: baseY, breatheY: breatheY, jump: jump, phase: phase)
        drawBubble(cx: cx)
        drawSessionCards()
    }

    private func drawCrab(cx: CGFloat, baseY: CGFloat, breatheY: CGFloat, jump: CGFloat, phase: CGFloat) {
        drawShadow(cx: cx, jump: jump)
        drawLegs(cx: cx, y: baseY)
        drawClaws(cx: cx, y: baseY, phase: phase)
        drawBody(cx: cx, y: baseY, breatheY: breatheY)
        drawFace(cx: cx, y: baseY)
        drawExtras(cx: cx, y: baseY, phase: phase)
    }

    /// ミニ表示時の右上バッジ。
    /// セッションがあれば数字バッジ（通知ドット風・気分で色が変わる）、なければ気分絵文字のみ。
    private func drawCollapsedBadge() {
        let bobY = sin(t * 3) * 1.5
        if sessionCount > 0 {
            let color: NSColor
            switch mood {
            case .working, .thinking: color = NSColor(red: 0.94, green: 0.60, blue: 0.23, alpha: 1) // 作業中はオレンジ
            case .sleeping:           color = NSColor(white: 0.58, alpha: 1)
            default:                  color = NSColor(red: 0.18, green: 0.76, blue: 0.36, alpha: 1) // ふだんは緑
            }
            let d: CGFloat = 26
            let rect = NSRect(x: Self.collapsedSize.width - d - 8, y: Self.collapsedSize.height - d - 4 + bobY,
                              width: d, height: d)
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
        (badge as NSString).draw(at: NSPoint(x: Self.collapsedSize.width - 30, y: Self.collapsedSize.height - 28 + bobY),
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
        guard cardsVisible, !collapsed else { return nil }
        for i in 0..<sessionCards.count {
            let r = cardRect(i)
            if r.minY < Self.petAreaHeight { break }
            if r.contains(point) { return i }
        }
        return nil
    }

    private func drawSessionCards() {
        guard cardsVisible, !sessionCards.isEmpty,
              bounds.height > Self.petAreaHeight + Self.cardHeight else { return }
        for (i, card) in sessionCards.enumerated() {
            let rect = cardRect(i)
            if rect.minY < Self.petAreaHeight { break }
            drawCard(card, in: rect)
        }
    }

    private func drawCard(_ card: SessionCard, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        NSColor.white.withAlphaComponent(0.93).setFill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.13)
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.shadowBlurRadius = 4
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if card.isPrimary {
            bodyColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
        } else {
            NSColor(red: 0.90, green: 0.85, blue: 0.81, alpha: 1).setStroke()
            path.lineWidth = 1.2
        }
        path.stroke()

        // ミニカニ
        drawMiniCrab(at: NSPoint(x: rect.minX + 25, y: rect.midY - 3), mood: card.mood)

        // 気分バッジ（右上）
        let badge: String
        switch card.mood {
        case .thinking: badge = "💭"
        case .working: badge = "🔧"
        case .celebrating: badge = "🎉"
        case .idle: badge = "☕"
        case .sleeping: badge = "💤"
        }
        (badge as NSString).draw(at: NSPoint(x: rect.maxX - 26, y: rect.midY + 2),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 13)])

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

        // おなかの模様
        let belly = NSBezierPath(ovalIn: NSRect(x: cx - 34, y: y - bh / 2 + 6, width: 68, height: 36))
        bellyColor.withAlphaComponent(0.9).setFill()
        belly.fill()
    }

    private func drawFace(cx: CGFloat, y: CGFloat) {
        let now = CACurrentMediaTime()
        let blinking = now < blinkUntil || mood == .sleeping

        // 目の位置（体の上部・目玉は柄付き）
        for side in [CGFloat(-1), 1] {
            let ex = cx + side * 22
            let stalkTop = NSPoint(x: ex, y: y + 52)
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

    // MARK: 吹き出し

    private func drawBubble(cx: CGFloat) {
        var status = statusLine
        if mood == .thinking || mood == .working {
            let dots = Int(t * 2.4) % 4
            status += String(repeating: "・", count: dots)
        }

        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
            .foregroundColor: textColor
        ]
        var contextText = contextLine
        if !sessionsInfo.isEmpty { contextText += "  \(sessionsInfo)" }
        let contextAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: subTextColor
        ]

        let statusStr = status as NSString
        let contextStr = contextText as NSString
        let maxTextWidth: CGFloat = 218
        let sSize = statusStr.boundingRect(with: NSSize(width: maxTextWidth, height: 60), options: [.usesLineFragmentOrigin], attributes: statusAttrs).size
        let cSize = contextStr.boundingRect(with: NSSize(width: maxTextWidth, height: 60), options: [.usesLineFragmentOrigin], attributes: contextAttrs).size

        let pad: CGFloat = 11
        let bw = min(maxTextWidth, max(sSize.width, cSize.width)) + pad * 2
        let bh = sSize.height + cSize.height + pad * 2 + 3
        let bx = min(max(cx - bw / 2, 6), bounds.width - bw - 6)
        let by: CGFloat = 152 // カニの頭のすぐ上に固定し、上方向に伸びる

        let alpha: CGFloat = (mood == .sleeping) ? 0.55 : 1.0

        // 吹き出し本体
        let rect = NSRect(x: bx, y: by, width: bw, height: bh)
        let bubble = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        // しっぽ
        bubble.move(to: NSPoint(x: cx - 8, y: by))
        bubble.line(to: NSPoint(x: cx, y: by - 10))
        bubble.line(to: NSPoint(x: cx + 8, y: by))
        bubble.close()

        NSColor.white.withAlphaComponent(0.95 * alpha).setFill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18 * alpha)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 5
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        bubble.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(red: 0.90, green: 0.85, blue: 0.81, alpha: alpha).setStroke()
        bubble.lineWidth = 1.5
        bubble.stroke()

        // テキスト
        statusStr.draw(in: NSRect(x: bx + pad, y: by + bh - pad - sSize.height, width: bw - pad * 2, height: sSize.height),
                       withAttributes: statusAttrs)
        contextStr.draw(in: NSRect(x: bx + pad, y: by + pad, width: bw - pad * 2, height: cSize.height),
                        withAttributes: contextAttrs)
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
