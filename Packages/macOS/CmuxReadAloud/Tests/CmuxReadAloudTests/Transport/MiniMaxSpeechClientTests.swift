import Foundation
import Testing
@testable import CmuxReadAloud

@Suite(.timeLimit(.minutes(1)))
struct MiniMaxSpeechClientTests {
    @Test
    func finishesReceivingWhileSinkSuspendsThenDeliversEverySampleInOrder() async throws {
        let fixture = MiniMaxStreamFixture()
        defer { fixture.close() }
        let audio = MiniMaxStreamAudioRecorder()
        let sink = ReadAloudTestGate<Void>()
        let read = Task {
            try await fixture.client.stream(request: fixture.request) { bytes in
                if await audio.append(bytes) == 1 {
                    await sink.wait()
                }
            }
        }
        defer {
            read.cancel()
            Task { await sink.release(()) }
        }

        try await fixture.exchange.send(sse(audio: "01000200", status: 1))
        await sink.waitUntilEntered()
        let remainder = sse(audio: "ff", status: 1)
            + sse(audio: "800300", status: 1)
            + sse(audio: "0400", status: 1)
            + sse(audio: "01000200ff8003000400", status: 2)
        try await fixture.exchange.send(Data(remainder.prefix(19)))
        try await fixture.exchange.send(Data(remainder.dropFirst(19)))

        // No HTTP EOF is sent. Only parsing the final SSE status can close the
        // request, so this must happen before playback is allowed to continue.
        try await fixture.exchange.stopped.wait()
        #expect(await audio.packets == [Data([1, 0, 2, 0])])
        await sink.release(())
        try await read.value
        #expect(await audio.bytes == Data([1, 0, 2, 0, 0xff, 0x80, 3, 0, 4, 0]))
    }

    @Test
    func transportFailureCancelsSuspendedSinkWithoutWaitingForItsRelease() async throws {
        let fixture = MiniMaxStreamFixture()
        defer { fixture.close() }
        let audio = MiniMaxStreamAudioRecorder()
        let entered = MiniMaxStreamSignal()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let read = Task {
            try await fixture.client.stream(request: fixture.request) { bytes in
                await audio.append(bytes)
                var iterator = release.makeAsyncIterator()
                await entered.signal()
                _ = await iterator.next()
                try Task.checkCancellation()
            }
        }
        defer { read.cancel() }

        try await fixture.exchange.send(sse(audio: "0100", status: 1))
        try await entered.wait()
        try await fixture.exchange.fail(URLError(.networkConnectionLost))

        // The sink's stream is never released here; only cancellation can wake it.
        await #expect(throws: ReadAloudTransportError.network) { try await read.value }
        #expect(await audio.bytes == Data([1, 0]))
    }

    @Test
    func sinkFailureCancelsOpenRequestAndPreservesSinkError() async throws {
        let fixture = MiniMaxStreamFixture()
        defer { fixture.close() }
        let audio = MiniMaxStreamAudioRecorder()
        let sink = ReadAloudTestGate<Void>()
        let read = Task {
            try await fixture.client.stream(request: fixture.request) { bytes in
                await audio.append(bytes)
                await sink.wait()
                throw MiniMaxStreamSinkError.rejected
            }
        }
        defer {
            read.cancel()
            Task { await sink.release(()) }
        }

        try await fixture.exchange.send(sse(audio: "0100", status: 1))
        await sink.waitUntilEntered()
        try await fixture.exchange.send(sse(audio: "0200", status: 1))
        // The server leaves the request open: the sink failure must cancel it,
        // rather than waiting for another network byte or a completion event.
        await sink.release(())
        try await fixture.exchange.stopped.wait()
        await #expect(throws: MiniMaxStreamSinkError.rejected) { try await read.value }
        #expect(await audio.bytes == Data([1, 0]))
    }

    @Test
    func callerCancellationDoesNotDeliverAudioAlreadyBufferedBehindSink() async throws {
        let fixture = MiniMaxStreamFixture()
        defer { fixture.close() }
        let audio = MiniMaxStreamAudioRecorder()
        let sink = ReadAloudTestGate<Void>()
        let read = Task {
            try await fixture.client.stream(request: fixture.request) { bytes in
                if await audio.append(bytes) == 1 {
                    // Deliberately acknowledge cancellation only after release,
                    // like a playback callback that is already in flight.
                    await sink.wait()
                }
            }
        }
        defer {
            read.cancel()
            Task { await sink.release(()) }
        }

        try await fixture.exchange.send(sse(audio: "0100", status: 1))
        await sink.waitUntilEntered()
        try await fixture.exchange.send(
            sse(audio: "02000300", status: 1) + sse(audio: nil, status: 2)
        )
        // Receiving is complete, so the later samples are definitely queued,
        // not merely waiting to be delivered by the URLProtocol fixture.
        try await fixture.exchange.stopped.wait()
        read.cancel()
        await sink.release(())

        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(await audio.bytes == Data([1, 0]))
    }

    private func sse(audio: String?, status: Int) -> Data {
        let encodedAudio = audio.map { "\"\($0)\"" } ?? "null"
        return Data("data: {\"data\":{\"audio\":\(encodedAudio),\"status\":\(status)},\"base_resp\":{\"status_code\":0}}\n\n".utf8)
    }
}

private enum MiniMaxStreamSinkError: Error, Equatable {
    case rejected
}

private actor MiniMaxStreamAudioRecorder {
    private(set) var packets: [Data] = []

    @discardableResult
    func append(_ bytes: Data) -> Int {
        packets.append(bytes)
        return packets.count
    }

    var bytes: Data {
        packets.reduce(into: Data()) { $0.append($1) }
    }
}

private actor MiniMaxStreamSignal {
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

private struct MiniMaxStreamFixture: Sendable {
    let exchange: MiniMaxStreamExchange
    let request: URLRequest
    let client: MiniMaxSpeechClient
    private let session: URLSession

    init() {
        let url = URL(string: "https://read-aloud.test.invalid/\(UUID().uuidString)")!
        exchange = MiniMaxStreamExchange()
        request = URLRequest(url: url)
        MiniMaxStreamURLProtocol.registry.insert(exchange, for: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MiniMaxStreamURLProtocol.self]
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        client = MiniMaxSpeechClient(session: session)
    }

    func close() {
        session.invalidateAndCancel()
        MiniMaxStreamURLProtocol.registry.remove(for: request.url!)
    }
}

// Keep Foundation's synchronous URLProtocol callbacks behind one lock instead
// of transferring a live protocol/client pair across an actor boundary.
private final class MiniMaxStreamExchange: @unchecked Sendable {
    let stopped = MiniMaxStreamSignal()
    private let started = MiniMaxStreamSignal()
    private let lock = NSRecursiveLock()
    private var transport: MiniMaxStreamURLProtocol?
    private var isStopped = false

    func start(_ transport: MiniMaxStreamURLProtocol) {
        lock.withLock {
            guard !isStopped else { return }
            self.transport = transport
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
        try forward { transport in
            transport.client?.urlProtocol(transport, didLoad: bytes)
        }
    }

    func fail(_ error: URLError) async throws {
        try await started.wait()
        try forward { transport in
            self.transport = nil
            transport.client?.urlProtocol(transport, didFailWithError: error)
        }
    }

    private func forward(_ body: (MiniMaxStreamURLProtocol) -> Void) throws {
        try lock.withLock {
            let transport = try #require(transport)
            body(transport)
        }
    }

    func stop() {
        lock.withLock {
            isStopped = true
            transport = nil
        }
        Task { await stopped.signal() }
    }
}

// URLProtocol's synchronous entry points use a locked registry, keyed by a fresh
// URL per test. Parallel tests never reset or consume one another's fixtures.
private final class MiniMaxStreamRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [URL: MiniMaxStreamExchange] = [:]

    func insert(_ exchange: MiniMaxStreamExchange, for url: URL) {
        lock.withLock { exchanges[url] = exchange }
    }

    func exchange(for url: URL?) -> MiniMaxStreamExchange? {
        lock.withLock { url.flatMap { exchanges[$0] } }
    }

    func remove(for url: URL) {
        _ = lock.withLock { exchanges.removeValue(forKey: url) }
    }
}

private final class MiniMaxStreamURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = MiniMaxStreamRegistry()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "read-aloud.test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let exchange = Self.registry.exchange(for: request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        exchange.start(self)
    }

    override func stopLoading() {
        guard let exchange = Self.registry.exchange(for: request.url) else { return }
        exchange.stop()
    }
}
