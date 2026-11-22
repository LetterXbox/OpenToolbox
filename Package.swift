// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenToolbox",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OpenToolboxCore", targets: ["OpenToolboxCore"]),
        .executable(name: "OpenToolbox", targets: ["OpenToolboxApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "OpenToolboxCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        .executableTarget(
            name: "OpenToolboxApp",
            dependencies: ["OpenToolboxCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OpenToolboxCoreTests",
            dependencies: ["OpenToolboxCore"]
        ),
        .testTarget(
            name: "OpenToolboxAppTests",
            dependencies: ["OpenToolboxApp", "OpenToolboxCore"]
        ),
    ]
)
