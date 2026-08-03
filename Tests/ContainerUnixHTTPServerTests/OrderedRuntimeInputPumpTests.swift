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
@testable import ContainerUnixHTTPServer
import Foundation
import Testing

@Test
func `Docker input pump preserves bytes and EOF order`() async {
    let session = RecordingHijackSession()
    let pump = OrderedDockerInputPump(session: session)

    for value in UInt8(1) ... UInt8(8) {
        pump.write(Data([value]))
    }
    pump.close()
    await pump.wait()

    #expect(session.bytes == Data(UInt8(1) ... UInt8(8)))
    #expect(session.operations.last == .close)
}

@Test
func `Docker input pump ignores writes following EOF`() async {
    let session = RecordingHijackSession()
    let pump = OrderedDockerInputPump(session: session)

    pump.write(Data([42]))
    pump.close()
    #expect(pump.write(Data([99])))
    await pump.wait()

    #expect(session.operations == [.data(Data([42])), .close])
}

@Test
func `Docker input pump cancels instead of dropping bytes past its bound`() async throws {
    let session = BlockingHijackSession()
    let pump = OrderedDockerInputPump(session: session)
    var rejected = false
    let chunk = Data(
        repeating: 0x5A,
        count: OrderedDockerInputPump.maximumInputChunkBytes
    )

    for _ in 0 ... OrderedDockerInputPump.maximumPendingBytes / chunk.count + 1 {
        if !pump.write(chunk) {
            rejected = true
            break
        }
    }

    #expect(rejected)
    let deadline = ContinuousClock.now + .seconds(1)
    while !session.cancelled, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.cancelled)
    pump.cancel()
    await pump.wait()
}

private final class RecordingHijackSession: DockerHijackSession, @unchecked Sendable {
    enum Operation: Equatable {
        case data(Data)
        case close
    }

    let frames = AsyncThrowingStream<DockerStreamFrame, any Error> { continuation in
        continuation.finish()
    }

    private let lock = NSLock()
    private var recorded: [Operation] = []

    var operations: [Operation] {
        lock.withLock { recorded }
    }

    var bytes: Data {
        lock.withLock {
            recorded.reduce(into: Data()) { result, operation in
                if case let .data(data) = operation {
                    result.append(data)
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock {
            recorded.append(.data(data))
        }
    }

    func closeStandardInput() {
        lock.withLock {
            recorded.append(.close)
        }
    }

    func wait() async throws -> Int32 {
        0
    }

    func cancel() {}
}

private final class BlockingHijackSession: DockerHijackSession, @unchecked Sendable {
    let frames = AsyncThrowingStream<DockerStreamFrame, any Error> { continuation in
        continuation.finish()
    }

    private let lock = NSLock()
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation
    private var didCancel = false

    init() {
        (gate, gateContinuation) = AsyncStream<Void>.makeStream()
    }

    var cancelled: Bool {
        lock.withLock { didCancel }
    }

    func write(_: Data) async throws {
        for await _ in gate {
            return
        }
    }

    func closeStandardInput() {}

    func wait() async throws -> Int32 {
        0
    }

    func cancel() {
        lock.withLock {
            didCancel = true
        }
        gateContinuation.finish()
    }
}
