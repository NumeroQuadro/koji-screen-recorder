// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Koji",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "Koji",
            targets: ["Koji"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "Koji",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icns",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
            ]
        ),
        .testTarget(
            name: "KojiTests",
            dependencies: ["Koji"],
            path: "tests/KojiTests"
        ),
    ]
)
