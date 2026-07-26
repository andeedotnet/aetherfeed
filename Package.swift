// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AetherFeed",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "10.4.0")
    ],
    targets: [
        .executableTarget(
            name: "AetherFeed",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FeedKit", package: "FeedKit")
            ]
        ),
        .testTarget(
            name: "AetherFeedTests",
            dependencies: ["AetherFeed"]
        )
    ]
)
