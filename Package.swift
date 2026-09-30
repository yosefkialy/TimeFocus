// swift-tools-version: 5.10
import PackageDescription

// TimeFocus — a fully local, ML-driven focus assistant for macOS.
// Built with SwiftPM only (no Xcode project needed). See scripts/build_app.sh to produce TimeFocus.app.

// The ML code is unusably slow at -Onone, so it is optimised in debug builds too. No -wmo here: SwiftPM's debug builds
// expect one object file per source file (release builds are whole-module anyway).
let optimize: [SwiftSetting] = [.unsafeFlags(["-O"], .when(configuration: .debug))]

let package = Package(
    name: "TimeFocus",
    defaultLocalization: "he",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TimeFocus", targets: ["TimeFocusApp"]),
        .executable(name: "FocusSelfTest", targets: ["FocusSelfTest"]),
        .executable(name: "EncoderCheck", targets: ["EncoderCheck"]),
        // Crash watchdog; its process name must not contain "TimeFocus" (see ThrottleWatchdog).
        .executable(name: "tf-watchdog", targets: ["TFWatchdog"]),
    ],
    targets: [
        // Transformer inference engine (multilingual sentence encoder, runs fully on-device).
        .target(
            name: "FocusTransformer",
            path: "Sources/FocusTransformer",
            swiftSettings: optimize,
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        // Pure ML building blocks: neural nets, clustering, hashing, temporal models.
        .target(
            name: "FocusML",
            path: "Sources/FocusML",
            swiftSettings: optimize,
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        // System integration, storage, learning pipeline, focus logic, interventions.
        .target(
            name: "FocusCore",
            dependencies: ["FocusML", "FocusTransformer"],
            path: "Sources/FocusCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Carbon"),
                .linkedFramework("NaturalLanguage"),
                // FoundationModels is weak-linked: the SDK/OS ABI can differ, we probe symbols at runtime.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        .executableTarget(
            name: "TimeFocusApp",
            dependencies: ["FocusCore"],
            path: "Sources/TimeFocusApp"
        ),
        .executableTarget(
            name: "FocusSelfTest",
            dependencies: ["FocusCore", "FocusML", "FocusTransformer"],
            path: "Sources/FocusSelfTest",
            swiftSettings: optimize
        ),
        .executableTarget(
            name: "EncoderCheck",
            dependencies: ["FocusTransformer"],
            path: "Sources/EncoderCheck",
            swiftSettings: optimize
        ),
        .executableTarget(
            name: "TFWatchdog",
            path: "Sources/TFWatchdog"
        ),
    ]
)
