import AVFAudio
import Foundation
import Testing
@testable import CmuxReadAloud

@Suite(.timeLimit(.minutes(1)))
struct ReadAloudRecordingTests {
    @Test func fragmentedSamplesRemainExactAcrossPageBoundariesAndArbitrarySeeks() async throws {
        let recording = try ReadAloudRecording()
        let pcm = Self.makePCM(frames: 10_000)
        #expect(try await recording.append(pcm.subdata(in: 0..<1)) == 0)
        #expect(try await recording.append(pcm.subdata(in: 1..<7)) == 3)
        #expect(try await recording.append(pcm.subdata(in: 7..<6_401)) == 3_200)
        #expect(try await recording.append(pcm.subdata(in: 6_401..<pcm.count)) == 10_000)
        try await recording.finish()

        #expect(try await recording.read(fromFrame: 3_199, maximumFrames: 3) == pcm.subdata(in: 6_398..<6_404))
        #expect(try await recording.read(fromFrame: 1, maximumFrames: 1) == pcm.subdata(in: 2..<4))
        #expect(try await recording.read(fromFrame: 9_999) == pcm.suffix(2))
        #expect(try await recording.read(fromFrame: 0, maximumFrames: Int.max) == pcm.prefix(6_400))
        #expect(try await recording.read(fromFrame: 10_000).isEmpty)
        await recording.discard()
    }

    @Test func cancellingGrowingReaderDoesNotCancelOtherReadersOrRecording() async throws {
        let recording = try ReadAloudRecording()
        let (ready, readiness) = AsyncStream<Void>.makeStream()
        let cancelled = Task {
            readiness.yield(())
            return try await recording.read(fromFrame: 0)
        }
        let survivor = Task {
            readiness.yield(())
            return try await recording.read(fromFrame: 0)
        }
        defer {
            cancelled.cancel()
            survivor.cancel()
            readiness.finish()
        }
        var readyIterator = ready.makeAsyncIterator()
        _ = await readyIterator.next()
        _ = await readyIterator.next()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        #expect(try await recording.append(Data([0x34])) == 0)
        #expect(try await recording.append(Data([0x12])) == 1)
        #expect(try await survivor.value == Data([0x34, 0x12]))
        let atEnd = Task { try await recording.read(fromFrame: 1) }
        defer { atEnd.cancel() }
        try await recording.finish()
        #expect(try await atEnd.value.isEmpty)
        #expect(try await recording.read(fromFrame: Int64.max).isEmpty)
        await recording.discard()
    }

    @Test func discardCancelsWaitersWithoutAffectingAnotherRecording() async throws {
        let discarded = try ReadAloudRecording()
        let retained = try ReadAloudRecording()
        try await retained.append(Data([9, 10]))
        let reader = Task { try await discarded.read(fromFrame: 0) }
        defer { reader.cancel() }
        await discarded.discard()
        await #expect(throws: CancellationError.self) { try await reader.value }
        #expect(try await retained.read(fromFrame: 0) == Data([9, 10]))
        try await retained.finish()
        await retained.discard()
    }

    @Test func cacheLimitRejectsWholeAppendWithoutLosingAcceptedPartialSample() async throws {
        let recording = try ReadAloudRecording(maximumBytes: 5)
        #expect(try await recording.append(Data([1, 2, 3])) == 1)
        await #expect(throws: ReadAloudRecordingError.cacheLimitExceeded) {
            try await recording.append(Data([99, 98, 97]))
        }
        #expect(try await recording.append(Data([4])) == 2)
        try await recording.finish()
        #expect(try await recording.read(fromFrame: 0) == Data([1, 2, 3, 4]))
        await recording.discard()
    }

    @Test func streamingSaveIncludesCachedAndFutureSamplesWithoutReplacingDestinationEarly() async throws {
        let directory = try TemporaryDirectory()
        let destination = directory.url.appendingPathComponent("recording.m4a")
        let previous = Data("previous user file".utf8)
        try previous.write(to: destination)
        let pcm = Self.makePCM(frames: 96_000)
        let recording = try ReadAloudRecording()
        try await recording.append(pcm.subdata(in: 0..<24_013))
        try await recording.startSaving(to: destination)
        #expect(await recording.isSaving)
        #expect(try Data(contentsOf: destination) == previous)

        try await recording.append(pcm.subdata(in: 24_013..<55_018))
        try await recording.append(pcm.subdata(in: 55_018..<pcm.count))
        #expect(try Data(contentsOf: destination) == previous)
        try await recording.finish()
        #expect(await recording.savedURL == destination)
        #expect(await recording.exportError == nil)
        #expect(await recording.isSaving == false)
        try Self.expectDecodedAudio(at: destination, matching: pcm)
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        let second = directory.url.appendingPathComponent("second.m4a")
        try await recording.startSaving(to: second)
        #expect(await recording.savedURL == second)
        #expect(await recording.isSaving == false)
        try Self.expectDecodedAudio(at: second, matching: pcm)
        await recording.discard()
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.url.path)) == ["recording.m4a", "second.m4a"])
    }

    @Test func intentionalPartialFinishTrimsOnlyOrphanByteAndFinalizesSave() async throws {
        let directory = try TemporaryDirectory()
        let destination = directory.url.appendingPathComponent("partial.m4a")
        let pcm = Self.makePCM(frames: 48_000)
        let recording = try ReadAloudRecording()
        try await recording.append(pcm)
        try await recording.append(Data([0x7f]))
        try await recording.startSaving(to: destination)
        await #expect(throws: ReadAloudPlaybackError.self) { try await recording.finish() }
        #expect(await recording.isSaving)
        try await recording.finish(allowIncompleteSample: true)
        try await recording.finish()
        #expect(await recording.frameCount == 48_000)
        #expect(try await recording.read(fromFrame: 47_999) == pcm.suffix(2))
        #expect(try await recording.read(fromFrame: 48_000).isEmpty)
        try Self.expectDecodedAudio(at: destination, matching: pcm)
        await recording.discard()
    }

    @Test func discardFinalizesRequestedPartialSaveBeforeRemovingPCMCache() async throws {
        let directory = try TemporaryDirectory()
        let destination = directory.url.appendingPathComponent("dismissed.m4a")
        let pcm = Self.makePCM(frames: 40_000)
        let recording = try ReadAloudRecording()
        try await recording.append(pcm.subdata(in: 0..<10_001))
        try await recording.startSaving(to: destination)
        try await recording.append(pcm.subdata(in: 10_001..<pcm.count))
        try await recording.append(Data([0xff]))
        await recording.discard()
        #expect(await recording.savedURL == destination)
        #expect(await recording.exportError == nil)
        #expect(await recording.isSaving == false)
        await #expect(throws: CancellationError.self) { try await recording.read(fromFrame: 0) }
        try Self.expectDecodedAudio(at: destination, matching: pcm)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["dismissed.m4a"])
    }

    @Test func failedExportPreservesDestinationAndPlayableCacheThenAllowsRetry() async throws {
        let directory = try TemporaryDirectory()
        let destination = directory.url.appendingPathComponent("existing.m4a")
        let previous = Data("keep this file".utf8)
        try previous.write(to: destination)
        let pcm = Self.makePCM(frames: 40_000)
        let recording = try ReadAloudRecording()
        try await recording.append(pcm.subdata(in: 0..<20_000))
        let unavailable = directory.url.appendingPathComponent("missing/recording.m4a")
        await #expect(throws: ReadAloudRecordingError.exportFailed) {
            try await recording.startSaving(to: unavailable)
        }
        try await recording.startSaving(to: destination)

        // Unlinking an open encoder's private output makes finalization fail
        // deterministically, without disk quotas, permissions, or injected codecs.
        let partial = try #require(FileManager.default.contentsOfDirectory(
            at: directory.url, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasSuffix(".partial.m4a") })
        try FileManager.default.removeItem(at: partial)
        #expect(try await recording.append(pcm.subdata(in: 20_000..<pcm.count)) == 40_000)
        try await recording.finish()
        #expect(await recording.exportError != nil)
        #expect(await recording.isSaving == false)
        #expect(try Data(contentsOf: destination) == previous)
        #expect(try await recording.read(fromFrame: 10_000, maximumFrames: 2) == pcm.subdata(in: 20_000..<20_004))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["existing.m4a"])

        try await recording.startSaving(to: destination)
        #expect(await recording.exportError == nil)
        try Self.expectDecodedAudio(at: destination, matching: pcm)
        await recording.discard()
    }

    private static func makePCM(frames: Int) -> Data {
        var data = Data(count: frames * 2)
        data.withUnsafeMutableBytes { bytes in
            let bytes = bytes.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                let time = Double(frame) / 32_000
                // A chirp distinguishes dropped/repeated pages from correct audio.
                let signal = 0.45 * sin(2 * Double.pi * (220 * time + 65 * time * time))
                    + 0.12 * sin(2 * Double.pi * 911 * time)
                let sample = UInt16(bitPattern: Int16((signal * 32_767).rounded()))
                bytes[frame * 2] = UInt8(truncatingIfNeeded: sample)
                bytes[frame * 2 + 1] = UInt8(truncatingIfNeeded: sample >> 8)
            }
        }
        return data
    }

    private static func expectDecodedAudio(at url: URL, matching pcm: Data) throws {
        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 32_000)
        #expect(file.processingFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var decoded: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let channel = try #require(buffer.floatChannelData?[0])
            guard buffer.frameLength > 0 else {
                Issue.record("Saved audio ended before its declared duration")
                return
            }
            decoded.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        let originalFrames = pcm.count / 2
        #expect(abs(Double(decoded.count - originalFrames) / 32_000) < 0.04)
        try #require(decoded.count >= originalFrames)
        // Ignore codec startup/tail transients, but check each interior 50-ms
        // window independently so short discontinuities cannot hide in an average.
        pcm.withUnsafeBytes { bytes in
            let bytes = bytes.bindMemory(to: UInt8.self)
            for start in stride(from: 2_048, to: originalFrames - 2_048, by: 1_600) {
                var error = 0.0
                var energy = 0.0
                for frame in start..<min(start + 1_600, originalFrames - 2_048) {
                    let bits = UInt16(bytes[frame * 2]) | (UInt16(bytes[frame * 2 + 1]) << 8)
                    let expected = Double(Int16(bitPattern: bits)) / 32_768
                    let difference = Double(decoded[frame]) - expected
                    error += difference * difference
                    energy += expected * expected
                }
                #expect(error / energy < 0.06)
            }
        }
    }

    private final class TemporaryDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReadAloudRecordingTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }
}
