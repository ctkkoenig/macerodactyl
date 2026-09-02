// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacerodactylKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacerodactylKit", targets: ["MacerodactylKit"]),
        .library(name: "MacerodactylPanel", targets: ["MacerodactylPanel"]),
        .executable(name: "kitcheck", targets: ["KitCheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-auth.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "MacerodactylKit",
            resources: [
                .copy("Resources/wordmark-light.png"),
                .copy("Resources/wordmark-dark.png"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "MacerodactylPanel",
            dependencies: [
                "MacerodactylKit",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdAuth", package: "hummingbird-auth"),
                .product(name: "HummingbirdBcrypt", package: "hummingbird-auth"),
            ]
        ),
        .executableTarget(
            name: "KitCheck",
            dependencies: ["MacerodactylKit"]
        ),
        .executableTarget(
            name: "PanelTool",
            dependencies: ["MacerodactylKit", "MacerodactylPanel"]
        ),
        .testTarget(
            name: "MacerodactylKitTests",
            dependencies: ["MacerodactylKit"]
        ),
        .testTarget(
            name: "MacerodactylPanelTests",
            dependencies: [
                "MacerodactylPanel",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
