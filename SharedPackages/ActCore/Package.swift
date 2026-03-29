// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ActCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v11),
    ],
    products: [
        .library(name: "ActCore", targets: ["ActCore"]),
    ],
    targets: [
        .target(
            name: "ActCore",
            dependencies: ["ActCoreBinary"],
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-no_compact_unwind"])
            ]
        ),
        .binaryTarget(
            name: "ActCoreBinary",
            path: "Sources/ActCoreBinary/ActCore.xcframework"
        ),
    ]
)
