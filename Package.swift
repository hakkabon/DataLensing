// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DataLensing",
    platforms: [
        .macOS(.v14), .iOS(.v17), .macCatalyst(.v17),
    ],
    products: [
        .library(name: "DataLensing", targets: ["DataLensing"]),
        .executable(name: "data-lensing-app", targets: ["DataLensingApp"]),
    ],
    dependencies: [
        // Swift-DataLens 0.19.x adds unified GAM/multivariate model contracts,
        // calibration/stability evidence, and sparse-solver provenance.
        // Keep DataLensing on tagged compatible releases; source-head
        // compatibility is covered separately in CI.
        .package(url: "https://github.com/hakkabon/Swift-DataLens.git",
                 .upToNextMinor(from: "0.19.0")),
    ],
    targets: [
        .target(
            name: "DataTables"
        ),
        .target(
            name: "DataLensing",
            dependencies: [
                "DataTables",
                .product(name: "DataLens", package: "Swift-DataLens"),
            ]
        ),
        .executableTarget(
            name: "DataLensingApp",
            dependencies: [
                "DataLensing",
                "DataTables",
                .product(name: "DataLens", package: "Swift-DataLens"),
            ],
            resources: [
                .copy("SampleData"),
            ]
        ),
        .testTarget(
            name: "DataLensingTests",
            dependencies: [
                "DataLensing",
                "DataTables",
                .product(name: "DataLens", package: "Swift-DataLens"),
            ]
        ),
        .testTarget(
            name: "DataTablesTests",
            dependencies: ["DataTables"]
        ),
    ]
)
