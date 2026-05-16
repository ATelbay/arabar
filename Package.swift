// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "arabar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "arabar",
            path: "arabar",
            exclude: ["Info.plist"],
            sources: ["App", "Logic", "Model", "DataSource", "UI", "Infra"],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "arabarTests",
            dependencies: ["arabar"],
            path: "Tests/arabarTests"
        ),
    ]
)
