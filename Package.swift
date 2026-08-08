// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "F8Goals",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "F8Goals",
            path: "Sources/F8Goals",
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        )
    ]
)
