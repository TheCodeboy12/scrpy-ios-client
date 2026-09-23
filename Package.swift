// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScrcpyKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ScrcpyKit",
            targets: ["ScrcpyKit"]
        ),
        .executable(
            name: "ScrcpyApp",
            targets: ["ScrcpyApp"]
        ),
        .executable(
            name: "ScrcpyTests",
            targets: ["ScrcpyTests"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ScrcpyKit",
            dependencies: [],
            path: "Sources/ScrcpyKit",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ScrcpyApp",
            dependencies: ["ScrcpyKit"],
            path: "Sources/ScrcpyApp",
            exclude: [
                "Info.plist"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ScrcpyTests",
            dependencies: ["ScrcpyKit"],
            path: "Sources/ScrcpyTests"
        )
    ]
)
