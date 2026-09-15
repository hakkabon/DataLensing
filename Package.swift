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
        // Pinned by revision, not version: Swift-DataLens still pins
        // Swift-NumericCore by revision (see its DECISIONS #9), so any
        // stable-version requirement on Swift-DataLens fails to resolve
        // ("depends on an unstable-version package"). This revision IS
        // tag 0.7.1 content.
        // Switch back to `.upToNextMinor(from: "0.7.2")` once upstream
        // tags a release that depends on NumericCore by version.
        .package(url: "https://github.com/hakkabon/Swift-DataLens.git", revision: "0ccc80bab16725fbf86e489bbfbf1ef54a28adb7"),
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
