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
        .executableTarget(
            name: "puremac",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/puremac"
        ),
        .testTarget(
            name: "puremacTests",
            dependencies: ["puremac"],
            path: "Tests/puremacTests"
        ),
    ]
)
