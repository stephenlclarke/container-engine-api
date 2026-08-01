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

    #expect(session.operations == (1 ... 8).map { .data(UInt8($0)) } + [.close])
}

@Test
func `Docker input pump ignores writes following EOF`() async {
    let session = RecordingHijackSession()
    let pump = OrderedDockerInputPump(session: session)

    pump.write(Data([42]))
    pump.close()
    pump.write(Data([99]))
    await pump.wait()

    #expect(session.operations == [.data(42), .close])
}

private final class RecordingHijackSession: DockerHijackSession, @unchecked Sendable {
    enum Operation: Equatable {
        case data(UInt8)
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

    func write(_ data: Data) async throws {
        guard let byte = data.first else {
            return
        }
        try await Task.sleep(for: .milliseconds(Int64(10 - Int(byte))))
        lock.withLock {
            recorded.append(.data(byte))
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
