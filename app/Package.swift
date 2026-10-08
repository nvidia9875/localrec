// swift-tools-version: 6.0
import PackageDescription

// Swift 5 言語モードを選択している。
// AVAudioPCMBuffer / CoreAudio の C コールバックは Sendable ではなく、
// Swift 6 モードでは本質的でないコンパイルエラーとの戦いに時間を取られるため。
// 並行性の正しさは actor と @MainActor の設計、およびテストで担保する。
let package = Package(
    name: "AudioRec",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AudioRecKit", targets: ["AudioRecKit"]),
        .executable(name: "AudioRec", targets: ["AudioRec"]),
    ],
    targets: [
        .target(
            name: "AudioRecKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioRec",
            dependencies: ["AudioRecKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioRecKitTests",
            dependencies: ["AudioRecKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
