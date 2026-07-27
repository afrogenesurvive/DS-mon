// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dev_mon",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "dev_mon",
            resources: [
                .process("Assets.xcassets"),
                .process("dslogo.png"),
                .process("dslogo1.png"),
                .process("menu_icon.png"),
            ]
        )
    ]
)
