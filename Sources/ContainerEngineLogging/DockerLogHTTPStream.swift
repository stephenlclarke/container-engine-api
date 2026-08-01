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

actor DockerLogHTTPStream: DockerHTTPStreamSession {
    private enum State {
        case active
        case cancelled
        case closed
        case errorEmitted
    }

    private let reader: any DockerLogReadSession
    private let request: DockerLogReadRequest
    private var state = State.active

    init(reader: any DockerLogReadSession, request: DockerLogReadRequest) {
        self.reader = reader
        self.request = request
    }

    func nextChunk() async throws -> Data? {
        guard state == .active else {
            if state == .errorEmitted {
                state = .closed
            }
            return nil
        }
        do {
            while let record = try await reader.nextRecord() {
                try Task.checkCancellation()
                guard state == .active else {
                    return nil
                }
                guard includes(record.source) else {
                    continue
                }
                return try Self.format(
                    record,
                    request: request,
                    terminal: reader.terminal
                )
            }
            state = .closed
            await reader.close()
            return nil
        } catch is CancellationError {
            await cancel()
            throw CancellationError()
        } catch {
            state = .errorEmitted
            await reader.cancel()
            return try Self.systemError(
                message: Self.streamErrorMessage(error),
                terminal: reader.terminal
            )
        }
    }

    func close() async {
        guard state != .closed, state != .cancelled else {
            return
        }
        state = .closed
        await reader.close()
    }

    func cancel() async {
        guard state != .cancelled, state != .closed else {
            return
        }
        state = .cancelled
        await reader.cancel()
    }

    private func includes(_ source: DockerLogRecordSource) -> Bool {
        switch source {
        case .standardOutput:
            request.stdout
        case .standardError:
            request.stderr
        }
    }

    private static func format(
        _ record: DockerLogRecord,
        request: DockerLogReadRequest,
        terminal: Bool
    ) throws -> Data {
        var line = Data()
        if request.timestamps {
            line.append(contentsOf: timestampBytes(record.timestamp))
            line.append(UInt8(ascii: " "))
        }
        if request.details {
            line.append(contentsOf: attributeBytes(record.attributes))
            line.append(UInt8(ascii: " "))
        }
        line.append(record.line)
        return try DockerStreamFraming.encode(
            DockerStreamFrame(
                channel: record.source == .standardOutput
                    ? .standardOutput
                    : .standardError,
                data: line
            ),
            terminal: terminal
        )
    }

    private static func systemError(message: String, terminal: Bool) throws -> Data {
        try DockerStreamFraming.encode(
            DockerStreamFrame(
                channel: .systemError,
                data: Data("Error grabbing logs: \(message)\n".utf8)
            ),
            terminal: terminal
        )
    }

    private static func streamErrorMessage(_ error: any Error) -> String {
        if let error = error as? DockerLoggingBackendError {
            return error.message
        }
        return "logging stream failed"
    }

    private static func timestampBytes(_ timestamp: DockerLogTimestamp) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let date = Date(
            timeIntervalSince1970: TimeInterval(timestamp.secondsSinceUnixEpoch)
        )
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let formatted = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%09uZ",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            timestamp.nanoseconds
        )
        return Data(formatted.utf8)
    }

    private static func attributeBytes(_ attributes: [String: String]) -> Data {
        let values = attributes.sorted { lhs, rhs in
            lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }.map { key, value in
            "\(queryEscape(key))=\(queryEscape(value))"
        }
        return Data(values.joined(separator: ",").utf8)
    }

    private static func queryEscape(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var result = Data()
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                result.append(byte)
            case UInt8(ascii: " "):
                result.append(UInt8(ascii: "+"))
            default:
                result.append(UInt8(ascii: "%"))
                result.append(hexadecimal[Int(byte >> 4)])
                result.append(hexadecimal[Int(byte & 0x0F)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
