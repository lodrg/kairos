// swift-tools-version:6.0
import PackageDescription

// 平台抬到 macOS 15 是为了用上 MeshGradient / KeyframeAnimator / symbolEffect。
// 语言模式仍锁在 v5：Swift 6 严格并发会卡住 Carbon 热键的 C 回调和
// HotkeyManager.shared，那是另一件事，不混进视觉改动里。
let package = Package(
    name: "Mirrage",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Mirrage",
            path: "Sources/Mirrage",
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
