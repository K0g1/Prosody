// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Prosody",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ProsodyCore", targets: ["ProsodyCore"]),
        .executable(name: "Prosody", targets: ["ProsodyApp"]),
        .executable(name: "ProsodyValidation", targets: ["ProsodyValidation"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .target(
            name: "ProsodyCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/ProsodyCore",
            resources: [.copy("Resources/ProsodyMenuBar.svg")],
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
