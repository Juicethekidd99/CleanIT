// swift-tools-version:5.9
// CleanIT for macOS. Build the app with ./build.sh (wraps `swift build` and assembles CleanIT.app).
import PackageDescription

let package = Package(
    name: "CleanIT",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "CleanIT",
            path: "Sources/CleanIT",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        )
    ]
)
