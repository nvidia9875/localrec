#!/usr/bin/env swift
//
// アプリアイコン (AudioRec.icns) を描いて書き出す。
//
// 画像ファイルではなくコードで持つ理由:
//   - 色や形を直すときに差分が読める
//   - 全サイズを「縮小」ではなく「そのサイズで描き直す」ので、
//     16pt でも線が潰れない
//
// 使い方:
//   swift scripts/make_icon.swift [出力.icns] [プレビュー.png]
//
import AppKit
import CoreGraphics
import Foundation

// MARK: - 配色

enum Palette {
    /// 背景のグラデーション (左上 → 右下)。録音中の赤に寄せた暖色。
    static let backgroundTop = rgb(0xFF, 0xA9, 0x8C)
    static let backgroundMid = rgb(0xF9, 0x6F, 0x83)
    static let backgroundBottom = rgb(0xE8, 0x4B, 0x6E)

    /// マイク本体。真っ白より少し暖かい生成り。
    static let bodyTop = rgb(0xFF, 0xFF, 0xFF)
    static let bodyBottom = rgb(0xFF, 0xEE, 0xE4)

    /// 顔。黒だと固く見えるので焦げ茶にする。
    static let face = rgb(0x5A, 0x3B, 0x38)
    static let blush = rgb(0xFF, 0x8F, 0xA1, 0.85)

    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
}

// MARK: - 寸法 (1024 四方の設計座標・y は下向き)

enum Layout {
    static let canvas: CGFloat = 1024

    /// アイコン本体の角丸矩形。macOS 標準の余白 100 / 角丸 185.4 に合わせる。
    static let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let bodyRadius: CGFloat = 185.4

    /// マイクのカプセル。アーチの内側に余白が残る長さにする
    /// (詰めるとアーチと溶け合って、ただの縦長の塊に見える)。
    static let capsule = CGRect(x: 362, y: 190, width: 300, height: 400)

    /// カプセルを受けるアーチ
    static let archCenter = CGPoint(x: 512, y: 555)
    static let archRadius: CGFloat = 200
    static let archWidth: CGFloat = 50

    /// 支柱と台座。支柱は細くするとアーチの底に埋もれて瘤に見えるので、
    /// 見えている部分 (アーチ底〜台座) が首として読める太さにする。
    static let stem = CGRect(x: 476, y: 752, width: 72, height: 58)
    static let base = CGRect(x: 392, y: 806, width: 236, height: 52)

    /// 顔
    static let eyeSize = CGSize(width: 40, height: 52)
    static let eyeY: CGFloat = 358
    static let eyeOffset: CGFloat = 57
    static let smileCenter = CGPoint(x: 512, y: 384)
    static let smileRadius: CGFloat = 54
    static let smileWidth: CGFloat = 18
    static let blushSize = CGSize(width: 62, height: 36)
    static let blushY: CGFloat = 414
    static let blushOffset: CGFloat = 92
}

// MARK: - 描画

/// - Parameter showsDetails: 顔ときらめきを描くか。
///   16pt では目と口が 1〜2px になって黒い塊に潰れるため、その寸法では省く。
func drawIcon(in ctx: CGContext, showsDetails: Bool) {
    let body = CGPath(
        roundedRect: Layout.bodyRect,
        cornerWidth: Layout.bodyRadius, cornerHeight: Layout.bodyRadius, transform: nil)

    // 背景
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    drawBackground(in: ctx)
    ctx.restoreGState()

    if showsDetails { drawSparkles(in: ctx) }

    // マイク。影は本体にだけ付ける (背景の縁に落とさない)
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.setShadow(
        offset: CGSize(width: 0, height: 16), blur: 34,
        color: Palette.rgb(0x7A, 0x21, 0x35, 0.30))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawMicrophone(in: ctx)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    if showsDetails { drawFace(in: ctx) }
}

private func drawBackground(in ctx: CGContext) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.backgroundTop, Palette.backgroundMid, Palette.backgroundBottom] as CFArray,
        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 140, y: 120), end: CGPoint(x: 900, y: 920),
        options: [])

    // 上から差す光。単色のベタ塗りに見えないようにする。
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.rgb(0xFF, 0xFF, 0xFF, 0.30), Palette.rgb(0xFF, 0xFF, 0xFF, 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 400, y: 210), startRadius: 0,
        endCenter: CGPoint(x: 400, y: 210), endRadius: 520,
        options: [])
}

/// 四芒星。角を丸めず、細く尖らせると「きらり」に見える。
private func drawSparkles(in ctx: CGContext) {
    func sparkle(center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let waist = radius * 0.26
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addQuadCurve(
            to: CGPoint(x: center.x + radius, y: center.y),
            control: CGPoint(x: center.x + waist, y: center.y - waist))
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y + radius),
            control: CGPoint(x: center.x + waist, y: center.y + waist))
        path.addQuadCurve(
            to: CGPoint(x: center.x - radius, y: center.y),
            control: CGPoint(x: center.x - waist, y: center.y + waist))
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y - radius),
            control: CGPoint(x: center.x - waist, y: center.y - waist))
        ctx.addPath(path)
        ctx.setFillColor(Palette.rgb(0xFF, 0xFF, 0xFF, alpha))
        ctx.fillPath()
    }

    sparkle(center: CGPoint(x: 742, y: 286), radius: 44, alpha: 0.85)
    sparkle(center: CGPoint(x: 300, y: 250), radius: 26, alpha: 0.70)
    sparkle(center: CGPoint(x: 772, y: 400), radius: 18, alpha: 0.55)
}

private func drawMicrophone(in ctx: CGContext) {
    let bodyGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.bodyTop, Palette.bodyBottom] as CFArray,
        locations: [0, 1])!

    // 台座 → 支柱 → アーチ → カプセルの順に重ねる
    let parts = CGMutablePath()
    parts.addRoundedRect(in: Layout.base, cornerWidth: 27, cornerHeight: 27)
    parts.addRoundedRect(in: Layout.stem, cornerWidth: 18, cornerHeight: 18)

    let arch = CGMutablePath()
    arch.addArc(
        center: Layout.archCenter, radius: Layout.archRadius,
        startAngle: 0, endAngle: .pi, clockwise: false)
    let strokedArch = CGPath(
        __byStroking: arch, transform: nil,
        lineWidth: Layout.archWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    if let strokedArch { parts.addPath(strokedArch) }

    parts.addRoundedRect(
        in: Layout.capsule,
        cornerWidth: Layout.capsule.width / 2, cornerHeight: Layout.capsule.width / 2)

    ctx.saveGState()
    ctx.addPath(parts)
    ctx.clip()
    ctx.drawLinearGradient(
        bodyGradient,
        start: CGPoint(x: 512, y: 190), end: CGPoint(x: 512, y: 860),
        options: [])
    ctx.restoreGState()
}

private func drawFace(in ctx: CGContext) {
    // ほっぺ (目より先に置いて、線が乗る順を自然にする)
    ctx.setFillColor(Palette.blush)
    for side in [-1.0, 1.0] as [CGFloat] {
        let rect = CGRect(
            x: 512 + side * Layout.blushOffset - Layout.blushSize.width / 2,
            y: Layout.blushY - Layout.blushSize.height / 2,
            width: Layout.blushSize.width, height: Layout.blushSize.height)
        ctx.addEllipse(in: rect)
    }
    ctx.fillPath()

    // 目
    ctx.setFillColor(Palette.face)
    for side in [-1.0, 1.0] as [CGFloat] {
        let rect = CGRect(
            x: 512 + side * Layout.eyeOffset - Layout.eyeSize.width / 2,
            y: Layout.eyeY - Layout.eyeSize.height / 2,
            width: Layout.eyeSize.width, height: Layout.eyeSize.height)
        ctx.addPath(
            CGPath(
                roundedRect: rect,
                cornerWidth: Layout.eyeSize.width / 2, cornerHeight: Layout.eyeSize.width / 2,
                transform: nil))
    }
    ctx.fillPath()

    // 口
    let smile = CGMutablePath()
    smile.addArc(
        center: Layout.smileCenter, radius: Layout.smileRadius,
        startAngle: .pi * 0.16, endAngle: .pi * 0.84, clockwise: false)
    ctx.addPath(smile)
    ctx.setStrokeColor(Palette.face)
    ctx.setLineWidth(Layout.smileWidth)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

// MARK: - 書き出し

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // 設計座標 (1024 四方・y 下向き) に合わせる
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: 1, y: -1)
    let scale = CGFloat(pixels) / Layout.canvas
    ctx.scaleBy(x: scale, y: scale)

    drawIcon(in: ctx, showsDetails: pixels >= 32)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 1)
    }
    try data.write(to: url, options: .atomic)
}

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = URL(
    fileURLWithPath: arguments.count > 1 ? arguments[1] : "app/Support/AudioRec.icns",
    relativeTo: root)
let preview = arguments.count > 2 ? URL(fileURLWithPath: arguments[2], relativeTo: root) : nil

// .iconset は iconutil が読む中間物なので一時ディレクトリに置く
let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("audiorec-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = workDirectory.appendingPathComponent("AudioRec.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

/// (論理サイズ, 倍率) の組。macOS の .icns が要求する 10 枚。
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    let suffix = variant.scale == 1 ? "" : "@2x"
    let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    try writePNG(render(pixels: pixels), to: iconset.appendingPathComponent(name))
}

if let preview {
    try FileManager.default.createDirectory(
        at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writePNG(render(pixels: 1024), to: preview)
}

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil が失敗しました\n".utf8))
    exit(1)
}

print("アイコンを書き出しました: \(output.standardizedFileURL.path)")
if let preview {
    print("プレビュー: \(preview.standardizedFileURL.path)")
}
