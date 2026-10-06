// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],  // @Observable, SettingsLink / openSettings, NSApp.activate()
    products: [
        .library(name: "TokenBarCore", targets: ["TokenBarCore"]),
        .executable(name: "tokenbar", targets: ["TokenBarCLI"]),
        // Not "TokenBar": it would collide with "tokenbar" in .build/<config>/ on case-insensitive APFS.
        // The bundling script renames the binary to Contents/MacOS/TokenBar.
        .executable(name: "TokenBarApp", targets: ["TokenBarApp"]),
    ],
    targets: [
        // Non-UI logic stays nonisolated: Sendable value types + async APIs, usable from any actor.
        .target(name: "TokenBarCore"),
        .executableTarget(name: "TokenBarCLI", dependencies: ["TokenBarCore"]),
        .executableTarget(
            name: "TokenBarApp",
            dependencies: ["TokenBarCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]),  // SE-0466; requires tools 6.2
        // swift-testing. With Command Line Tools only, run via scripts/test.sh (needs CLI flags, see there).
        .testTarget(name: "TokenBarCoreTests", dependencies: ["TokenBarCore"]),
    ],
    swiftLanguageModes: [.v6]
)
