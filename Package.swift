// swift-tools-version: 6.0
import PackageDescription

let defaultSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "MetalPlayer",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "MetalPlayer", targets: ["MetalPlayerApp"]),
        .library(name: "MetalPlayerCore", targets: ["MetalPlayerCore"]),
        .library(name: "MetalPlayerUI", targets: ["MetalPlayerUI"]),
        .library(name: "MetalPlayerKit", targets: ["MetalPlayerKit"]),
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavformat libavcodec libavutil libswresample",
            providers: [
                .brew(["ffmpeg"]),
                .apt(["libavformat-dev", "libavcodec-dev", "libavutil-dev", "libswresample-dev"]),
            ]
        ),
        .target(
            name: "MetalPlayerCore",
            dependencies: ["CFFmpeg"],
            resources: [
                .process("Video/HDRToneMapping.metal")
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .target(
            name: "MetalPlayerUI",
            dependencies: ["MetalPlayerCore"],
            swiftSettings: defaultSwiftSettings
        ),
        .target(
            name: "MetalPlayerKit",
            dependencies: ["MetalPlayerCore", "MetalPlayerUI"],
            swiftSettings: defaultSwiftSettings
        ),
        .executableTarget(
            name: "MetalPlayerApp",
            dependencies: ["MetalPlayerCore", "MetalPlayerUI", "MetalPlayerKit"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .testTarget(
            name: "MetalPlayerCoreTests",
            dependencies: ["MetalPlayerCore"],
            swiftSettings: defaultSwiftSettings
        ),
    ]
)
