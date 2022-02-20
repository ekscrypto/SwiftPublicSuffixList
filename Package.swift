// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "SwiftPublicSuffixList",
    platforms: [
            .macOS(.v10_12),
            .iOS(.v11),
            .tvOS(.v11)
        ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "SwiftPublicSuffixList",
            targets: ["SwiftPublicSuffixList"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftPublicSuffixList",
            dependencies: []),
        .testTarget(
            name: "SwiftPublicSuffixListTests",
            dependencies: ["SwiftPublicSuffixList"]),
    ]
)
