// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],  // @Observable, openSettings, SMAppService status API
    products: [
        .library(name: "TokenBarCore", targets: ["TokenBarCore"]),
        .executable(name: "tokenbar", targets: ["TokenBarCLI"]),
        // Not "TokenBar": it would collide with "tokenbar" in .build/<config>/ on case-insensitive APFS.
        // scripts/bundle.sh renames the binary to Contents/MacOS/TokenBar.
        .executable(name: "TokenBarApp", targets: ["TokenBarApp"]),
    ],
    targets: [
        // Non-UI logic: nonisolated Sendable value types and async APIs. Side effects go through CoreEnvironment.
        .target(name: "TokenBarCore"),
        .executableTarget(name: "TokenBarCLI", dependencies: ["TokenBarCore"]),
        .executableTarget(
            name: "TokenBarApp",
            dependencies: ["TokenBarCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]),  // SE-0466; requires tools 6.2
        // swift-testing. With Command Line Tools only, run it via scripts/test.sh (it adds the required flags).
        // Fixtures are read from disk via #filePath, so they are excluded from the target.
        .testTarget(
            name: "TokenBarCoreTests",
            dependencies: ["TokenBarCore"],
            exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
