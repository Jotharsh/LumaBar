// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LumaBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        // Pure logic: WiZ protocol, networking, models, sun/colour math. No UI.
        .target(name: "LumaBarCore"),
        // The menu bar app.
        .executableTarget(
            name: "LumaBar",
            dependencies: ["LumaBarCore", "KeyboardShortcuts"]
        ),
        .testTarget(name: "LumaBarCoreTests", dependencies: ["LumaBarCore"]),
        .testTarget(name: "LumaBarTests", dependencies: ["LumaBar", "LumaBarCore"]),
    ]
)
