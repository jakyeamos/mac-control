// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacControl",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MacCtlCore", targets: ["MacCtlCore"]),
        .executable(name: "macctl", targets: ["MacCtlCLI"]),
        .executable(name: "macctld", targets: ["MacCtlDaemon"])
    ],
    targets: [
        .target(
            name: "MacCtlCore",
            path: "Sources/MacCtlCore"
        ),
        .executableTarget(
            name: "MacCtlCLI",
            dependencies: ["MacCtlCore"],
            path: "Sources/MacCtlCLI"
        ),
        .executableTarget(
            name: "MacCtlDaemon",
            dependencies: ["MacCtlCore"],
            path: "Sources/MacCtlDaemon"
        ),
        .testTarget(
            name: "MacCtlCoreTests",
            dependencies: ["MacCtlCore"],
            path: "Tests/MacCtlCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
