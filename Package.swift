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
        .target(
            name: "ObjCExceptionCatch",
            path: "Sources/ObjCExceptionCatch",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "CCSpace",
            dependencies: ["ObjCExceptionCatch"],
            path: "Sources/CCSpace"
        ),
        .testTarget(
            name: "CCSpaceTests",
            dependencies: ["CCSpace"],
            path: "Tests/CCSpaceTests"
        )
    ]
)
