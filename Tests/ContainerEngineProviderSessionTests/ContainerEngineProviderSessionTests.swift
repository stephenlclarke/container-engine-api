//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineWire
import Foundation
import Testing

@testable import ContainerEngineProviderSession
@testable import ContainerEngineRuntimeSPI

@Suite(.serialized)
struct ContainerEngineProviderSessionTests {
    @Test
    func `peer identity cache reuses only the exact executable image`() throws {
        let cache = ProviderSessionPeerIdentityCache(capacity: 4)
        let identity = Self.testCodeIdentity(identifier: "provider")
        var loadCount = 0
        let key = Self.peerProcessKey(processIdentifier: 41, startTimeSeconds: 100)

        let first = try cache.identity(for: key) {
            loadCount += 1
            return identity
        }
        let second = try cache.identity(for: key) {
            loadCount += 1
            return Self.testCodeIdentity(identifier: "unexpected")
        }
        let recycledPID = try cache.identity(
            for: Self.peerProcessKey(processIdentifier: 41, startTimeSeconds: 101)
        ) {
            loadCount += 1
            return Self.testCodeIdentity(identifier: "replacement")
        }
        let executedImage = try cache.identity(
            for: Self.peerProcessKey(
                processIdentifier: 41,
                startTimeSeconds: 101,
                processVersion: 2
            )
        ) {
            loadCount += 1
            return Self.testCodeIdentity(identifier: "executed")
        }
        let relocatedImage = try cache.identity(
            for: Self.peerProcessKey(
                processIdentifier: 41,
                startTimeSeconds: 101,
                processVersion: 2,
                executablePath: "/tmp/replacement"
            )
        ) {
            loadCount += 1
            return Self.testCodeIdentity(identifier: "relocated")
        }

        #expect(first == identity)
        #expect(second == identity)
        #expect(recycledPID.signingIdentifier == "replacement")
        #expect(executedImage.signingIdentifier == "executed")
        #expect(relocatedImage.signingIdentifier == "relocated")
        #expect(loadCount == 4)
    }

    @Test
    func `peer identity cache retains only successful bounded entries`() throws {
        let cache = ProviderSessionPeerIdentityCache(capacity: 2)
        let firstKey = Self.peerProcessKey(processIdentifier: 1)
        var firstLoadCount = 0

        #expect(throws: ProviderSessionTestError.expectedIdentityLoadFailure) {
            _ = try cache.identity(for: firstKey) {
                firstLoadCount += 1
                throw ProviderSessionTestError.expectedIdentityLoadFailure
            }
        }
        _ = try cache.identity(for: firstKey) {
            firstLoadCount += 1
            return Self.testCodeIdentity(identifier: "first")
        }
        _ = try cache.identity(for: Self.peerProcessKey(processIdentifier: 2)) {
            Self.testCodeIdentity(identifier: "second")
        }
        _ = try cache.identity(for: Self.peerProcessKey(processIdentifier: 3)) {
            Self.testCodeIdentity(identifier: "third")
        }
        _ = try cache.identity(for: firstKey) {
            firstLoadCount += 1
            return Self.testCodeIdentity(identifier: "first-reloaded")
        }

        #expect(firstLoadCount == 3)
    }

    @Test
    func `shutdown wakes an idle provider listener`() async throws {
        try await withServer { _, _, _ in }
    }

    private static func peerProcessKey(
        processIdentifier: pid_t,
        startTimeSeconds: UInt64 = 100,
        processVersion: UInt32 = 1,
        executablePath: String = "/tmp/provider"
    ) -> ProviderSessionPeerProcessKey {
        ProviderSessionPeerProcessKey(
            processIdentifier: processIdentifier,
            peerAuditToken: withUnsafeBytes(of: processVersion.bigEndian) {
                Data($0)
            },
            startTimeSeconds: startTimeSeconds,
            startTimeMicroseconds: 200,
            executablePath: executablePath
        )
    }

    private static func testCodeIdentity(
        identifier: String
    ) -> ProviderHandoffCodeIdentityV1 {
        ProviderHandoffCodeIdentityV1(
            signingIdentifier: identifier,
            teamIdentifier: nil,
            designatedRequirementDigestSHA256: "digest-\(identifier)"
        )
    }

    @Test
    func `provider ownership and handshake are exclusive`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let competing = try ContainerEngineProviderSessionServer(
                responder: TestResponder(),
                socketPath: socket,
                declaration: declaration,
                stateRootUUID: stateRoot
            )
            #expect(throws: (any Error).self) {
                try competing.start()
            }

            _ = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
        }
    }

    @Test
    func `provider forwards byte responses`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/bytes")
            )
            #expect(response.status == 200)
            if case .bytes(let data) = response.body {
                #expect(String(decoding: data, as: UTF8.self) == "provider-bytes")
            } else {
                Issue.record("expected bytes response")
            }
        }
    }

    @Test
    func `provider chunks request bodies larger than one frame`() async throws {
        let recorder = RequestBodyRecorder()
        try await withServer(responder: RequestBodyResponder(recorder: recorder)) {
            socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let body = Data(repeating: 0x5A, count: 36 * 1024 * 1024 + 1)
            let response = await client.respond(
                to: DockerHTTPRequest(
                    method: .post,
                    target: "/large-request",
                    body: body
                )
            )
            #expect(response.status == 204)
            let recorded = await recorder.body
            #expect(recorded == body)
        }
    }

    @Test
    func `provider request body framing fails closed`() throws {
        var accumulator = ProviderRequestBodyAccumulator(maximumBytes: 3)
        var body = ProviderSessionFrame(kind: .requestBody)
        body.data = Data("abc".utf8)
        #expect(try accumulator.consume(body) == nil)

        var overflow = ProviderSessionFrame(kind: .requestBody)
        overflow.data = Data("d".utf8)
        #expect(throws: ContainerEngineProviderSessionError.requestBodyTooLarge(4)) {
            try accumulator.consume(overflow)
        }

        let missing = ProviderSessionFrame(kind: .requestBody)
        #expect(
            throws: ContainerEngineProviderSessionError.protocolViolation(
                "request body frame omitted its data"
            )
        ) {
            var missingAccumulator = ProviderRequestBodyAccumulator(
                maximumBytes: 3
            )
            _ = try missingAccumulator.consume(missing)
        }

        let unexpected = ProviderSessionFrame(kind: .next)
        #expect(
            throws: ContainerEngineProviderSessionError.protocolViolation(
                "expected request body data or end, received next"
            )
        ) {
            var unexpectedAccumulator = ProviderRequestBodyAccumulator(
                maximumBytes: 3
            )
            _ = try unexpectedAccumulator.consume(unexpected)
        }

        let end = ProviderSessionFrame(kind: .requestEnd)
        var emptyAccumulator = ProviderRequestBodyAccumulator(maximumBytes: 3)
        #expect(try emptyAccumulator.consume(end) == Data())
    }

    @Test
    func `provider forwards pull based streams`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/stream")
            )
            if case .managedStream(let session) = response.body {
                #expect(try await session.nextChunk() == Data("first".utf8))
                #expect(try await session.nextChunk() == Data("second".utf8))
                #expect(try await session.nextChunk() == nil)
            } else {
                Issue.record("expected managed stream response")
            }
        }
    }

    @Test
    func `provider forwards large pull based stream chunks`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/large-stream")
            )
            if case .managedStream(let session) = response.body {
                #expect(try await session.nextChunk()?.count == 2 * 1024 * 1024 + 17)
                #expect(try await session.nextChunk() == nil)
            } else {
                Issue.record("expected large managed stream response")
            }
        }
    }

    @Test
    func `provider hijack accepts queued input`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            try await session.write(Data("queued-input".utf8))
            await session.cancel()
        }
    }

    @Test
    func `provider hijack relays queued input`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            try await session.write(Data("queued-input".utf8))
            var iterator = session.frames.makeAsyncIterator()
            let frame = try await iterator.next()
            #expect(frame?.channel == .standardOutput)
            #expect(frame?.data == Data("queued-input".utf8))
            await session.cancel()
        }
    }

    @Test
    func `provider hijack relays concurrent input`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            let output = Task {
                var iterator = session.frames.makeAsyncIterator()
                return try await iterator.next()
            }
            try await session.write(Data("concurrent-input".utf8))
            let frame = try await output.value
            #expect(frame?.channel == .standardOutput)
            #expect(frame?.data == Data("concurrent-input".utf8))
            await session.cancel()
        }
    }

    @Test
    func `provider hijack preserves delayed binary input and half close order`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let response = await client.respond(
                to: DockerHTTPRequest(method: .post, target: "/ordered-hijack")
            )
            guard case .hijack(let session, _) = response.body else {
                Issue.record("expected ordered hijack response")
                return
            }
            let output = Task {
                var iterator = session.frames.makeAsyncIterator()
                return try await iterator.next()
            }
            let chunks = [
                Data(repeating: 0x01, count: 1024 * 1024),
                Data(repeating: 0x02, count: 1024 * 1024),
                Data(repeating: 0x03, count: 1024 * 1024),
            ]
            for chunk in chunks {
                try await session.write(chunk)
            }
            try await session.closeStandardInput()
            let frame = try await output.value
            #expect(frame?.channel == .standardOutput)
            #expect(frame?.data == chunks.reduce(into: Data()) { $0.append($1) })
            await session.cancel()
        }
    }

    @Test
    func `provider hijack returns exit status`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            #expect(try await session.wait() == 0)
        }
    }

    @Test
    func `provider hijack relays input before returning exit status`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let session = try await Self.hijackSession(client: client)
            do {
                let output = Task {
                    var iterator = session.frames.makeAsyncIterator()
                    return try await iterator.next()
                }
                try await session.write(Data("input-before-output".utf8))
                let frame = try await output.value
                #expect(frame?.channel == .standardOutput)
                #expect(frame?.data == Data("input-before-output".utf8))
                #expect(try await session.wait() == 0)
            } catch {
                await session.cancel()
                throw error
            }
        }
    }

    @Test
    func `provider preserves websocket response identity and duplex bytes`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/websocket")
            )
            guard case .webSocket(let session) = response.body else {
                Issue.record("expected websocket response")
                return
            }
            let output = Task {
                var iterator = session.frames.makeAsyncIterator()
                return try await iterator.next()
            }
            try await session.write(Data("websocket-input".utf8))
            let frame = try await output.value
            #expect(frame?.channel == .standardOutput)
            #expect(frame?.data == Data("websocket-input".utf8))
            await session.cancel()
        }
    }

    @Test
    func `client rejects a different selected fingerprint`() async throws {
        try await withServer { socket, _, _ in
            let other = try ContainerEngineProviderFingerprint(
                declaration: Self.declaration(version: "2.0.0"),
                stateRootUUID: UUID()
            )
            let client = ContainerEngineProviderSessionClient(
                socketPath: socket,
                expectedFingerprint: other
            )

            let response = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/bytes")
            )
            #expect(response.status == 503)
        }
    }

    @Test
    func `provider transports bounded handoff control independently of Docker HTTP`() async throws {
        let responder = TestHandoffControlResponder()
        try await withServer(handoffControlResponder: responder) {
            socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let body = Data("{\"tokenID\":\"token-1\"}".utf8)
            let request = try ContainerEngineProviderHandoffControlRequestV1(
                requestID: "request-1",
                operation: .partPromote,
                bodyMediaType: "application/vnd.test.handoff-request+json",
                body: body
            )
            let result = try await client.performHandoffControl(
                request,
                body: body
            )

            #expect(result.response.requestID == request.requestID)
            #expect(result.response.disposition == .completed)
            #expect(result.body == Data("durable-receipt".utf8))
            #expect(await responder.receivedRequest() == request)
            #expect(await responder.receivedBody() == body)

            let dockerResponse = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/bytes")
            )
            #expect(dockerResponse.status == 200)
        }
    }

    @Test
    func `handoff control rejects changed body before transport`() throws {
        let body = Data("original".utf8)
        let request = try ContainerEngineProviderHandoffControlRequestV1(
            requestID: "request-1",
            operation: .rootPrepare,
            bodyMediaType: "application/vnd.test.handoff-request+json",
            body: body
        )
        #expect(throws: ContainerEngineProviderSessionError.invalidControlMessage) {
            try request.validate(body: Data("changed".utf8))
        }
    }

    @Test
    func `provider without handoff responder fails closed`() async throws {
        try await withServer { socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let body = Data("{}".utf8)
            let request = try ContainerEngineProviderHandoffControlRequestV1(
                requestID: "request-unsupported",
                operation: .rootSnapshot,
                bodyMediaType: "application/vnd.test.handoff-request+json",
                body: body
            )
            await #expect(throws: ContainerEngineProviderSessionError.self) {
                _ = try await client.performHandoffControl(request, body: body)
            }
        }
    }

    @Test
    func `provider control transfers and resumes a multi-frame bundle object`() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-session-object-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        let service = ContainerEngineProviderHandoffControlService(
            objectStore: ProviderHandoffBundleObjectStore(
                root: parent.appendingPathComponent("objects")
            )
        )
        try await withServer(handoffControlResponder: service) {
            socket, declaration, stateRoot in
            let client = try await Self.client(
                socket: socket,
                declaration: declaration,
                stateRoot: stateRoot
            )
            let bytes = Data(
                (0..<(3 * 1024 * 1024 + 31)).map {
                    UInt8(truncatingIfNeeded: $0)
                })
            let digest = ProviderHandoffDigest.sha256(bytes)
            let objectID = "sha256:\(digest)"
            let declareBody =
                try ProviderHandoffBundleObjectControlCodec
                .encodeDeclare(
                    ProviderHandoffBundleObjectDeclareRequestV1(
                        bundleObjectID: objectID,
                        transportByteLength: UInt64(bytes.count),
                        transportDigestSHA256: digest
                    )
                )
            var record =
                try ProviderHandoffBundleObjectControlCodec
                .decodeRecord(
                    try await Self.control(
                        client: client,
                        requestID: "object-declare",
                        operation: .objectDeclare,
                        body: declareBody
                    ).body
                )

            var offset = 0
            while offset < bytes.count {
                let upper = min(
                    offset
                        + ProviderHandoffBundleObjectControlCodec
                        .maximumTransportChunkBytes,
                    bytes.count
                )
                let appendBody =
                    try ProviderHandoffBundleObjectControlCodec
                    .encodeAppend(
                        ProviderHandoffBundleObjectAppendRequestV1(
                            bundleObjectID: objectID,
                            offset: UInt64(offset),
                            expectedObjectRevision: record.objectRevision,
                            bytes: bytes.subdata(in: offset..<upper)
                        )
                    )
                record =
                    try ProviderHandoffBundleObjectControlCodec
                    .decodeRecord(
                        try await Self.control(
                            client: client,
                            requestID: "object-append-\(offset)",
                            operation: .objectAppend,
                            body: appendBody
                        ).body
                    )
                offset = upper
            }

            let verifyBody =
                try ProviderHandoffBundleObjectControlCodec
                .encodeReference(
                    ProviderHandoffBundleObjectReferenceRequestV1(
                        bundleObjectID: objectID,
                        expectedObjectRevision: record.objectRevision
                    )
                )
            record = try ProviderHandoffBundleObjectControlCodec.decodeRecord(
                try await Self.control(
                    client: client,
                    requestID: "object-verify",
                    operation: .objectVerify,
                    body: verifyBody
                ).body
            )
            #expect(record.state == .verified)

            var reconstructed = Data()
            offset = 0
            while offset < bytes.count {
                let readBody =
                    try ProviderHandoffBundleObjectControlCodec
                    .encodeRead(
                        ProviderHandoffBundleObjectReadRequestV1(
                            bundleObjectID: objectID,
                            offset: UInt64(offset),
                            maximumBytes: UInt32(
                                ProviderHandoffBundleObjectControlCodec
                                    .maximumTransportChunkBytes
                            )
                        )
                    )
                let chunk =
                    try ProviderHandoffBundleObjectControlCodec
                    .decodeChunk(
                        try await Self.control(
                            client: client,
                            requestID: "object-read-\(offset)",
                            operation: .objectRead,
                            body: readBody
                        ).body
                    )
                #expect(chunk.offset == UInt64(offset))
                reconstructed.append(chunk.bytes)
                offset += chunk.bytes.count
            }
            #expect(reconstructed == bytes)
        }
    }

    @Test
    func `provider enrolls public handoff keys and proves private possession`() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "ceps-identity-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        let service =
            "io.github.stephenlclarke.container-engine.tests.\(UUID().uuidString)"
        let account = "provider-keys"
        defer {
            try? FileManager.default.removeItem(at: root)
            try? ProviderHandoffProviderKeyStore.removeForTesting(
                service: service,
                account: account
            )
        }
        let socket = root.appendingPathComponent("provider.sock").path
        let declaration = try Self.declaration()
        let stateRoot = UUID()
        let fingerprint = try ContainerEngineProviderFingerprint(
            declaration: declaration,
            stateRootUUID: stateRoot
        )
        let context = ProviderHandoffProviderKeyEnrollmentContextV1(
            providerFingerprint: fingerprint.digest,
            stateRootUUID: stateRoot.uuidString.lowercased(),
            owningBundleIdentifier:
                "io.github.stephenlclarke.container-engine.tests",
            codeRequirementDigestSHA256: String(repeating: "c", count: 64),
            teamIdentifier: "TESTTEAM",
            providerRegistrationDigestSHA256: String(
                repeating: "d",
                count: 64
            ),
            enrolledAtUnixSeconds: 100,
            notBeforeUnixSeconds: 100,
            notAfterUnixSeconds: 10_000
        )
        let identity = try ProviderHandoffProviderKeyStore(
            service: service,
            account: account
        ).loadOrCreate(context: context)
        let server = try ContainerEngineProviderSessionServer(
            responder: TestResponder(),
            handoffControlResponder:
                ContainerEngineProviderIdentityControlResponder(
                    identity: identity,
                    possessionProofStore:
                        ProviderHandoffPossessionProofStore(
                            root: root.appendingPathComponent(
                                "possession-proofs",
                                isDirectory: true
                            )
                        )
                ),
            socketPath: socket,
            declaration: declaration,
            stateRootUUID: stateRoot
        )
        try server.start()
        defer { Task { await server.shutdown() } }
        let client = try await Self.client(
            socket: socket,
            declaration: declaration,
            stateRoot: stateRoot
        )

        let snapshotBody =
            try ProviderHandoffProviderKeyControlCodec
            .encodeSnapshotRequest(
                ProviderHandoffProviderKeySnapshotRequestV1(
                    expectedProviderFingerprint: fingerprint.digest,
                    expectedStateRootUUID: stateRoot.uuidString.lowercased()
                )
            )
        let snapshotResult = try await Self.control(
            client: client,
            requestID: "key-snapshot",
            operation: .destinationKeySnapshot,
            mediaType: ProviderHandoffProviderKeyControlCodec
                .snapshotRequestMediaType,
            body: snapshotBody
        )
        #expect(
            snapshotResult.response.bodyMediaType
                == ProviderHandoffProviderKeyControlCodec.snapshotMediaType
        )
        let snapshot = try ProviderHandoffProviderKeyControlCodec.decodeSnapshot(
            snapshotResult.body
        )
        #expect(snapshot.context == context)
        #expect(snapshot.trustKeys == identity.trustKeys)

        let encryptionKey = try identity.trustKey(
            for: .destinationPayloadEncryption
        )
        let pending = try ProviderHandoffPossessionProofCodec.prepareChallenge(
            proofID: "proof-1",
            tokenID: "token-1",
            manifestID: "manifest-1",
            destinationProviderFingerprint: fingerprint.digest,
            destinationStateRootUUID: stateRoot.uuidString.lowercased(),
            destinationKeyPurpose: .destinationPayloadEncryption,
            destinationKeyID: encryptionKey.keyID,
            destinationPublicKey: encryptionKey.rawPublicKey,
            nonce: Data(repeating: 7, count: 24),
            challengePlaintext: Data(repeating: 11, count: 32),
            ephemeralPrivateKey: Data(repeating: 13, count: 32)
        )
        let possessionBody =
            try ProviderHandoffProviderKeyControlCodec
            .encodePossessionChallenge(
                ProviderHandoffProviderKeyPossessionRequestV1(
                    trustRegistryRevision: 9,
                    challenge: pending.transportChallenge
                )
            )
        #expect(
            !possessionBody.contains(
                Data(pending.challengePlaintext.base64EncodedString().utf8)
            )
        )
        let possessionResult = try await Self.control(
            client: client,
            requestID: "key-possession",
            operation: .destinationKeyPossession,
            mediaType: ProviderHandoffProviderKeyControlCodec
                .possessionChallengeMediaType,
            body: possessionBody
        )
        let proof =
            try ProviderHandoffProviderKeyControlCodec
            .decodePossessionProof(possessionResult.body)
        #expect(proof.destinationKeyID == encryptionKey.keyID)
        #expect(
            proof.responseDigestSHA256
                == (try ProviderHandoffProjections
                    .destinationPossessionResponseDigest(
                        proof,
                        challengePlaintext: pending.challengePlaintext
                    ))
        )
        let proofDigest =
            try ProviderHandoffProjections
            .destinationPossessionProofRecordDigest(proof)
        #expect(
            proof.destinationSignature.signedProjectionDigestSHA256
                == proofDigest
        )
        try ProviderHandoffCrypto.verify(
            proof.destinationSignature,
            publicKey: try identity.trustKey(
                for: .destinationPossessionSigning
            ).rawPublicKey
        )
        let proofRoot = root.appendingPathComponent(
            "possession-proofs",
            isDirectory: true
        )
        let proofStore = ProviderHandoffPossessionProofStore(root: proofRoot)
        #expect(try proofStore.load(proofDigest) == proof)
        #expect(try proofStore.store(proof) == proofDigest)
        var conflictingProof = proof
        conflictingProof.responseDigestSHA256 = String(repeating: "e", count: 64)
        #expect(
            throws: ProviderHandoffPossessionProofStoreError.conflictingProof
        ) {
            try proofStore.store(conflictingProof)
        }
        let proofURL = proofRoot.appendingPathComponent("\(proofDigest).json")
        let firstByte = try #require(Data(contentsOf: proofURL).first)
        let proofHandle = try FileHandle(forWritingTo: proofURL)
        try proofHandle.write(contentsOf: Data([firstByte ^ 1]))
        try proofHandle.synchronize()
        try proofHandle.close()
        #expect(
            throws: ProviderHandoffPossessionProofStoreError.invalidEncoding
        ) {
            try proofStore.load(proofDigest)
        }
        await server.shutdown()
    }

    private func withServer(
        responder: any DockerHTTPResponder = TestResponder(),
        handoffControlResponder:
            (any ContainerEngineProviderHandoffControlResponder)? = nil,
        _ operation: (
            _ socket: String,
            _ declaration: ContainerEngineProviderDeclaration,
            _ stateRoot: UUID
        ) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "ceps-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("provider.sock").path
        let declaration = try Self.declaration()
        let stateRoot = UUID()
        let server = try ContainerEngineProviderSessionServer(
            responder: responder,
            handoffControlResponder: handoffControlResponder,
            socketPath: socket,
            declaration: declaration,
            stateRootUUID: stateRoot
        )
        try server.start()

        do {
            try await operation(socket, declaration, stateRoot)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    private static func client(
        socket: String,
        declaration: ContainerEngineProviderDeclaration,
        stateRoot: UUID
    ) async throws -> ContainerEngineProviderSessionClient {
        let descriptor = try await ContainerEngineProviderSessionClient.probe(
            socketPath: socket
        )
        #expect(descriptor.fingerprint.declaration == declaration)
        #expect(descriptor.fingerprint.stateRootUUID == stateRoot)
        #expect(descriptor.codeIdentity == (try ProviderHandoffCodeIdentity.current()))
        return ContainerEngineProviderSessionClient(
            socketPath: socket,
            expectedFingerprint: descriptor.fingerprint
        )
    }

    private static func hijackSession(
        client: ContainerEngineProviderSessionClient
    ) async throws -> any DockerHijackSession {
        let response = await client.respond(
            to: DockerHTTPRequest(method: .post, target: "/hijack")
        )
        guard case .hijack(let session, let terminal) = response.body else {
            throw ProviderSessionTestError.expectedHijack
        }
        #expect(!terminal)
        return session
    }

    private static func control(
        client: ContainerEngineProviderSessionClient,
        requestID: String,
        operation: ContainerEngineProviderHandoffOperationV1,
        mediaType: String =
            ProviderHandoffBundleObjectControlCodec.requestMediaType,
        body: Data
    ) async throws -> ContainerEngineProviderHandoffControlResultV1 {
        let request = try ContainerEngineProviderHandoffControlRequestV1(
            requestID: requestID,
            operation: operation,
            bodyMediaType: mediaType,
            body: body
        )
        let result = try await client.performHandoffControl(
            request,
            body: body
        )
        #expect(result.response.disposition == .completed)
        return result
    }

    private static func declaration(
        version: String = "1.0.0"
    ) throws -> ContainerEngineProviderDeclaration {
        try ContainerEngineProviderDeclaration(
            profile: .stock,
            kind: .devcontainerStock,
            implementationVersion: version,
            runtimeRevisions: ["runtime": "test"],
            stateSchemaVersion: 1,
            capabilities: [
                ContainerEngineProviderCapability(
                    identifier: "engine.routes",
                    status: .native
                )
            ]
        )
    }
}

private actor TestHandoffControlResponder:
    ContainerEngineProviderHandoffControlResponder
{
    private var request: ContainerEngineProviderHandoffControlRequestV1?
    private var body = Data()

    func respond(
        to request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        context _: ContainerEngineProviderHandoffControlContextV1
    ) async -> ContainerEngineProviderHandoffControlResultV1 {
        self.request = request
        self.body = body
        let response = try! ContainerEngineProviderHandoffControlResponseV1(
            requestID: request.requestID,
            disposition: .completed,
            bodyMediaType: "application/vnd.test.handoff-response+octet-stream",
            body: Data("durable-receipt".utf8)
        )
        return ContainerEngineProviderHandoffControlResultV1(
            response: response,
            body: Data("durable-receipt".utf8)
        )
    }

    func receivedRequest() -> ContainerEngineProviderHandoffControlRequestV1? {
        request
    }

    func receivedBody() -> Data {
        body
    }
}

private actor RequestBodyRecorder {
    private(set) var body = Data()

    func record(_ body: Data) {
        self.body = body
    }
}

private struct RequestBodyResponder: DockerHTTPResponder {
    let recorder: RequestBodyRecorder

    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        await recorder.record(request.body)
        return DockerHTTPResponse(status: 204, body: .bytes(Data()))
    }
}

private enum ProviderSessionTestError: Error {
    case expectedIdentityLoadFailure
    case expectedHijack
}

private struct TestResponder: DockerHTTPResponder {
    func respond(to request: DockerHTTPRequest) async -> DockerHTTPResponse {
        if request.target == "/hijack" {
            return DockerHTTPResponse(
                status: 101,
                body: .hijack(TestHijackSession(), terminal: false)
            )
        }
        if request.target == "/websocket" {
            return DockerHTTPResponse(
                status: 101,
                body: .webSocket(TestHijackSession())
            )
        }
        if request.target == "/ordered-hijack" {
            return DockerHTTPResponse(
                status: 101,
                body: .hijack(OrderedEchoHijackSession(), terminal: false)
            )
        }
        if request.target == "/large-stream" {
            return DockerHTTPResponse(
                status: 200,
                body: .managedStream(
                    TestStreamSession(
                        chunks: [Data(repeating: 0x61, count: 2 * 1024 * 1024 + 17)]
                    )
                )
            )
        }
        if request.target == "/stream" {
            return DockerHTTPResponse(
                status: 200,
                body: .managedStream(TestStreamSession())
            )
        }
        return DockerHTTPResponse.text("provider-bytes")
    }
}

private actor TestStreamSession: DockerHTTPStreamSession {
    var chunks: [Data]

    init(chunks: [Data] = [Data("first".utf8), Data("second".utf8)]) {
        self.chunks = chunks
    }

    func nextChunk() -> Data? {
        chunks.isEmpty ? nil : chunks.removeFirst()
    }

    func close() {}
    func cancel() {}
}

private final class TestHijackSession: DockerHijackSession, @unchecked Sendable {
    private let state = TestHijackState()

    var frames: AsyncThrowingStream<DockerStreamFrame, any Error> {
        let state = state
        return AsyncThrowingStream(unfolding: {
            await state.nextFrame()
        })
    }

    func write(_ data: Data) async throws {
        await state.write(data)
    }

    func closeStandardInput() async throws {}

    func wait() async throws -> Int32 {
        0
    }

    func cancel() async {}
}

private actor TestHijackState {
    var input: Data?
    var continuation: CheckedContinuation<Data, Never>?
    var emitted = false

    func write(_ data: Data) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: data)
        } else {
            input = data
        }
    }

    func nextFrame() async -> DockerStreamFrame? {
        guard !emitted else {
            return nil
        }
        emitted = true
        let data: Data
        if let input {
            data = input
            self.input = nil
        } else {
            data = await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return DockerStreamFrame(channel: .standardOutput, data: data)
    }
}

private final class OrderedEchoHijackSession: DockerHijackSession, @unchecked Sendable {
    private let state = OrderedEchoHijackState()

    var frames: AsyncThrowingStream<DockerStreamFrame, any Error> {
        let state = state
        return AsyncThrowingStream(unfolding: {
            await state.nextFrame()
        })
    }

    func write(_ data: Data) async throws {
        if data.first == 0x01 {
            try await Task.sleep(for: .milliseconds(40))
        } else if data.first == 0x02 {
            try await Task.sleep(for: .milliseconds(20))
        }
        await state.write(data)
    }

    func closeStandardInput() async throws {
        await state.closeStandardInput()
    }

    func wait() async throws -> Int32 {
        0
    }

    func cancel() async {}
}

private actor OrderedEchoHijackState {
    private var continuation: CheckedContinuation<Data, Never>?
    private var emitted = false
    private var input = Data()
    private var inputClosed = false

    func write(_ data: Data) {
        input.append(data)
    }

    func closeStandardInput() {
        inputClosed = true
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: input)
        }
    }

    func nextFrame() async -> DockerStreamFrame? {
        guard !emitted else {
            return nil
        }
        emitted = true
        let output: Data =
            if inputClosed {
                input
            } else {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
        return DockerStreamFrame(channel: .standardOutput, data: output)
    }
}
