// ClawnPet アプリアイコンをベクター描画から PNG 出力するスクリプト
// デザイン: Claude アイコン風（テラコッタ地 + 白のミニマルなカニグリフ）
// 使い方: swift tools/render_icon.swift <出力.png> <サイズpx>
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon_1024.png"
let S: CGFloat = args.count > 2 ? CGFloat(Int(args[2]) ?? 1024) : 1024
let u = S / 1024.0

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("bitmap init failed\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * u, y: y * u) }
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x * u, y: y * u, width: w * u, height: h * u)
}

// Claude アイコンのテラコッタ
let bgColor = NSColor(red: 0.855, green: 0.467, blue: 0.337, alpha: 1) // #DA7756
let glyph   = NSColor.white

// 背景（フラットな角丸スクエア）
let bg = NSBezierPath(roundedRect: R(64, 64, 896, 896), xRadius: 224 * u, yRadius: 224 * u)
bgColor.setFill()
bg.fill()

// 脚（各サイド 3 本・放射状 = スターバーストの気配）
glyph.setStroke()
for side: CGFloat in [-1, 1] {
    for (i, angleDeg) in [CGFloat(-34), -58, -82].enumerated() {
        let a = angleDeg * .pi / 180
        let start = P(512 + side * (150 + CGFloat(i) * 26), 400 - CGFloat(i) * 22)
        let len: CGFloat = 132 * u
        let end = NSPoint(x: start.x + side * cos(-a) * len, y: start.y + sin(a) * len)
        let leg = NSBezierPath()
        leg.lineWidth = 46 * u
        leg.lineCapStyle = .round
        leg.move(to: start)
        leg.line(to: end)
        leg.stroke()
    }
}

// 腕（体とハサミをつなぐ）
for side: CGFloat in [-1, 1] {
    let arm = NSBezierPath()
    arm.lineWidth = 62 * u
    arm.lineCapStyle = .round
    arm.move(to: P(512 + side * 178, 540))
    arm.line(to: P(512 + side * 252, 612))
    glyph.setStroke()
    arm.stroke()
}

// ハサミ（上向きに開いたパックマン円）
for side: CGFloat in [-1, 1] {
    let center = P(512 + side * 272, 652)
    let r = 126 * u
    let mouth: CGFloat = side < 0 ? 122 : 58
    let half: CGFloat = 27
    let claw = NSBezierPath()
    claw.move(to: center)
    claw.appendArc(withCenter: center, radius: r, startAngle: mouth + half, endAngle: mouth - half, clockwise: false)
    claw.close()
    glyph.setFill()
    claw.fill()
}

// 体（白のソリッド楕円）
let body = NSBezierPath(ovalIn: R(277, 262, 470, 380))
glyph.setFill()
body.fill()

// 目（背景色の丸抜き）
for side: CGFloat in [-1, 1] {
    let eye = NSBezierPath(ovalIn: R(512 + side * 88 - 37, 484, 74, 74))
    bgColor.setFill()
    eye.fill()
}

// くち（背景色の小さな "w"）
let mouth = NSBezierPath()
mouth.lineWidth = 22 * u
mouth.lineCapStyle = .round
mouth.appendArc(withCenter: P(482, 408), radius: 30 * u, startAngle: 180, endAngle: 320, clockwise: false)
mouth.appendArc(withCenter: P(542, 408), radius: 30 * u, startAngle: 220, endAngle: 360, clockwise: false)
bgColor.setStroke()
mouth.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(Int(S))px)")
