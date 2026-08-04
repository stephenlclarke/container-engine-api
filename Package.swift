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
        .library(name: "ContainerEngineProviderSession", targets: ["ContainerEngineProviderSession"]),
        .library(name: "ContainerEngineGateway", targets: ["ContainerEngineGateway"]),
        .library(name: "ContainerEngineRuntimeSPI", targets: ["ContainerEngineRuntimeSPI"]),
        .library(name: "ContainerEngineService", targets: ["ContainerEngineService"]),
        .library(name: "ContainerUnixHTTPServer", targets: ["ContainerUnixHTTPServer"]),
        .executable(name: "container-engine", targets: ["ContainerEngineServiceExecutable"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.0"),
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
                "ContainerEngineWire",
            ]
        ),
        .target(
            name: "ContainerEngineRuntimeSPI",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "ContainerEngineProviderSession",
            dependencies: [
                "ContainerEngineRuntimeSPI",
                "ContainerEngineWire",
            ]
        ),
        .target(
            name: "ContainerEngineGateway",
            dependencies: [
                "ContainerEngineProviderSession",
                "ContainerEngineRouter",
                "ContainerEngineRuntimeSPI",
                "ContainerEngineWire",
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
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .target(
            name: "ContainerEngineService",
            dependencies: [
                "ContainerEngineGateway",
                "ContainerEngineProviderSession",
                "ContainerEngineRuntimeSPI",
                "ContainerUnixHTTPServer",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "ContainerEngineServiceExecutable",
            dependencies: ["ContainerEngineService"],
            path: "Sources/ContainerEngineServiceExecutable"
        ),
        .executableTarget(
            name: "ContainerEngineStreamingPerformanceFixture",
            dependencies: [
                "ContainerEngineGateway",
                "ContainerEngineLogging",
                "ContainerEngineProviderSession",
                "ContainerEngineRuntimeSPI",
                "ContainerEngineWire",
                "ContainerUnixHTTPServer",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tools/ContainerEngineStreamingPerformanceFixture"
        ),
        .testTarget(
            name: "ContainerEngineWireTests",
            dependencies: ["ContainerEngineWire"]
        ),
        .testTarget(
            name: "ContainerEngineRouterTests",
            dependencies: [
                "ContainerEngineRouter",
                "ContainerEngineWire",
            ]
        ),
        .testTarget(
            name: "ContainerEngineLoggingTests",
            dependencies: [
                "ContainerEngineLogging",
                "ContainerEngineRouter",
                "ContainerEngineWire",
            ]
        ),
        .testTarget(
            name: "ContainerEngineRuntimeSPITests",
            dependencies: ["ContainerEngineRuntimeSPI"]
        ),
        .testTarget(
            name: "ContainerEngineProviderSessionTests",
            dependencies: [
                "ContainerEngineProviderSession",
                "ContainerEngineRuntimeSPI",
                "ContainerEngineWire",
            ]
        ),
        .testTarget(
            name: "ContainerEngineGatewayTests",
            dependencies: [
                "ContainerEngineGateway",
                "ContainerEngineProviderSession",
                "ContainerEngineRouter",
                "ContainerEngineRuntimeSPI",
                "ContainerEngineWire",
                "ContainerUnixHTTPServer",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "ContainerEngineServiceTests",
            dependencies: [
                "ContainerEngineProviderSession",
                "ContainerEngineRuntimeSPI",
                "ContainerEngineService",
                "ContainerEngineWire",
            ]
        ),
        .testTarget(
            name: "ContainerUnixHTTPServerTests",
            dependencies: [
                "ContainerEngineWire",
                "ContainerUnixHTTPServer",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
