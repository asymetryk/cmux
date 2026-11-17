import Foundation
import Testing
@testable import CmuxReadAloud

@Suite(.timeLimit(.minutes(1)))
struct ReadAloudAudioBufferTests {
    @Test func burstRemainsOrderedUntilDelayedConsumerDrainsFinishedBuffer() async throws {
        let packets = [Data([0, 1]), Data([2, 3, 4, 5]), Data([6, 7])]
        let buffer = ReadAloudAudioBuffer(maximumBufferedBytes: 8)
        for packet in packets {
            try buffer.yield(packet)
        }
        buffer.finish()
        #expect(throws: CancellationError.self) { try buffer.yield(Data([8, 9])) }

        var received: [Data] = []
        for try await packet in buffer {
            received.append(packet)
        }
        #expect(received == packets)
    }

    @Test func overflowRejectsNewPacketWithoutLosingQueuedAudio() async throws {
        let buffer = ReadAloudAudioBuffer(maximumBufferedBytes: 4)
        try buffer.yield(Data([0, 1]))
        #expect(throws: ReadAloudTransportError.responseTooLarge) {
            try buffer.yield(Data([2, 3, 4, 5]))
        }
        try buffer.yield(Data([6, 7]))
        buffer.finish()

        var received: [Data] = []
        for try await packet in buffer {
            received.append(packet)
        }
        #expect(received == [Data([0, 1]), Data([6, 7])])
    }

    @Test func handedOffPacketImmediatelyReleasesItsByteBudget() async throws {
        let buffer = ReadAloudAudioBuffer(maximumBufferedBytes: 4)
        try buffer.yield(Data([0, 1, 2, 3]))
        var iterator = buffer.makeAsyncIterator()
        let playing = try await iterator.next()
        #expect(playing == Data([0, 1, 2, 3]))

        // The consumer still owns the first packet while the next packet is queued.
        try buffer.yield(Data([4, 5, 6, 7]))
        #expect(throws: ReadAloudTransportError.responseTooLarge) {
            try buffer.yield(Data([8, 9]))
        }
        buffer.finish()
        #expect(try await iterator.next() == Data([4, 5, 6, 7]))
        #expect(try await iterator.next() == nil)
    }

    @Test func finishReleasesConsumerWaitingForAudio() async throws {
        let buffer = ReadAloudAudioBuffer()
        let (ready, readiness) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var iterator = buffer.makeAsyncIterator()
            readiness.yield(())
            return try await iterator.next()
        }
        defer { consumer.cancel() }
        var readinessIterator = ready.makeAsyncIterator()
        _ = await readinessIterator.next()
        buffer.finish()

        #expect(try await consumer.value == nil)
        readiness.finish()
    }

    @Test func failedProducerCannotLookLikeACleanChunkBoundary() async throws {
        let buffer = ReadAloudAudioBuffer()
        try buffer.yield(Data([0, 1]))
        buffer.finish(throwing: ReadAloudTransportError.network)
        var iterator = buffer.makeAsyncIterator()
        #expect(try await iterator.next() == Data([0, 1]))
        await #expect(throws: ReadAloudTransportError.network) {
            _ = try await iterator.next()
        }
    }

    @Test func cancellationReleasesConsumerWaitingForAudioAndRejectsProducer() async throws {
        let buffer = ReadAloudAudioBuffer()
        let (ready, readiness) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var iterator = buffer.makeAsyncIterator()
            readiness.yield(())
            return try await iterator.next()
        }
        defer { consumer.cancel() }
        var readinessIterator = ready.makeAsyncIterator()
        _ = await readinessIterator.next()
        consumer.cancel()

        await #expect(throws: CancellationError.self) { try await consumer.value }
        #expect(throws: CancellationError.self) { try buffer.yield(Data([0, 1])) }
        readiness.finish()
    }
}
