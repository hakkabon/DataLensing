// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DataLensing",
    platforms: [
        .macOS(.v14), .iOS(.v17), .macCatalyst(.v16),
    ],
    products: [
        .library(name: "DataLensing", targets: ["DataLensing"]),
        .executable(name: "data-lensing-app", targets: ["DataLensingApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hakkabon/Swift-DataLens.git", .upToNextMinor(from:"0.6.2")),
    ],
    targets: [
        .target(
            name: "DataLensing",
            dependencies: [
                .product(name: "DataLens", package: "Swift-DataLens"),
            ]
        ),
        .executableTarget(
            name: "DataLensingApp",
            dependencies: [
                .product(name: "DataLens", package: "Swift-DataLens"),
            ],
            path: "Sources/DataLensingApp"
        ),
        .testTarget(
            name: "DataLensingTests",
            dependencies: ["DataLensing"]
        ),
    ]
)
