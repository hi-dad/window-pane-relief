// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowPin",
    platforms: [.macOS(.v13)],
    // The app is built by scripts/build-app.sh; this keeps `swift build` and editors working too.
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "WindowPin",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/WindowPin",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
