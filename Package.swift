// swift-tools-version:5.9
import PackageDescription

let package = Package(
            name: "Flare",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
    ],
    targets: [
        .executableTarget(
    name: "Flare",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            path: "Sources",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
