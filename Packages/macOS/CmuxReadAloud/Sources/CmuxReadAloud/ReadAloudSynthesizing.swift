import Foundation

/// Synthesizes selected text into mono 32 kHz signed 16-bit little-endian PCM.
public protocol ReadAloudSynthesizing: Sendable {
    /// Delivers ordered audio to one sequential, backpressured consumer.
    ///
    /// Reception may run ahead within a bounded queue. Cancellation must stop
    /// every underlying request. Only the consumer may retain or save the PCM;
    /// the provider transport never persists selected text, credentials, or audio.
    /// - Parameters:
    ///   - text: The selected text, without silent truncation.
    ///   - configuration: Model, voice, and speed preferences.
    ///   - apiKey: The caller-provided MiniMax credential.
    ///   - audioSink: Consumes ordered PCM; its playback-independent backpressure bounds lookahead.
    /// - Throws: Cancellation, transport, provider, or consumption errors.
    func synthesize(
        text: String,
        configuration: ReadAloudConfiguration,
        apiKey: String,
        audioSink: @escaping @Sendable (Data) async throws -> Void
    ) async throws
}
