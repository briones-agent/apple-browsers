// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  Package.swift
//
//  Copyright © 2026 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import PackageDescription

let package = Package(
    name: "DuckAILocalServer",
    platforms: [
        .iOS("15.0"),
        .macOS("11.4")
    ],
    products: [
        .library(name: "DuckAILocalServerAPI", targets: ["DuckAILocalServerAPI"]),
        .library(name: "DuckAILocalServerImpl", targets: ["DuckAILocalServerImpl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", exact: "0.26.2"),
    ],
    targets: [
        .target(
            name: "DuckAILocalServerAPI",
            dependencies: []
        ),
        .target(
            name: "DuckAILocalServerImpl",
            dependencies: [
                "DuckAILocalServerAPI",
                .product(name: "FlyingFox", package: "FlyingFox"),
            ]
        ),
        .testTarget(
            name: "DuckAILocalServerTests",
            dependencies: [
                "DuckAILocalServerAPI",
                "DuckAILocalServerImpl",
                .product(name: "FlyingFox", package: "FlyingFox"),
            ]
        ),
    ]
)
