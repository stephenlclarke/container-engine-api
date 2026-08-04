//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Darwin
import Foundation

public enum ContainerEngineHealthProbe {
    public static func ping(
        socketPath: String,
        timeoutMilliseconds: Int32 = 1000
    ) throws {
        guard timeoutMilliseconds > 0 else {
            throw ContainerEngineHealthProbeError.invalidTimeout
        }
        let response = try request(
            socketPath: socketPath,
            target: "/_ping",
            timeoutMilliseconds: timeoutMilliseconds
        )
        guard
            response.status == 200,
            response.body.starts(with: Data("OK".utf8))
        else {
            throw ContainerEngineHealthProbeError.invalidResponse
        }
    }

    /// Verifies both the public listener and the selected private provider.
    /// Unlike `/_ping`, `/info` is dispatched through the fingerprint-bound
    /// provider session, so a stale or unavailable provider cannot pass.
    public static func systemInfo(
        socketPath: String,
        timeoutMilliseconds: Int32 = 1000
    ) throws {
        guard timeoutMilliseconds > 0 else {
            throw ContainerEngineHealthProbeError.invalidTimeout
        }
        let response = try request(
            socketPath: socketPath,
            target: "/info",
            timeoutMilliseconds: timeoutMilliseconds
        )
        guard
            response.status == 200,
            let object = try? JSONSerialization.jsonObject(with: response.body),
            object is [String: Any]
        else {
            throw ContainerEngineHealthProbeError.invalidResponse
        }
    }

    public static func waitUntilResponsive(
        socketPath: String,
        timeout: Duration
    ) async throws {
        try await waitUntilResponsive(
            socketPath: socketPath,
            timeout: timeout,
            probe: ping
        )
    }

    public static func waitUntilProviderResponsive(
        socketPath: String,
        timeout: Duration
    ) async throws {
        try await waitUntilResponsive(
            socketPath: socketPath,
            timeout: timeout,
            probe: systemInfo
        )
    }

    private static func waitUntilResponsive(
        socketPath: String,
        timeout: Duration,
        probe: (String, Int32) throws -> Void
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: (any Error)?
        repeat {
            do {
                let remaining = clock.now.duration(to: deadline)
                let timeoutMilliseconds = max(
                    1,
                    min(200, milliseconds(roundingUp: remaining))
                )
                try probe(socketPath, timeoutMilliseconds)
                return
            } catch {
                lastError = error
            }
            if clock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
        } while clock.now < deadline
        throw ContainerEngineHealthProbeError.timedOut(
            socketPath: socketPath,
            lastError: lastError.map(String.init(describing:)) ?? "unknown error"
        )
    }

    private static func request(
        socketPath: String,
        target: String,
        timeoutMilliseconds: Int32
    ) throws -> HTTPProbeResponse {
        let client = try UnixSocketClient(
            path: socketPath,
            timeoutMilliseconds: timeoutMilliseconds
        )
        defer { client.close() }
        try client.write(
            Data(
                "GET \(target) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                    .utf8
            )
        )
        return try client.readResponse()
    }

    private static func milliseconds(roundingUp duration: Duration) -> Int32 {
        guard duration > .zero else {
            return 1
        }
        let components = duration.components
        let whole = components.seconds * 1000
        let fractional = components.attoseconds / 1_000_000_000_000_000
        let remainder = components.attoseconds % 1_000_000_000_000_000
        let rounded = whole + fractional + (remainder == 0 ? 0 : 1)
        return Int32(clamping: rounded)
    }
}

public enum ContainerEngineHealthProbeError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case invalidResponse
    case invalidSocketPath(String)
    case invalidTimeout
    case responseTooLarge
    case timedOut(socketPath: String, lastError: String)

    public var description: String {
        switch self {
        case .invalidResponse:
            "Engine health probe returned an invalid response"
        case let .invalidSocketPath(path):
            "invalid Engine Unix socket path \(path)"
        case .invalidTimeout:
            "Engine health probe timeout must be positive"
        case .responseTooLarge:
            "Engine health probe response exceeded 1 MiB"
        case let .timedOut(socketPath, lastError):
            "Engine health probe at \(socketPath) timed out: \(lastError)"
        }
    }
}

private final class UnixSocketClient {
    private static let maximumResponseBytes = 1024 * 1024

    private var descriptor: Int32
    private let deadline: ContinuousClock.Instant

    init(path: String, timeoutMilliseconds: Int32) throws {
        let pathCapacity = withUnsafeBytes(of: sockaddr_un().sun_path) {
            $0.count
        }
        guard
            path.hasPrefix("/"),
            !path.contains("\0"),
            path.utf8.count < pathCapacity
        else {
            throw ContainerEngineHealthProbeError.invalidSocketPath(path)
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Self.posixError()
        }
        deadline = ContinuousClock.now
            + .milliseconds(Int64(timeoutMilliseconds))
        do {
            var noSignal: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))
            ) == 0 else {
                throw Self.posixError()
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard
                flags >= 0,
                fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
            else {
                throw Self.posixError()
            }
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                path.withCString { value in
                    bytes.copyMemory(
                        from: UnsafeRawBufferPointer(
                            start: value,
                            count: path.utf8.count + 1
                        )
                    )
                }
            }
            let result = withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else {
                    throw Self.posixError()
                }
                try wait(for: Int16(POLLOUT))
                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(
                    MemoryLayout.size(ofValue: socketError)
                )
                guard
                    getsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_ERROR,
                        &socketError,
                        &socketErrorLength
                    ) == 0
                else {
                    throw Self.posixError()
                }
                guard socketError == 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: socketError) ?? .EIO
                    )
                }
            }
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var written = 0
            while written < bytes.count {
                try wait(for: Int16(POLLOUT))
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if count < 0, errno == EAGAIN || errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw Self.posixError()
                }
                written += count
            }
        }
    }

    func readResponse() throws -> HTTPProbeResponse {
        var response = Data()
        let headerMarker = Data("\r\n\r\n".utf8)
        while response.range(of: headerMarker) == nil {
            guard try readChunk(into: &response) else {
                throw ContainerEngineHealthProbeError.invalidResponse
            }
        }
        guard
            let headerRange = response.range(of: headerMarker),
            let headerText = String(
                data: response[..<headerRange.lowerBound],
                encoding: .utf8
            )
        else {
            throw ContainerEngineHealthProbeError.invalidResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard
            let statusLine = lines.first,
            statusLine.hasPrefix("HTTP/1.1 "),
            let status = Int(statusLine.dropFirst("HTTP/1.1 ".count).prefix(3))
        else {
            throw ContainerEngineHealthProbeError.invalidResponse
        }
        let contentLength = lines.dropFirst().first { line in
            line.lowercased().hasPrefix("content-length:")
        }.flatMap { line in
            Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }
        if let contentLength {
            guard contentLength >= 0 else {
                throw ContainerEngineHealthProbeError.invalidResponse
            }
            let requiredCount = headerRange.upperBound + contentLength
            guard requiredCount <= Self.maximumResponseBytes else {
                throw ContainerEngineHealthProbeError.responseTooLarge
            }
            while response.count < requiredCount {
                guard try readChunk(into: &response) else {
                    throw ContainerEngineHealthProbeError.invalidResponse
                }
            }
            return HTTPProbeResponse(
                status: status,
                body: response.subdata(in: headerRange.upperBound ..< requiredCount)
            )
        }
        while try readChunk(into: &response) {}
        return HTTPProbeResponse(
            status: status,
            body: response.subdata(in: headerRange.upperBound ..< response.endIndex)
        )
    }

    func close() {
        guard descriptor >= 0 else {
            return
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private func wait(for events: Int16) throws {
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw POSIXError(.ETIMEDOUT)
            }
            let components = remaining.components
            let milliseconds = min(
                Int64(Int32.max),
                max(
                    1,
                    components.seconds * 1000
                        + components.attoseconds / 1_000_000_000_000_000
                )
            )
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: events,
                revents: 0
            )
            let result = poll(
                &pollDescriptor,
                1,
                Int32(milliseconds)
            )
            if result < 0, errno == EINTR {
                continue
            }
            guard result >= 0 else {
                throw Self.posixError()
            }
            guard result > 0 else {
                throw POSIXError(.ETIMEDOUT)
            }
            if pollDescriptor.revents & Int16(POLLNVAL | POLLERR) != 0 {
                throw POSIXError(.EIO)
            }
            return
        }
    }

    private func readChunk(into response: inout Data) throws -> Bool {
        guard response.count < Self.maximumResponseBytes else {
            throw ContainerEngineHealthProbeError.responseTooLarge
        }
        try wait(for: Int16(POLLIN))
        var bytes = [UInt8](
            repeating: 0,
            count: min(4096, Self.maximumResponseBytes - response.count)
        )
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count < 0, errno == EAGAIN || errno == EINTR {
            return true
        }
        guard count >= 0 else {
            throw Self.posixError()
        }
        guard count > 0 else {
            return false
        }
        response.append(contentsOf: bytes.prefix(count))
        return true
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private struct HTTPProbeResponse {
    let status: Int
    let body: Data
}
