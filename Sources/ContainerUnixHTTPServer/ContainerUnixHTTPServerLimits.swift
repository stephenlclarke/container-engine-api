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

public struct ContainerUnixHTTPServerLimits: Equatable, Sendable {
    public static let production = ContainerUnixHTTPServerLimits(
        maximumRequestBodyBytes: 1_073_741_824,
        maximumBufferedRequestBodyBytes: 1_073_741_824,
        maximumPendingRequests: 32,
        maximumConnections: 128,
        maximumAggregateBufferedRequestBodyBytes: 2_147_483_648,
        requestReadTimeout: .seconds(30),
        idleConnectionTimeout: .seconds(300),
        gracefulDrainTimeout: .seconds(10)
    )

    public let maximumRequestBodyBytes: Int
    /// Per-connection body bytes retained across the active and pending requests.
    public let maximumBufferedRequestBodyBytes: Int
    public let maximumPendingRequests: Int
    /// Global accepted child-channel ceiling.
    public let maximumConnections: Int
    /// Body bytes retained across every accepted connection.
    public let maximumAggregateBufferedRequestBodyBytes: Int
    /// Maximum time from the first request byte through the request end.
    public let requestReadTimeout: Duration
    /// Maximum keep-alive time while no request or response is active.
    public let idleConnectionTimeout: Duration
    /// Time allowed for accepted work before child channels are force-closed.
    public let gracefulDrainTimeout: Duration

    /// Preserves the original API and derives a global budget of at least 2 GiB.
    public init(
        maximumRequestBodyBytes: Int,
        maximumBufferedRequestBodyBytes: Int,
        maximumPendingRequests: Int
    ) {
        self.init(
            maximumRequestBodyBytes: maximumRequestBodyBytes,
            maximumBufferedRequestBodyBytes: maximumBufferedRequestBodyBytes,
            maximumPendingRequests: maximumPendingRequests,
            maximumConnections: 128,
            maximumAggregateBufferedRequestBodyBytes: max(
                maximumBufferedRequestBodyBytes,
                2_147_483_648
            ),
            requestReadTimeout: .seconds(30),
            idleConnectionTimeout: .seconds(300),
            gracefulDrainTimeout: .seconds(10)
        )
    }

    public init(
        maximumRequestBodyBytes: Int,
        maximumBufferedRequestBodyBytes: Int,
        maximumPendingRequests: Int,
        maximumConnections: Int,
        maximumAggregateBufferedRequestBodyBytes: Int,
        requestReadTimeout: Duration,
        idleConnectionTimeout: Duration,
        gracefulDrainTimeout: Duration
    ) {
        precondition(maximumRequestBodyBytes > 0)
        precondition(maximumBufferedRequestBodyBytes >= maximumRequestBodyBytes)
        precondition(maximumPendingRequests > 0)
        precondition(maximumConnections > 0)
        precondition(
            maximumAggregateBufferedRequestBodyBytes
                >= maximumBufferedRequestBodyBytes
        )
        precondition(requestReadTimeout > .zero)
        precondition(idleConnectionTimeout > .zero)
        precondition(gracefulDrainTimeout > .zero)
        self.maximumRequestBodyBytes = maximumRequestBodyBytes
        self.maximumBufferedRequestBodyBytes = maximumBufferedRequestBodyBytes
        self.maximumPendingRequests = maximumPendingRequests
        self.maximumConnections = maximumConnections
        self.maximumAggregateBufferedRequestBodyBytes =
            maximumAggregateBufferedRequestBodyBytes
        self.requestReadTimeout = requestReadTimeout
        self.idleConnectionTimeout = idleConnectionTimeout
        self.gracefulDrainTimeout = gracefulDrainTimeout
    }
}
