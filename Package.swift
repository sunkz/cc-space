// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCSpace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CCSpace", targets: ["CCSpace"])
    ],
    targets: [
        .executableTarget(
            name: "CCSpace",
            path: "Sources/CCSpace"
        ),
        .testTarget(
            name: "CCSpaceTests",
            dependencies: ["CCSpace"],
            path: "Tests/CCSpaceTests"
        )
    ]
)
