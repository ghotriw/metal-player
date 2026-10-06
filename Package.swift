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
        .target(
            name: "CFFmpeg",
            dependencies: [],
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ]
        ),
        .target(
            name: "MetalPlayerCore",
            dependencies: ["CFFmpeg"],
            resources: [
                .process("Video/HDRToneMapping.metal")
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-lavformat",
                    "-lavcodec",
                    "-lavutil"
                ])
            ]
        ),
        .target(
            name: "MetalPlayerUI",
            dependencies: ["MetalPlayerCore"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])
            ]
        ),
        .executableTarget(
            name: "MetalPlayerApp",
            dependencies: ["MetalPlayerCore", "MetalPlayerUI"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])
            ]
        ),
        .testTarget(
            name: "MetalPlayerCoreTests",
            dependencies: ["MetalPlayerCore"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])
            ]
        )
    ]
)
