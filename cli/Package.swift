// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "puremac",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "puremac", targets: ["puremac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "TerminalUI",
            path: "Sources/TerminalUI"
        ),
        .executableTarget(
            name: "puremac",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "TerminalUI",
            ],
            path: "Sources/puremac"
        ),
        .testTarget(
            name: "TerminalUITests",
            dependencies: ["TerminalUI"],
            path: "Tests/TerminalUITests"
        ),
        .testTarget(
            name: "puremacTests",
            dependencies: ["puremac", "TerminalUI"],
            path: "Tests/puremacTests"
        ),
    ]
)
