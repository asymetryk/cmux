import Foundation

/// A single-consumer PCM queue whose byte budget excludes the packet being played.
struct ReadAloudAudioBuffer: AsyncSequence, Sendable {
    typealias Element = Data

    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let state: State

    init(maximumBufferedBytes: Int = 64 * 1024 * 1024) {
        precondition(maximumBufferedBytes >= 0)
        let state = State(maximumBufferedBytes: maximumBufferedBytes)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.onTermination = { _ in state.terminate() }
        self.stream = stream
        self.continuation = continuation
        self.state = state
    }

    func yield(_ data: Data) throws {
        try state.yield(data, to: continuation)
    }

    func finish(throwing error: (any Error)? = nil) {
        state.finish(continuation, throwing: error)
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator(), state: state)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var iterator: AsyncThrowingStream<Data, any Error>.Iterator
        fileprivate let state: State

        mutating func next() async throws -> Data? {
            let data = try await iterator.next()
            if let data { state.consume(data.count) }
            // AsyncThrowingStream returns nil on cancellation, not just clean EOF.
            try Task.checkCancellation()
            return data
        }
    }

    // The continuation retains only this state, which never retains the stream or
    // continuation. All mutable fields are protected by the lock. A recursive
    // lock permits the stream's synchronous onTermination callback during finish.
    fileprivate final class State: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private let maximumBufferedBytes: Int
        private var bufferedBytes = 0
        private var terminated = false

        init(maximumBufferedBytes: Int) {
            self.maximumBufferedBytes = maximumBufferedBytes
        }

        func yield(_ data: Data, to continuation: AsyncThrowingStream<Data, any Error>.Continuation) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !terminated else { throw CancellationError() }
            // Empty PCM has nothing to play and must not create unbounded queue nodes.
            guard !data.isEmpty else { return }
            guard data.count <= maximumBufferedBytes - bufferedBytes else {
                throw ReadAloudTransportError.responseTooLarge
            }
            bufferedBytes += data.count
            switch continuation.yield(data) {
            case .enqueued:
                break
            case .terminated:
                bufferedBytes -= data.count
                terminated = true
                throw CancellationError()
            case .dropped:
                bufferedBytes -= data.count
                throw ReadAloudTransportError.responseTooLarge
            @unknown default:
                bufferedBytes -= data.count
                throw ReadAloudTransportError.responseTooLarge
            }
        }

        func consume(_ count: Int) {
            lock.lock()
            defer { lock.unlock() }
            bufferedBytes -= count
        }

        func finish(_ continuation: AsyncThrowingStream<Data, any Error>.Continuation, throwing error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            terminated = true
            continuation.finish(throwing: error)
        }

        func terminate() {
            lock.lock()
            defer { lock.unlock() }
            terminated = true
        }
    }
}
