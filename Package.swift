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
    ],
    // 显式锁定 Swift 6 语言模式:不写则由工具链默认决定,换机器/回退 Xcode 版本时
    // 会静默降级到 Swift 5 模式,Sendable 与 nonisolated(unsafe) 的诊断强度不一致,
    // 本地与 CI 可能得出不同结论。
    swiftLanguageModes: [.v6]
)
