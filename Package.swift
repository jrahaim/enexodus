// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "enexodus",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0")
    ],
    targets: [
        .executableTarget(
            name: "enexodus",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/enexodus"
        ),
        .testTarget(
            name: "enexodusTests",
            dependencies: ["enexodus"],
            path: "Tests/enexodusTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
