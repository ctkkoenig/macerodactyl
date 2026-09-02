// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacerodactylKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacerodactylKit", targets: ["MacerodactylKit"]),
        .executable(name: "kitcheck", targets: ["KitCheck"]),
    ],
    targets: [
        .target(
            name: "MacerodactylKit",
            resources: [.copy("Resources/logo-long.png")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "KitCheck",
            dependencies: ["MacerodactylKit"]
        ),
        .testTarget(
            name: "MacerodactylKitTests",
            dependencies: ["MacerodactylKit"]
        ),
    ]
)
