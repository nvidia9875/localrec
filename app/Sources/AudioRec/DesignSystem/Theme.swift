import AppKit
import SwiftUI

/// Notion の会議ノート UI に寄せたデザイントークン。
///
/// 色はすべて `NSColor` の dynamic provider 経由で定義している。
/// こうすると SwiftUI のビュー側で `@Environment(\.colorScheme)` を持ち回らずに
/// ライト/ダークが自動で切り替わる。
enum Theme {

    // MARK: - 色

    enum Palette {
        /// 本文背景
        static let background = Color(nsColor: .audioRecDynamic(light: 0xFFFFFF, dark: 0x191919))
        /// サイドバー背景。Notion は本文よりわずかに沈ませる。
        static let sidebar = Color(nsColor: .audioRecDynamic(light: 0xF7F7F5, dark: 0x202020))
        /// hover / 選択中の面
        static let surfaceHover = Color(nsColor: NSPalette.surfaceHover)
        static let surfaceSelected = Color(nsColor: .audioRecDynamic(light: 0xE8E7E4, dark: 0x333333))

        /// 本文。真っ黒ではなくわずかに温かい墨色 — Notion の特徴。
        static let text = Color(nsColor: NSPalette.text)
        /// 補助文字 (タイムスタンプ、日付、件数)
        static let textMuted = Color(nsColor: NSPalette.textMuted)
        /// 未確定 (volatile) の文字起こし
        static let textVolatile = Color(nsColor: .audioRecDynamic(light: 0xB4B3AF, dark: 0x6B6B6B))

        /// 1px の区切り線。影ではなく線で構造を作る。
        static let rule = Color(nsColor: .audioRecDynamic(light: 0xE9E9E7, dark: 0x2F2F2F))

        /// 録音中を示す赤
        static let recording = Color(nsColor: .audioRecDynamic(light: 0xE03E3E, dark: 0xFF6B6B))

        /// 話者チップ: 自分 (青系)
        static let speakerSelfBG = Color(nsColor: .audioRecDynamic(light: 0xE7F3F8, dark: 0x1C3A47))
        static let speakerSelfFG = Color(nsColor: .audioRecDynamic(light: 0x0B6E99, dark: 0x7FC7E8))
        /// 話者チップ: 相手 (橙系)
        static let speakerOtherBG = Color(nsColor: .audioRecDynamic(light: 0xFAEBDD, dark: 0x3E2E1E))
        static let speakerOtherFG = Color(nsColor: .audioRecDynamic(light: 0xD9730D, dark: 0xE9A66B))

        /// 再生中セグメントのハイライト
        static let highlight = Color(nsColor: .audioRecDynamic(light: 0xFDF3D9, dark: 0x3A3320))
    }

    /// AppKit のビュー（メモ欄の NSTextView）で使う色。値は `Palette` と共有する。
    enum NSPalette {
        static let text = NSColor.audioRecDynamic(light: 0x37352F, dark: 0xD4D4D4)
        static let textMuted = NSColor.audioRecDynamic(light: 0x9B9A97, dark: 0x7F7F7F)
        static let surfaceHover = NSColor.audioRecDynamic(light: 0xEFEFEE, dark: 0x2C2C2C)
    }

    // MARK: - 字送り

    enum Font {
        static let title = SwiftUI.Font.system(size: 32, weight: .bold)
        static let sectionHeader = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 16)
        static let meta = SwiftUI.Font.system(size: 12)
        static let sidebarItem = SwiftUI.Font.system(size: 14)
        /// タイムスタンプは桁が揺れないよう等幅数字にする
        static let timestamp = SwiftUI.Font.system(size: 13, design: .monospaced)
        static let speakerChip = SwiftUI.Font.system(size: 11, weight: .medium)
    }

    // MARK: - 余白・寸法

    enum Metrics {
        /// Notion の角丸は小さい。大きくすると途端に「テンプレっぽく」なる。
        static let radius: CGFloat = 3.0
        static let sidebarWidth: CGFloat = 260
        static let sidebarMinWidth: CGFloat = 200
        static let sidebarMaxWidth: CGFloat = 360

        /// 本文の左右余白。Notion は本文カラムをかなり広く取る。
        static let contentPadding: CGFloat = 48
        /// 本文カラムの上限幅。ウィンドウを広げたときに 1 行が長くなりすぎると
        /// 目線の戻りが大きくなって読みづらい。Notion も同様に上限を設けている。
        static let maxContentWidth: CGFloat = 900
        static let rowVerticalPadding: CGFloat = 6
        /// 文字起こし行のハイライト背景を本文より少しだけ外に広げるための内寄せ量。
        /// 行にこの余白を持たせ、リスト側で同じだけ差し引くことで、
        /// 本文の左端がタイトル・メタ行と正確に揃う。
        static let rowHorizontalInset: CGFloat = 8
        /// タイムスタンプ列の幅。ここを固定するとテキストの左端が揃う。
        static let timestampColumnWidth: CGFloat = 56
        static let bodyLineSpacing: CGFloat = 6
    }
}

// MARK: - NSColor ヘルパ

extension NSColor {
    /// ライト/ダークで自動的に切り替わる色を 16 進で定義する。
    static func audioRecDynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
