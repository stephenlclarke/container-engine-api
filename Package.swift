// swift-tools-version: 6.2
//===----------------------------------------------------------------------===//
// Copyright 2026 devcontainer and container-engine-api project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "container-engine-api",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ContainerEngineWire", targets: ["ContainerEngineWire"]),
        .library(name: "ContainerEngineRouter", targets: ["ContainerEngineRouter"]),
        .library(name: "ContainerEngineLogging", targets: ["ContainerEngineLogging"]),
        .library(name: "ContainerUnixHTTPServer", targets: ["ContainerUnixHTTPServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0")
    ],
    targets: [
        .target(name: "ContainerEngineWire"),
        .target(
            name: "ContainerEngineRouter",
            dependencies: ["ContainerEngineWire"]
        ),
        .target(
            name: "ContainerEngineLogging",
            dependencies: [
                "ContainerEngineRouter",
                "ContainerEngineWire"
            ]
        ),
        .target(
            name: "ContainerUnixHTTPServer",
            dependencies: [
                "ContainerEngineWire",
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "ContainerEngineWireTests",
            dependencies: ["ContainerEngineWire"]
        ),
        .testTarget(
            name: "ContainerEngineRouterTests",
            dependencies: [
                "ContainerEngineRouter",
                "ContainerEngineWire"
            ]
        ),
        .testTarget(
            name: "ContainerEngineLoggingTests",
            dependencies: [
                "ContainerEngineLogging",
                "ContainerEngineRouter",
                "ContainerEngineWire"
            ]
        ),
        .testTarget(
            name: "ContainerUnixHTTPServerTests",
            dependencies: [
                "ContainerEngineWire",
                "ContainerUnixHTTPServer",
                .product(name: "Logging", package: "swift-log")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
