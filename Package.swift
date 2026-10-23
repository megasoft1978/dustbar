// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DustBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DustBar",
            path: "Sources/DustBar",
            swiftSettings: [.unsafeFlags(["-Osize", "-wmo"], .when(configuration: .release))],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))]
        ),
        .testTarget(name: "DustBarTests", dependencies: ["DustBar"], path: "Tests/DustBarTests"),
    ]
)
