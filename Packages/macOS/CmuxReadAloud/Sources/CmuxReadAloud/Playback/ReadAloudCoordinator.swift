import Foundation
import Observation

/// Owns one private recording, its bounded synthesis lookahead, and an independent playback cursor.
/// Stop preserves generated audio; dismissal or replacement removes the temporary recording.
@MainActor
@Observable
public final class ReadAloudCoordinator {
    /// Active playback intent, including loading, buffering, and a deliberate pause.
    public private(set) var isSpeaking = false
    public private(set) var isGenerating = false
    public private(set) var isGenerationComplete = false
    public private(set) var isPaused = false
    public private(set) var position: TimeInterval = 0
    public private(set) var bufferedDuration: TimeInterval = 0
    public private(set) var playbackRate: Double = 1
    public private(set) var isSaving = false
    public private(set) var savedURL: URL?
    public private(set) var errorMessage: String?
    public private(set) var saveError: String?
    public var hasRecording: Bool { bufferedDuration > 0 }
    public var recordingID: UUID? { session }
    public var requiresShutdown: Bool { session != nil || finalization != nil }

    @ObservationIgnored private let synthesizer: any ReadAloudSynthesizing
    @ObservationIgnored private let player: PCMReadAloudPlayer
    @ObservationIgnored private let authorization: @Sendable () async throws -> (ReadAloudConfiguration, String)
    @ObservationIgnored private var session: UUID?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var playbackGeneration: UUID?
    @ObservationIgnored private var recording: ReadAloudRecording?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var finalization: Task<Void, Never>?
    @ObservationIgnored private var completion: CheckedContinuation<Void, any Error>?
    @ObservationIgnored private var lookaheadWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored private var rateWasAdjusted = false
    private static let lookaheadSeconds: TimeInterval = 60

    public init(
        synthesizer: any ReadAloudSynthesizing,
        preferences: ReadAloudPreferences,
        player: PCMReadAloudPlayer
    ) {
        self.synthesizer = synthesizer
        self.player = player
        self.authorization = {
            guard await preferences.consentGranted() else {
                throw ReadAloudCoordinatorError.configurationRequired
            }
            try Task.checkCancellation()
            guard let key = try await preferences.apiKey(),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReadAloudCoordinatorError.configurationRequired
            }
            try Task.checkCancellation()
            let configuration = await preferences.configuration()
            try Task.checkCancellation()
            return (configuration, key)
        }
    }

    /// Isolated authorization seam for cancellation tests; never accesses the real Keychain.
    init(
        synthesizer: any ReadAloudSynthesizing,
        player: PCMReadAloudPlayer,
        authorization: @escaping @Sendable () async throws -> (ReadAloudConfiguration, String)
    ) {
        self.synthesizer = synthesizer
        self.player = player
        self.authorization = authorization
    }

    /// Replaces the old recording and waits until playback ends, fails, or is stopped.
    /// An already-cancelled caller cannot interrupt an existing session.
    public func read(_ text: String) async throws {
        try Task.checkCancellation()
        dismiss()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = UUID()
        session = generation
        self.generation = generation
        isSpeaking = true
        isGenerating = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                completion = continuation
                if Task.isCancelled {
                    stop(generation: generation)
                    return
                }
                operation = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.generate(text, generation: generation)
                    } catch {
                        guard self.generation == generation else { return }
                        if Task.isCancelled || error is CancellationError {
                            self.stop()
                        } else {
                            self.errorMessage = self.safeDescription(error)
                            self.halt(result: .failure(error))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop(generation: generation) }
        }
        try Task.checkCancellation()
    }

    /// Cancels requests and audible playback immediately, retaining the partial recording.
    public func stop() {
        halt(result: .failure(CancellationError()))
    }

    /// Closes the player and removes its private cache after finalizing an explicitly requested save.
    public func dismiss() {
        stop()
        let oldRecording = recording
        let oldFinalization = finalization
        recording = nil
        session = nil
        finalization = Task {
            await oldFinalization?.value
            await oldRecording?.discard()
        }
        position = 0
        bufferedDuration = 0
        isGenerationComplete = false
        playbackRate = 1
        rateWasAdjusted = false
        isSaving = false
        savedURL = nil
        errorMessage = nil
        saveError = nil
    }

    /// Used by app teardown to finish exports and cache removal before the process exits.
    public func finishDismissal() async {
        dismiss()
        await finalization?.value
    }

    public func togglePlayback() {
        if isSpeaking {
            isPaused.toggle()
            if isPaused { player.pause() } else { player.resume() }
        } else if let session, let recording, hasRecording {
            if position >= bufferedDuration { position = 0 }
            isPaused = false
            isSpeaking = true
            startPlayback(recording, session: session, at: position)
        }
    }

    /// Seeking is limited to generated audio and never resubmits text to the provider.
    public func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, let recording, let session else { return }
        position = min(max(0, seconds), bufferedDuration)
        resumeLookaheadIfReady()
        if isSpeaking { startPlayback(recording, session: session, at: position) }
    }

    public func skip(by seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        seek(to: position + seconds)
    }

    public func setPlaybackRate(_ rate: Double) {
        guard rate.isFinite else { return }
        playbackRate = min(max(rate, 0.5), 2)
        rateWasAdjusted = true
        player.setRate(playbackRate)
    }

    /// Saves existing and future ordered audio at its original speed, not the listening rate.
    public func save(to url: URL) async throws {
        guard let recording, let session, hasRecording else { return }
        saveError = nil
        isSaving = true
        do {
            try await recording.startSaving(to: url)
            await refreshExport(recording, session: session)
        } catch {
            guard self.session == session else { throw CancellationError() }
            saveError = safeDescription(error)
            await refreshExport(recording, session: session)
            throw error
        }
    }

    private func generate(_ text: String, generation: UUID) async throws {
        var (configuration, key) = try await authorization()
        try checkActive(generation)
        if !rateWasAdjusted {
            playbackRate = configuration.speed.isFinite ? min(max(configuration.speed, 0.5), 2) : 1
        }
        // The settings speed initializes local playback; recordings always retain the normal-speed master.
        configuration.speed = 1
        let recording = try ReadAloudRecording()
        self.recording = recording
        startPlayback(recording, session: generation, at: 0)
        try await synthesizer.synthesize(text: text, configuration: configuration, apiKey: key) { [weak self] data in
            guard let self else { throw CancellationError() }
            try await self.accept(data, into: recording, generation: generation)
        }
        try checkActive(generation)
        try await recording.finish()
        try checkActive(generation)
        isGenerating = false
        isGenerationComplete = true
        operation = nil
        await refreshExport(recording, session: generation)
        guard self.generation == generation else { return }
        if playbackTask == nil { completeRead() }
    }

    private func accept(_ data: Data, into recording: ReadAloudRecording, generation: UUID) async throws {
        try checkActive(generation)
        while bufferedDuration - position >= Self.lookaheadSeconds {
            try await waitForLookahead(generation: generation)
        }
        let frames = try await recording.append(data)
        try checkActive(generation)
        bufferedDuration = Double(frames) / ReadAloudRecording.sampleRate
        await refreshExport(recording, session: generation)
        try checkActive(generation)
    }

    private func startPlayback(_ recording: ReadAloudRecording, session: UUID, at seconds: TimeInterval) {
        playbackTask?.cancel()
        let playback = UUID()
        playbackGeneration = playback
        let firstFrame = Int64(seconds * ReadAloudRecording.sampleRate)
        let offset = Double(firstFrame) / ReadAloudRecording.sampleRate
        player.begin(generation: playback, rate: playbackRate, onProgress: { [weak self] frames in
            guard let self, self.session == session, self.playbackGeneration == playback else { return }
            self.position = min(self.bufferedDuration, offset + Double(frames) / ReadAloudRecording.sampleRate)
            self.resumeLookaheadIfReady()
        }, onFailure: { [weak self] error in
            guard let self, self.session == session, self.playbackGeneration == playback else { return }
            self.errorMessage = self.safeDescription(error)
            self.halt(result: .failure(error))
        })
        if isPaused { player.pause() }
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                var frame = firstFrame
                while true {
                    let data = try await recording.read(fromFrame: frame)
                    try self.checkPlayback(session: session, playback: playback)
                    if data.isEmpty { break }
                    try await self.player.append(data, generation: playback)
                    frame += Int64(data.count / 2)
                }
                try await self.player.finish(generation: playback)
                try self.checkPlayback(session: session, playback: playback)
                self.position = Double(frame) / ReadAloudRecording.sampleRate
                self.playbackTask = nil
                self.playbackGeneration = nil
                self.player.stop()
                self.isSpeaking = false
                self.isPaused = false
                if !self.isGenerating { self.completeRead() }
            } catch is CancellationError {
                // Seeking, replacement, and Stop deliberately invalidate only their own cursor.
            } catch {
                guard self.session == session, self.playbackGeneration == playback else { return }
                self.errorMessage = self.safeDescription(error)
                self.halt(result: .failure(error))
            }
        }
    }

    private func checkPlayback(session: UUID, playback: UUID) throws {
        try Task.checkCancellation()
        guard self.session == session, playbackGeneration == playback else { throw CancellationError() }
    }

    private func checkActive(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
    }

    private func stop(generation: UUID) {
        guard self.generation == generation else { return }
        stop()
    }

    private func halt(result: Result<Void, any Error>) {
        generation = nil
        operation?.cancel()
        operation = nil
        playbackGeneration = nil
        playbackTask?.cancel()
        playbackTask = nil
        player.stop()
        resumeLookahead(throwing: CancellationError())
        isSpeaking = false
        isGenerating = false
        isPaused = false
        let completion = self.completion
        self.completion = nil
        completion?.resume(with: result)
        if let recording, let session {
            let previous = finalization
            finalization = Task { [weak self] in
                await previous?.value
                do {
                    try await recording.finish(allowIncompleteSample: true)
                } catch {
                    guard let self, self.session == session else { return }
                    self.errorMessage = self.safeDescription(error)
                }
                let frames = await recording.frameCount
                if let self, self.session == session {
                    // An append can commit just before Stop invalidates its producer.
                    self.bufferedDuration = Double(frames) / ReadAloudRecording.sampleRate
                    self.position = min(self.position, self.bufferedDuration)
                }
                await self?.refreshExport(recording, session: session)
            }
        }
    }

    private func completeRead() {
        generation = nil
        operation = nil
        let completion = self.completion
        self.completion = nil
        completion?.resume()
    }

    private func refreshExport(_ recording: ReadAloudRecording, session: UUID) async {
        let saving = await recording.isSaving
        let saved = await recording.savedURL
        let error = await recording.exportError
        guard self.session == session else { return }
        isSaving = saving
        savedURL = saved
        if let error { saveError = error }
    }

    private func waitForLookahead(generation: UUID) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try checkActive(generation)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lookaheadWaiters[id] = continuation
            }
            try checkActive(generation)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.lookaheadWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    private func resumeLookaheadIfReady() {
        if bufferedDuration - position < Self.lookaheadSeconds { resumeLookahead() }
    }

    private func resumeLookahead(throwing error: (any Error)? = nil) {
        guard !lookaheadWaiters.isEmpty else { return }
        let waiters = lookaheadWaiters
        lookaheadWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters.values {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    private func safeDescription(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription
            ?? String(localized: "readAloud.playback.failed", defaultValue: "Audio playback or recording failed. Please try again.", table: "ReadAloudPlayback", bundle: .module)
    }
}
