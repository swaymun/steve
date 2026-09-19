// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SteveNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SteveNative", targets: ["SteveNative"]),
        .library(name: "IMsgCore", targets: ["IMsgCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", revision: "964c300fb0736699ce945c9edb56ecd62eba27a3"),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git", from: "4.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0")
    ],
    targets: [
        .target(
            name: "IMsgCore",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit")
            ],
            path: "Vendor/IMsgCore",
            resources: [.copy("LICENSE")],
            linkerSettings: [
                .linkedFramework("Contacts"),
                .linkedFramework("ScriptingBridge")
            ]
        ),
        .executableTarget(
            name: "SteveNative",
            dependencies: [
                "IMsgCore",
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Sources/SteveNative",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SteveNativeTests",
            dependencies: ["SteveNative"],
            path: "Tests/SteveNativeTests"
        ),
        .testTarget(
            name: "IMsgCoreTests",
            dependencies: ["IMsgCore"],
            path: "Tests/IMsgCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
