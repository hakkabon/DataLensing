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
        // tag 0.6.2 content (verified: `git describe` == 0.6.2).
        // Switch back to `.upToNextMinor(from: "0.6.3")` once upstream
        // tags a release that depends on NumericCore by version.
        .package(url: "https://github.com/hakkabon/Swift-DataLens.git", revision: "403000751e3a0a547d82152f016b78bf90e42472"),
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
