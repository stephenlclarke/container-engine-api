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

import ContainerEngineWire
import Foundation

/// Emits Docker's terminal wait payload after HTTP has acknowledged the
/// registered waiter.
actor DockerContainerWaitHTTPStream: DockerHTTPStreamSession {
    private enum State {
        case active
        case closed
        case cancelled
    }

    private let waitForCompletion: @Sendable () async throws -> DockerContainerWaitResult
    private let cancelWait: @Sendable () -> Void
    private var state = State.active

    init(
        waitForCompletion: @escaping @Sendable () async throws -> DockerContainerWaitResult,
        cancelWait: @escaping @Sendable () -> Void
    ) {
        self.waitForCompletion = waitForCompletion
        self.cancelWait = cancelWait
    }

    func nextChunk() async throws -> Data? {
        guard state == .active else {
            return nil
        }
        let cancelWait = cancelWait
        return try await withTaskCancellationHandler {
            do {
                var data = try DockerJSON.encoder.encode(
                    try await waitForCompletion()
                )
                data.append(UInt8(ascii: "\n"))
                state = .closed
                return data
            } catch is CancellationError {
                cancel()
                throw CancellationError()
            } catch {
                state = .closed
                throw error
            }
        } onCancel: {
            cancelWait()
        }
    }

    func close() {
        guard state == .active else {
            return
        }
        state = .closed
        cancelWait()
    }

    func cancel() {
        guard state == .active else {
            return
        }
        state = .cancelled
        cancelWait()
    }
}

/// Synchronizes the HTTP acknowledgement with the backend waiter
/// registration without delaying it until the container terminates.
final class DockerContainerWaitStartGate: @unchecked Sendable {
    enum Outcome: Sendable {
        case registered
        case terminal(DockerHTTPResponse)
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func registered() {
        resolve(.registered)
    }

    func completed(with response: DockerHTTPResponse) {
        resolve(.terminal(response))
    }

    func waitForOutcome() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func resolve(_ nextOutcome: Outcome) {
        let continuation: CheckedContinuation<Outcome, Never>?
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = nextOutcome
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: nextOutcome)
    }
}
