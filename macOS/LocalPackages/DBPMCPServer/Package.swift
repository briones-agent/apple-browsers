// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "DBPMCPServer",
    platforms: [
        .macOS("13.0")
    ],
    products: [
        .executable(
            name: "dbp-mcp-server",
            targets: ["DBPMCPServer"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "DBPMCPServer",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
