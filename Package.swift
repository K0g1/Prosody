// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Prosody",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ProsodyCore", targets: ["ProsodyCore"]),
        .executable(name: "ProsodyCLI", targets: ["ProsodyCLI"]),
        .executable(name: "Prosody", targets: ["ProsodyApp"]),
        .executable(name: "ProsodyValidation", targets: ["ProsodyValidation"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")
    ],
    targets: [
        .target(name: "ProsodyIPC"),
        .executableTarget(name: "ProsodyCLI", dependencies: ["ProsodyIPC"]),
        .target(
            name: "ProsodyCore",
            dependencies: [
                "ProsodyIPC",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/ProsodyCore",
            resources: [.copy("Resources/ProsodyMenuBar.svg"), .copy("Resources/SpeechModelPackages.json")],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "ProsodyApp",
            dependencies: ["ProsodyCore"],
            path: "Sources/ProsodyApp",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "ProsodyValidation",
            dependencies: [
                "ProsodyCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Tools/ProsodyValidation",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ProsodyCoreTests",
            dependencies: ["ProsodyCore"],
            path: "Tests/ProsodyCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
