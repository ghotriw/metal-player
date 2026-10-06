// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalPlayer",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "MetalPlayer", targets: ["MetalPlayerApp"]),
        .library(name: "MetalPlayerCore", targets: ["MetalPlayerCore"]),
        .library(name: "MetalPlayerUI", targets: ["MetalPlayerUI"])
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavformat libavcodec libavutil libswresample",
            providers: [
                .brew(["ffmpeg"]),
                .apt(["libavformat-dev", "libavcodec-dev", "libavutil-dev", "libswresample-dev"])
            ]
        ),
        .target(
            name: "MetalPlayerCore",
            dependencies: ["CFFmpeg"],
            resources: [
                .process("Video/HDRToneMapping.metal")
            ]
        ),
        .target(
            name: "MetalPlayerUI",
            dependencies: ["MetalPlayerCore"]
        ),
        .executableTarget(
            name: "MetalPlayerApp",
            dependencies: ["MetalPlayerCore", "MetalPlayerUI"]
        ),
        .testTarget(
            name: "MetalPlayerCoreTests",
            dependencies: ["MetalPlayerCore"]
        )
    ]
)
