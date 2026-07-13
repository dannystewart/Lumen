// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "lumen",
            targets: ["Lumen"],
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor", from: "4.121.3"),
    ],
    targets: [
        .executableTarget(
            name: "Lumen",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
            ],
        ),
        .testTarget(
            name: "LumenTests",
            dependencies: ["Lumen"],
        ),
    ],
    swiftLanguageModes: [.v6],
)
