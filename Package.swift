// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Launcher27B",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Launcher27B", targets: ["Launcher27B"])
    ],
    targets: [
        .executableTarget(
            name: "Launcher27B",
            path: "Sources/Launcher27B",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "Launcher27BTests",
            dependencies: ["Launcher27B"],
            path: "Tests/Launcher27BTests"
        )
    ]
)
