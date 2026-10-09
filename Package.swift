// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AuraSense",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "AuraSense", targets: ["AuraSense"]),
        .library(name: "AuraSenseCore", targets: ["AuraSenseCore"]),
    ],
    targets: [
        .target(
            name: "AuraSenseCore",
            path: "Sources/AuraSenseCore"
        ),
        .executableTarget(
            name: "AuraSense",
            dependencies: ["AuraSenseCore"],
            path: "Sources/AuraSense"
        ),
        .testTarget(
            name: "AuraSenseTests",
            dependencies: ["AuraSenseCore"],
            path: "Tests/AuraSenseTests",
            swiftSettings: [
                .unsafeFlags([
                    "-Xfrontend", "-load-resolved-plugin",
                    "-Xfrontend", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib##TestingMacros"
                ])
            ]
        )
    ]
)
