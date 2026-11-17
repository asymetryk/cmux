import AVFAudio
import Darwin
import Foundation

/// Disk-backed, mono signed-16-bit little-endian PCM. Audio objects and file I/O
/// remain on this actor, independent of the main actor and the playback rate.
actor ReadAloudRecording {
    static let sampleRate: Double = 32_000
    private static let pageFrames = 3_200
    private static let writePageBytes = 64 * 1024

    private(set) var frameCount: Int64 = 0
    private(set) var isSaving = false
    private(set) var savedURL: URL?
    private(set) var exportError: String?

    private let maximumBytes: Int
    private var byteCount = 0
    private var finished = false
    private var cache: CacheFile?
    private var export: Export?
    private var readers: [UUID: WaitingReader] = [:]

    init(maximumBytes: Int = 512 * 1024 * 1024) throws {
        guard maximumBytes >= 0 else { throw ReadAloudRecordingError.cacheLimitExceeded }
        self.maximumBytes = maximumBytes
        cache = try CacheFile()
    }

    @discardableResult
    func append(_ data: Data) throws -> Int64 {
        guard let cache else { throw CancellationError() }
        guard !finished else { throw ReadAloudRecordingError.recordingFinished }
        guard data.count <= maximumBytes - byteCount else {
            throw ReadAloudRecordingError.cacheLimitExceeded
        }
        guard !data.isEmpty else { return frameCount }

        do {
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = min(Self.writePageBytes, bytes.count - written)
                    let result = Darwin.pwrite(
                        cache.descriptor, bytes.baseAddress!.advanced(by: written), count,
                        off_t(byteCount + written)
                    )
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { throw ReadAloudRecordingError.cacheUnavailable }
                    written += result
                }
            }
        } catch {
            // A failed write never advances the accepted length. Later appends
            // overwrite any unaccepted bytes even if truncation also fails.
            _ = Darwin.ftruncate(cache.descriptor, off_t(byteCount))
            throw ReadAloudRecordingError.cacheUnavailable
        }

        byteCount += data.count
        frameCount = Int64(byteCount / 2)
        resumeReaders()
        if let export, !export.isCatchingUp {
            do {
                try writeAvailableAudio(to: export)
            } catch {
                failExport(export)
            }
        }
        return frameCount
    }

    /// Returns at most one 100-ms page, including when a larger limit is supplied.
    /// A reader beyond the growing end waits for that position or final EOF.
    func read(fromFrame: Int64, maximumFrames: Int = 3_200) async throws -> Data {
        guard fromFrame >= 0, maximumFrames > 0 else {
            throw ReadAloudRecordingError.invalidRange
        }
        while true {
            try Task.checkCancellation()
            guard cache != nil else { throw CancellationError() }
            if fromFrame < frameCount {
                return try readCachedFrames(
                    fromFrame: fromFrame, maximumFrames: min(maximumFrames, Self.pageFrames)
                )
            }
            if finished { return Data() }
            try await waitForAudio(fromFrame: fromFrame)
        }
    }

    func finish(allowIncompleteSample: Bool = false) throws {
        guard !finished else { return }
        guard let cache else { throw CancellationError() }
        if byteCount % 2 != 0 {
            guard allowIncompleteSample else { throw ReadAloudPlaybackError.incompleteSample }
            guard Darwin.ftruncate(cache.descriptor, off_t(byteCount - 1)) == 0 else {
                throw ReadAloudRecordingError.cacheUnavailable
            }
            byteCount -= 1
        }
        finished = true
        resumeReaders()
        if let export {
            do {
                try writeAvailableAudio(to: export)
                try finalizeExport(export)
            } catch {
                failExport(export)
            }
        }
    }

    /// Catches up in bounded pages, then follows future appends. Yielding during
    /// catch-up keeps playback reads responsive even for a long recording.
    func startSaving(to url: URL) async throws {
        try Task.checkCancellation()
        guard cache != nil else { throw CancellationError() }
        guard export == nil else { throw ReadAloudRecordingError.saveInProgress }
        exportError = nil

        let request: Export
        do {
            request = try Export(destination: url)
        } catch {
            exportError = ReadAloudRecordingError.exportFailed.localizedDescription
            throw ReadAloudRecordingError.exportFailed
        }
        export = request
        isSaving = true
        do {
            while export === request {
                try Task.checkCancellation()
                if request.nextFrame == frameCount {
                    request.isCatchingUp = false
                    if finished { try finalizeExport(request) }
                    return
                }
                try writeExportPage(to: request)
                await Task.yield()
            }
            // finish/discard may finalize this request while catch-up yields.
            if !request.completed { throw ReadAloudRecordingError.exportFailed }
        } catch {
            if export === request { failExport(request) }
            if error is CancellationError { throw CancellationError() }
            throw ReadAloudRecordingError.exportFailed
        }
    }

    /// A save explicitly requested by the user survives closing the player.
    /// No other recording's directory or destination is ever removed here.
    func discard() {
        if let export {
            do {
                try writeAvailableAudio(to: export)
                try finalizeExport(export)
            } catch {
                failExport(export)
            }
        }
        finished = true
        cache = nil
        byteCount = 0
        frameCount = 0
        let waiting = readers
        readers.removeAll()
        for reader in waiting.values { reader.continuation.resume(throwing: CancellationError()) }
    }

    private func waitForAudio(fromFrame: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                readers[id] = WaitingReader(fromFrame: fromFrame, continuation: continuation)
            }
        } onCancel: {
            // Cancellation removes only this reader. Registration is synchronous
            // on the actor, so this task cannot overtake an in-flight registration.
            Task { await self.cancelReader(id) }
        }
    }

    private func cancelReader(_ id: UUID) {
        readers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func resumeReaders() {
        for (id, reader) in readers where finished || reader.fromFrame < frameCount {
            readers.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func readCachedFrames(fromFrame: Int64, maximumFrames: Int) throws -> Data {
        guard let cache else { throw CancellationError() }
        let frames = min(Int64(maximumFrames), frameCount - fromFrame)
        var data = Data(count: Int(frames) * 2)
        try data.withUnsafeMutableBytes { bytes in
            var received = 0
            while received < bytes.count {
                let result = Darwin.pread(
                    cache.descriptor, bytes.baseAddress!.advanced(by: received), bytes.count - received,
                    off_t(fromFrame * 2 + Int64(received))
                )
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw ReadAloudRecordingError.cacheUnavailable }
                received += result
            }
        }
        return data
    }

    private func writeAvailableAudio(to request: Export) throws {
        while request.nextFrame < frameCount { try writeExportPage(to: request) }
    }

    private func writeExportPage(to request: Export) throws {
        let data = try readCachedFrames(fromFrame: request.nextFrame, maximumFrames: Self.pageFrames)
        let frames = data.count / 2
        guard frames > 0, let samples = request.buffer.floatChannelData?[0], let file = request.file else {
            throw ReadAloudRecordingError.exportFailed
        }
        data.withUnsafeBytes { bytes in
            let bytes = bytes.bindMemory(to: UInt8.self)
            for index in 0..<frames {
                let sample = UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
                samples[index] = Float(Int16(bitPattern: sample)) / 32_768
            }
        }
        request.buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: request.buffer)
        request.nextFrame += Int64(frames)
    }

    private func finalizeExport(_ request: Export) throws {
        // On macOS 14 dropping the last AVAudioFile reference closes the encoder
        // and writes the M4A header. No local reference to it survives this call.
        request.closeEncoder()
        try request.verifyAndCommit()
        request.completed = true
        savedURL = request.destination
        export = nil
        isSaving = false
    }

    private func failExport(_ request: Export) {
        request.removePartial()
        export = nil
        isSaving = false
        exportError = ReadAloudRecordingError.exportFailed.localizedDescription
    }

    private struct WaitingReader {
        let fromFrame: Int64
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// Resource lifetime performs deinit cleanup without accessing actor-isolated
    /// state from an actor's nonisolated deinitializer.
    private final class CacheFile {
        let directory: URL
        let descriptor: Int32

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-read-aloud-\(UUID().uuidString)", isDirectory: true)
            guard Darwin.mkdir(directory.path, 0o700) == 0 else {
                throw ReadAloudRecordingError.cacheUnavailable
            }
            descriptor = Darwin.open(
                directory.appendingPathComponent("audio.pcm").path,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600
            )
            guard descriptor >= 0 else {
                try? FileManager.default.removeItem(at: directory)
                throw ReadAloudRecordingError.cacheUnavailable
            }
        }

        deinit {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Confined to its recording actor; neither AVAudioFile nor its buffer crosses
    /// an actor boundary. A failed or abandoned export owns only its partial file.
    private final class Export {
        let destination: URL
        let partial: URL
        let buffer: AVAudioPCMBuffer
        var file: AVAudioFile?
        var nextFrame: Int64 = 0
        var isCatchingUp = true
        var completed = false
        private var ownsPartial = false

        init(destination: URL) throws {
            guard destination.isFileURL else { throw ReadAloudRecordingError.exportFailed }
            self.destination = destination
            partial = destination.deletingLastPathComponent()
                .appendingPathComponent(".cmux-read-aloud-\(UUID().uuidString).partial.m4a")
            guard let format = AVAudioFormat(standardFormatWithSampleRate: ReadAloudRecording.sampleRate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ReadAloudRecording.pageFrames)) else {
                throw ReadAloudRecordingError.exportFailed
            }
            self.buffer = buffer
            let descriptor = Darwin.open(partial.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw ReadAloudRecordingError.exportFailed }
            ownsPartial = true
            Darwin.close(descriptor)
            do {
                file = try AVAudioFile(
                    forWriting: partial,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVAudioFileTypeKey: kAudioFileM4AType,
                        AVSampleRateKey: ReadAloudRecording.sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 64_000,
                    ],
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                guard Darwin.chmod(partial.path, 0o600) == 0 else {
                    throw ReadAloudRecordingError.exportFailed
                }
            } catch {
                removePartial()
                throw ReadAloudRecordingError.exportFailed
            }
        }

        func closeEncoder() {
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
        }

        func verifyAndCommit() throws {
            // AVAudioFile.close has no error result. Reopen the completed header
            // and decode its final requested frame before replacing user data.
            try autoreleasepool {
                let verification = try AVAudioFile(forReading: partial)
                guard verification.processingFormat.sampleRate == ReadAloudRecording.sampleRate,
                      verification.processingFormat.channelCount == 1,
                      verification.length >= nextFrame else {
                    throw ReadAloudRecordingError.exportFailed
                }
                if nextFrame > 0 {
                    verification.framePosition = nextFrame - 1
                    try verification.read(into: buffer, frameCount: 1)
                    guard buffer.frameLength == 1 else { throw ReadAloudRecordingError.exportFailed }
                }
            }
            let descriptor = Darwin.open(partial.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ReadAloudRecordingError.exportFailed }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw ReadAloudRecordingError.exportFailed }
            // Both paths share a directory, so rename is an atomic replacement.
            // In particular, an existing destination is never deleted up front.
            guard Darwin.rename(partial.path, destination.path) == 0 else {
                throw ReadAloudRecordingError.exportFailed
            }
        }

        func removePartial() {
            closeEncoder()
            if ownsPartial {
                try? FileManager.default.removeItem(at: partial)
                ownsPartial = false
            }
        }

        deinit {
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
            if ownsPartial && !completed { try? FileManager.default.removeItem(at: partial) }
        }
    }
}
