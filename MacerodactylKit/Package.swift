// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacerodactylKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacerodactylKit", targets: ["MacerodactylKit"]),
        .library(name: "MacerodactylPanel", targets: ["MacerodactylPanel"]),
        .library(name: "MacerodactylUI", targets: ["MacerodactylUI"]),
        .executable(name: "kitcheck", targets: ["KitCheck"]),
        .executable(name: "macerodactyld", targets: ["macerodactyld"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-auth.git", from: "2.0.0"),
        // Already vendored transitively; declared directly so the panel can
        // serve HTTPS (self-signed) when bound to the LAN without a tunnel.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
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
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            // The web frontend: static HTML/CSS/JS served from the bundle (built
            // with safe DOM APIs, so a missed escape can't be a latent XSS).
            resources: [.copy("Resources/panel")]
        ),
        .target(
            name: "MacerodactylUI",
            dependencies: ["MacerodactylKit", "MacerodactylPanel"]
        ),
        .executableTarget(
            name: "KitCheck",
            dependencies: ["MacerodactylKit"]
        ),
        .executableTarget(
            name: "PanelTool",
            dependencies: ["MacerodactylKit", "MacerodactylPanel"]
        ),
        .executableTarget(
            name: "macerodactyld",
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
