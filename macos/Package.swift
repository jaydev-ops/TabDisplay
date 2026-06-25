// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TabDisplayServer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TabDisplayServer", targets: ["TabDisplayServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.26.0")
    ],
    targets: [
        .target(
            name: "CoreGraphicsPrivate",
            dependencies: [],
            path: "Sources/CoreGraphicsPrivate"
        ),
        .executableTarget(
            name: "TabDisplayServer",
            dependencies: [
                "CoreGraphicsPrivate",
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Sources/TabDisplayServer"
        )
    ]
)
