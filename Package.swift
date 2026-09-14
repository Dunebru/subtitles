// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Subtitles",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored FluidAudio v0.15.7 (Apache 2.0): Parakeet TDT v3 speech recognition on CoreML.
        // scripts/fetch-deps.sh fetches the NemoTextProcessing xcframework into Vendor/FluidAudio/Binaries.
        .package(path: "Vendor/FluidAudio"),
    ],
    targets: [
        .executableTarget(
            name: "Subtitles",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Subtitles",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                // Translation exists from macOS 15; weak-link so the app still launches on macOS 14.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "Translation"]),
            ]
        ),
        .testTarget(name: "SubtitlesTests", dependencies: ["Subtitles"], path: "Tests/SubtitlesTests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
