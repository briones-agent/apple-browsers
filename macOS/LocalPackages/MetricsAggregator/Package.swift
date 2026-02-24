// swift-tools-version: 5.9
//
//  Package.swift
//
//  Copyright © 2025 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this code except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//

import PackageDescription

let package = Package(
    name: "MetricsAggregatorMac",
    platforms: [
        .macOS("11.4")
    ],
    products: [
        .library(name: "MetricsAggregatorMac", targets: ["MetricsAggregatorMac"])
    ],
    dependencies: [
        .package(path: "../../../SharedPackages/BrowserServicesKit")
    ],
    targets: [
        .target(
            name: "MetricsAggregatorMac",
            dependencies: [
                .product(name: "Common", package: "BrowserServicesKit"),
                .product(name: "GRDB", package: "BrowserServicesKit")
            ],
            path: "Sources",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ]
)
