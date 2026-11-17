import Foundation
import Testing
@testable import CmuxReadAloud

@Suite(.timeLimit(.minutes(1)))
struct ReadAloudParallelSynthesisTests {
    @Test
    func laterChunkFinishesFirstWithoutDelayingOrReorderingFirstChunkAudio() async throws {
        let fixture = ReadAloudParallelFixture(chunkCount: 2)
        defer { fixture.close() }
        let audio = ReadAloudParallelAudioRecorder()
        let sink = ReadAloudTestGate<Void>()
        let read = Task {
            try await fixture.client.synthesize(
                text: fixture.text, configuration: .init(), apiKey: fixture.apiKey
            ) { bytes in
                if await audio.append(bytes) == 1 { await sink.wait() }
            }
        }
        defer {
            read.cancel()
            Task { await sink.release(()) }
        }

        try await fixture.exchanges[0].started.wait()
        try await fixture.exchanges[1].started.wait()
        try await fixture.exchanges[0].send(sse(audio: "0100", status: 1))
        // Neither response is complete: the first request must already be audible.
        await sink.waitUntilEntered()
        try await fixture.exchanges[1].send(
            sse(audio: "03000400", status: 1) + sse(audio: "03000400", status: 2)
        )
        // No HTTP EOF is sent. Stopping proves the second request's final SSE
        // was parsed independently while the first request's sink is suspended.
        try await fixture.exchanges[1].stopped.wait()
        #expect(await audio.bytes == Data([1, 0]))
        try await fixture.exchanges[0].send(
            sse(audio: "0200", status: 1) + sse(audio: "01000200", status: 2)
        )
        try await fixture.exchanges[0].stopped.wait()
        #expect(await audio.bytes == Data([1, 0]))

        await sink.release(())
        try await read.value
        #expect(await audio.bytes == Data([1, 0, 2, 0, 3, 0, 4, 0]))
    }

    @Test
    func batchesNeverExceedTwoRequestsAndWaitForSinkBeforeAdvancing() async throws {
        let fixture = ReadAloudParallelFixture(chunkCount: 5)
        defer { fixture.close() }
        let audio = ReadAloudParallelAudioRecorder()
        let firstBatchSink = ReadAloudTestGate<Void>()
        let secondBatchSink = ReadAloudTestGate<Void>()
        let read = Task {
            try await fixture.client.synthesize(
                text: fixture.text, configuration: .init(), apiKey: fixture.apiKey
            ) { bytes in
                let count = await audio.append(bytes)
                if count == 1 { await firstBatchSink.wait() }
                if count == 3 { await secondBatchSink.wait() }
                fixture.timeline.consumePacket()
            }
        }
        defer {
            read.cancel()
            Task {
                await firstBatchSink.release(())
                await secondBatchSink.release(())
            }
        }

        try await fixture.exchanges[0].started.wait()
        try await fixture.exchanges[1].started.wait()
        try await fixture.exchanges[0].send(sse(audio: "0100", status: 1))
        await firstBatchSink.waitUntilEntered()
        try await fixture.exchanges[0].send(sse(audio: "0100", status: 2))
        try await fixture.exchanges[1].send(
            sse(audio: "0200", status: 1) + sse(audio: "0200", status: 2)
        )
        try await fixture.exchanges[0].stopped.wait()
        try await fixture.exchanges[1].stopped.wait()
        #expect(fixture.timeline.startedIndices.sorted() == [0, 1])
        await firstBatchSink.release(())

        try await fixture.exchanges[2].started.wait()
        try await fixture.exchanges[3].started.wait()
        try await fixture.exchanges[2].send(sse(audio: "0300", status: 1))
        await secondBatchSink.waitUntilEntered()
        try await fixture.exchanges[2].send(sse(audio: "0300", status: 2))
        try await fixture.exchanges[3].send(
            sse(audio: "0400", status: 1) + sse(audio: "0400", status: 2)
        )
        try await fixture.exchanges[2].stopped.wait()
        try await fixture.exchanges[3].stopped.wait()
        #expect(fixture.timeline.startedIndices.sorted() == [0, 1, 2, 3])
        await secondBatchSink.release(())

        try await fixture.exchanges[4].send(
            sse(audio: "0500", status: 1) + sse(audio: "0500", status: 2)
        )
        try await read.value
        try await fixture.exchanges[4].stopped.wait()
        #expect(fixture.timeline.startedIndices.sorted() == [0, 1, 2, 3, 4])
        #expect(fixture.timeline.maximumActiveRequests == 2)
        // Record at request start, rather than relying only on snapshots taken
        // while a task might not yet have been scheduled.
        #expect(fixture.timeline.consumedBeforeStarting(2) == 2)
        #expect(fixture.timeline.consumedBeforeStarting(3) == 2)
        #expect(fixture.timeline.consumedBeforeStarting(4) == 4)
        #expect(await audio.bytes == Data([1, 0, 2, 0, 3, 0, 4, 0, 5, 0]))
    }

    @Test
    func laterProviderFailureCancelsOpenSiblingAndSuspendedSink() async throws {
        let fixture = ReadAloudParallelFixture(chunkCount: 3)
        defer { fixture.close() }
        let audio = ReadAloudParallelAudioRecorder()
        let entered = ReadAloudParallelSignal()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let read = Task {
            try await fixture.client.synthesize(
                text: fixture.text, configuration: .init(), apiKey: fixture.apiKey
            ) { bytes in
                await audio.append(bytes)
                var iterator = release.makeAsyncIterator()
                await entered.signal()
                _ = await iterator.next()
                try Task.checkCancellation()
            }
        }
        defer { read.cancel() }

        try await fixture.exchanges[1].started.wait()
        try await fixture.exchanges[0].send(sse(audio: "0100", status: 1))
        try await entered.wait()
        try await fixture.exchanges[1].send(
            Data("data: {\"base_resp\":{\"status_code\":1004}}\n\n".utf8)
        )
        // Only task-group cancellation can release this sink. Neither request
        // receives HTTP EOF, and the first receives no provider completion.
        await #expect(throws: ReadAloudTransportError.provider(code: 1004)) { try await read.value }
        try await fixture.exchanges[0].stopped.wait()
        try await fixture.exchanges[1].stopped.wait()
        #expect(fixture.timeline.startedIndices.sorted() == [0, 1])
        #expect(await audio.bytes == Data([1, 0]))
    }

    @Test
    func sinkFailureCancelsBothOpenRequestsAndPreservesSinkError() async throws {
        let fixture = ReadAloudParallelFixture(chunkCount: 3)
        defer { fixture.close() }
        let audio = ReadAloudParallelAudioRecorder()
        let sink = ReadAloudTestGate<Void>()
        let read = Task {
            try await fixture.client.synthesize(
                text: fixture.text, configuration: .init(), apiKey: fixture.apiKey
            ) { bytes in
                await audio.append(bytes)
                await sink.wait()
                throw ReadAloudParallelSinkError.rejected
            }
        }
        defer {
            read.cancel()
            Task { await sink.release(()) }
        }

        try await fixture.exchanges[1].started.wait()
        try await fixture.exchanges[0].send(sse(audio: "0100", status: 1))
        await sink.waitUntilEntered()
        try await fixture.exchanges[0].send(sse(audio: "0200", status: 1))
        try await fixture.exchanges[1].send(sse(audio: "0300", status: 1))
        await sink.release(())

        await #expect(throws: ReadAloudParallelSinkError.rejected) { try await read.value }
        try await fixture.exchanges[0].stopped.wait()
        try await fixture.exchanges[1].stopped.wait()
        #expect(fixture.timeline.startedIndices.sorted() == [0, 1])
        #expect(await audio.bytes == Data([1, 0]))
    }

    @Test
    func callerCancellationStopsBothRequestsBeforeSinkReleaseAndDiscardsPendingAudio() async throws {
        let fixture = ReadAloudParallelFixture(chunkCount: 3)
        defer { fixture.close() }
        let audio = ReadAloudParallelAudioRecorder()
        let sink = ReadAloudTestGate<Void>()
        let read = Task {
            try await fixture.client.synthesize(
                text: fixture.text, configuration: .init(), apiKey: fixture.apiKey
            ) { bytes in
                if await audio.append(bytes) == 1 {
                    // Mimic an in-flight playback callback that acknowledges
                    // cancellation only after it has returned.
                    await sink.wait()
                }
            }
        }
        defer {
            read.cancel()
            Task { await sink.release(()) }
        }

        try await fixture.exchanges[1].started.wait()
        try await fixture.exchanges[0].send(sse(audio: "0100", status: 1))
        await sink.waitUntilEntered()
        try await fixture.exchanges[0].send(sse(audio: "0200", status: 1))
        try await fixture.exchanges[1].send(sse(audio: "0300", status: 1))
        read.cancel()
        // Cancellation must reach both network tasks without sink cooperation.
        try await fixture.exchanges[0].stopped.wait()
        try await fixture.exchanges[1].stopped.wait()
        await sink.release(())

        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(fixture.timeline.startedIndices.sorted() == [0, 1])
        #expect(await audio.bytes == Data([1, 0]))
    }

    private func sse(audio: String, status: Int) -> Data {
        Data("data: {\"data\":{\"audio\":\"\(audio)\",\"status\":\(status)},\"base_resp\":{\"status_code\":0}}\n\n".utf8)
    }
}

private enum ReadAloudParallelSinkError: Error, Equatable {
    case rejected
}

private actor ReadAloudParallelAudioRecorder {
    private var packets: [Data] = []

    @discardableResult
    func append(_ bytes: Data) -> Int {
        packets.append(bytes)
        return packets.count
    }

    var bytes: Data {
        packets.reduce(into: Data()) { $0.append($1) }
    }
}

private actor ReadAloudParallelSignal {
    private var signalled = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func wait() async throws {
        if signalled { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private struct ReadAloudParallelFixture: Sendable {
    let apiKey = UUID().uuidString
    let text: String
    let exchanges: [ReadAloudParallelExchange]
    let timeline: ReadAloudParallelTimeline
    let client: MiniMaxSpeechClient
    private let session: URLSession

    init(chunkCount: Int) {
        // Each paragraph fills one 600-UTF16-unit request. Distinct text routes
        // concurrent starts by content, never by nondeterministic arrival order.
        let chunks = (0..<chunkCount).map { String(repeating: String($0), count: 599) + "\n" }
        text = chunks.joined()
        let timeline = ReadAloudParallelTimeline()
        self.timeline = timeline
        exchanges = chunks.indices.map { ReadAloudParallelExchange(index: $0, timeline: timeline) }
        ReadAloudParallelURLProtocol.registry.insert(
            Dictionary(uniqueKeysWithValues: zip(chunks, exchanges)), for: apiKey
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadAloudParallelURLProtocol.self]
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        client = MiniMaxSpeechClient(session: session)
    }

    func close() {
        session.invalidateAndCancel()
        ReadAloudParallelURLProtocol.registry.remove(for: apiKey)
    }
}

// Track network starts/stops and successful sink returns synchronously so the
// batch-boundary assertions do not depend on actor-message scheduling order.
private final class ReadAloudParallelTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [(index: Int, consumed: Int)] = []
    private var active = 0
    private var maximumActive = 0
    private var consumed = 0

    func start(_ index: Int) {
        lock.withLock {
            starts.append((index, consumed))
            active += 1
            maximumActive = max(maximumActive, active)
        }
    }

    func stop() {
        lock.withLock { active -= 1 }
    }

    func consumePacket() {
        lock.withLock { consumed += 1 }
    }

    var startedIndices: [Int] {
        lock.withLock { starts.map(\.index) }
    }

    var maximumActiveRequests: Int {
        lock.withLock { maximumActive }
    }

    func consumedBeforeStarting(_ index: Int) -> Int? {
        lock.withLock { starts.first { $0.index == index }?.consumed }
    }
}

// Foundation objects stay within these synchronous, locked URLProtocol
// boundaries. Only Sendable PCM and signal notifications cross actor boundaries.
private final class ReadAloudParallelExchange: @unchecked Sendable {
    let started = ReadAloudParallelSignal()
    let stopped = ReadAloudParallelSignal()
    private let index: Int
    private let timeline: ReadAloudParallelTimeline
    private let lock = NSRecursiveLock()
    private var transport: ReadAloudParallelURLProtocol?
    private var isStopped = false

    init(index: Int, timeline: ReadAloudParallelTimeline) {
        self.index = index
        self.timeline = timeline
    }

    func start(_ transport: ReadAloudParallelURLProtocol) {
        lock.withLock {
            guard !isStopped else { return }
            self.transport = transport
            timeline.start(index)
            let response = HTTPURLResponse(
                url: transport.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            transport.client?.urlProtocol(transport, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        Task { await started.signal() }
    }

    func send(_ bytes: Data) async throws {
        try await started.wait()
        try lock.withLock {
            let transport = try #require(transport)
            transport.client?.urlProtocol(transport, didLoad: bytes)
        }
    }

    func stop() {
        lock.withLock {
            guard !isStopped else { return }
            isStopped = true
            if transport != nil { timeline.stop() }
            transport = nil
        }
        Task { await stopped.signal() }
    }
}

// Every ephemeral session uses a unique bearer key, so tests sharing the real
// provider URL never replace or consume one another's exchanges.
private final class ReadAloudParallelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: [String: ReadAloudParallelExchange]] = [:]

    func insert(_ exchanges: [String: ReadAloudParallelExchange], for apiKey: String) {
        lock.withLock { fixtures["Bearer \(apiKey)"] = exchanges }
    }

    func exchange(for authorization: String?, text: String) -> ReadAloudParallelExchange? {
        lock.withLock { authorization.flatMap { fixtures[$0]?[text] } }
    }

    func remove(for apiKey: String) {
        _ = lock.withLock { fixtures.removeValue(forKey: "Bearer \(apiKey)") }
    }
}

private final class ReadAloudParallelURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ReadAloudParallelRegistry()
    private let lock = NSRecursiveLock()
    private var exchange: ReadAloudParallelExchange?
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        true // Unmatched requests fail locally; no test can reach a real provider.
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        lock.withLock {
            guard !isStopped else { return }
            guard let body = Self.body(of: request),
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let text = object["text"] as? String,
                  let exchange = Self.registry.exchange(
                    for: request.value(forHTTPHeaderField: "Authorization"), text: text
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.exchange = exchange
            exchange.start(self)
        }
    }

    override func stopLoading() {
        let exchange = lock.withLock {
            isStopped = true
            let exchange = self.exchange
            self.exchange = nil
            return exchange
        }
        exchange?.stop()
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: 1_024)
            guard count >= 0 else { return nil }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
}
