import SwiftUI

/// Native playback controls for a retained, progressively generated recording.
@MainActor
public struct ReadAloudPlayerView: View {
    @Bindable private var coordinator: ReadAloudCoordinator
    private let onSave: @MainActor () -> Void
    private let onSettings: @MainActor () -> Void
    @State private var seekDraft: Double?
    @State private var seekUpperBound: Double?
    private static let standardRates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// Save destination selection and settings presentation remain owned by the host app.
    public init(
        coordinator: ReadAloudCoordinator,
        onSave: @escaping @MainActor () -> Void,
        onSettings: @escaping @MainActor () -> Void
    ) {
        self.coordinator = coordinator
        self.onSave = onSave
        self.onSettings = onSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "title", defaultValue: "Read Aloud", table: "ReadAloudPlayer", bundle: .module))
                    .font(.title2.bold())
                Spacer()
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("ReadAloudPlayerStatus")
            }

            timeline
            playbackControls

            HStack {
                Picker(
                    String(localized: "speed.label", defaultValue: "Playback Speed", table: "ReadAloudPlayer", bundle: .module),
                    selection: Binding(
                        get: { coordinator.playbackRate },
                        set: { coordinator.setPlaybackRate($0) }
                    )
                ) {
                    ForEach(Self.standardRates, id: \.self) { rate in
                        Text(String(localized: "speed.value", defaultValue: "\(rate.formatted(.number.precision(.fractionLength(0...2))))×", table: "ReadAloudPlayer", bundle: .module))
                            .tag(rate)
                    }
                    if !Self.standardRates.contains(coordinator.playbackRate) {
                        Text(String(localized: "speed.value", defaultValue: "\(coordinator.playbackRate.formatted(.number.precision(.fractionLength(0...2))))×", table: "ReadAloudPlayer", bundle: .module))
                            .tag(coordinator.playbackRate)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("ReadAloudPlayerSpeed")
                Spacer()
            }

            if let message = coordinator.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ReadAloudPlayerError")
            }
            if let message = coordinator.saveError {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ReadAloudPlayerSaveError")
            }

            saveStatus

            HStack {
                Button(String(localized: "action.settings", defaultValue: "Settings…", table: "ReadAloudPlayer", bundle: .module), action: onSettings)
                    .accessibilityIdentifier("ReadAloudPlayerSettings")
                Spacer()
                Button(String(localized: "action.save", defaultValue: "Save Audio…", table: "ReadAloudPlayer", bundle: .module), action: onSave)
                    .disabled(!coordinator.hasRecording || coordinator.isSaving)
                    .accessibilityIdentifier("ReadAloudPlayerSave")
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ReadAloudPlayer")
        .onChange(of: coordinator.recordingID) { _, _ in
            seekDraft = nil
            seekUpperBound = nil
        }
    }

    private var timeline: some View {
        VStack(spacing: 6) {
            HStack {
                Text(String(localized: "time.elapsed", defaultValue: "Elapsed \(timestamp(coordinator.position))", table: "ReadAloudPlayer", bundle: .module))
                    .accessibilityIdentifier("ReadAloudPlayerElapsed")
                Spacer()
                Text(String(localized: "time.generated", defaultValue: "Generated \(timestamp(coordinator.bufferedDuration))", table: "ReadAloudPlayer", bundle: .module))
                    .accessibilityIdentifier("ReadAloudPlayerGenerated")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            // This fraction describes only the audio received, not the document's final length.
            ProgressView(value: min(max(coordinator.position, 0), availableDuration), total: availableDuration)
                .progressViewStyle(.linear)
                .accessibilityLabel(String(localized: "timeline.played", defaultValue: "Played portion of generated audio", table: "ReadAloudPlayer", bundle: .module))
                .accessibilityIdentifier("ReadAloudPlayerProgress")

            Slider(value: seekBinding, in: 0...(seekUpperBound ?? availableDuration), onEditingChanged: editSeek) {
                Text(String(localized: "action.seek", defaultValue: "Seek within generated audio", table: "ReadAloudPlayer", bundle: .module))
            }
            .labelsHidden()
            .disabled(!canUseRecording)
            .accessibilityValue(timestamp(seekDraft ?? coordinator.position))
            .accessibilityIdentifier("ReadAloudPlayerSeek")

            if coordinator.isGenerating {
                Text(String(localized: "timeline.generating", defaultValue: "Audio is still arriving. Seek anywhere in the generated audio.", table: "ReadAloudPlayer", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ReadAloudPlayerGenerationHint")
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 16) {
            Spacer()
            Button {
                coordinator.skip(by: -15)
            } label: {
                Label(String(localized: "action.rewind", defaultValue: "Rewind 15 Seconds", table: "ReadAloudPlayer", bundle: .module), systemImage: "gobackward.15")
            }
            .disabled(!canUseRecording || coordinator.position <= 0)
            .accessibilityIdentifier("ReadAloudPlayerRewind")

            Button {
                coordinator.togglePlayback()
            } label: {
                Label(playbackLabel, systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!canUseRecording && !coordinator.isSpeaking)
            .accessibilityIdentifier("ReadAloudPlayerPlayPause")

            Button {
                coordinator.skip(by: 15)
            } label: {
                Label(String(localized: "action.forward", defaultValue: "Forward 15 Seconds", table: "ReadAloudPlayer", bundle: .module), systemImage: "goforward.15")
            }
            .disabled(!canUseRecording || coordinator.position >= coordinator.bufferedDuration)
            .accessibilityIdentifier("ReadAloudPlayerForward")

            Button {
                coordinator.stop()
            } label: {
                Label(String(localized: "action.stop", defaultValue: "Stop", table: "ReadAloudPlayer", bundle: .module), systemImage: "stop.fill")
            }
            .disabled(!coordinator.isGenerating && !coordinator.isSpeaking)
            .accessibilityIdentifier("ReadAloudPlayerStop")
            Spacer()
        }
        .labelStyle(.iconOnly)
        .controlSize(.large)
    }

    @ViewBuilder
    private var saveStatus: some View {
        if coordinator.isSaving {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(coordinator.isGenerating
                     ? String(localized: "save.streaming", defaultValue: "Saving as audio arrives…", table: "ReadAloudPlayer", bundle: .module)
                     : String(localized: "save.saving", defaultValue: "Saving audio…", table: "ReadAloudPlayer", bundle: .module))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ReadAloudPlayerSaveStatus")
        } else if let url = coordinator.savedURL {
            Text(coordinator.isGenerationComplete
                 ? String(localized: "save.saved", defaultValue: "Saved: \(url.lastPathComponent)", table: "ReadAloudPlayer", bundle: .module)
                 : String(localized: "save.partial", defaultValue: "Saved partial audio: \(url.lastPathComponent)", table: "ReadAloudPlayer", bundle: .module))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(url.lastPathComponent)
                .accessibilityIdentifier("ReadAloudPlayerSaveStatus")
        }
    }

    private var canUseRecording: Bool {
        coordinator.hasRecording && coordinator.bufferedDuration > 0
    }

    private var availableDuration: Double {
        max(coordinator.bufferedDuration, 0.001)
    }

    private var isPlaying: Bool {
        coordinator.isSpeaking && !coordinator.isPaused
    }

    private var playbackLabel: String {
        if isPlaying {
            String(localized: "action.pause", defaultValue: "Pause", table: "ReadAloudPlayer", bundle: .module)
        } else if coordinator.isPaused {
            String(localized: "action.resume", defaultValue: "Resume", table: "ReadAloudPlayer", bundle: .module)
        } else {
            String(localized: "action.play", defaultValue: "Play", table: "ReadAloudPlayer", bundle: .module)
        }
    }

    private var status: String {
        if coordinator.isPaused {
            return coordinator.isGenerating
                ? String(localized: "status.pausedGenerating", defaultValue: "Paused · generating audio", table: "ReadAloudPlayer", bundle: .module)
                : String(localized: "status.paused", defaultValue: "Paused", table: "ReadAloudPlayer", bundle: .module)
        }
        if coordinator.isGenerating {
            if isPlaying && coordinator.position < coordinator.bufferedDuration - 0.1 {
                return String(localized: "status.playingGenerating", defaultValue: "Playing · generating audio", table: "ReadAloudPlayer", bundle: .module)
            }
            return String(localized: "status.buffering", defaultValue: "Buffering · generating audio", table: "ReadAloudPlayer", bundle: .module)
        }
        if isPlaying {
            return String(localized: "status.playing", defaultValue: "Playing", table: "ReadAloudPlayer", bundle: .module)
        }
        if coordinator.isGenerationComplete && coordinator.errorMessage == nil && coordinator.position >= coordinator.bufferedDuration {
            return String(localized: "status.finished", defaultValue: "Finished", table: "ReadAloudPlayer", bundle: .module)
        }
        if coordinator.hasRecording || coordinator.errorMessage != nil {
            return String(localized: "status.stopped", defaultValue: "Stopped", table: "ReadAloudPlayer", bundle: .module)
        }
        return String(localized: "status.waiting", defaultValue: "Waiting for audio", table: "ReadAloudPlayer", bundle: .module)
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: { min(max(seekDraft ?? coordinator.position, 0), seekUpperBound ?? availableDuration) },
            set: { position in
                if seekUpperBound != nil {
                    seekDraft = position
                } else {
                    // Keyboard and accessibility adjustments need not start a pointer drag.
                    coordinator.seek(to: position)
                }
            }
        )
    }

    private func editSeek(_ isEditing: Bool) {
        if isEditing {
            seekUpperBound = availableDuration
            seekDraft = min(max(coordinator.position, 0), availableDuration)
        } else {
            if let seekDraft {
                coordinator.seek(to: seekDraft)
            }
            seekDraft = nil
            seekUpperBound = nil
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        Duration.seconds(max(seconds, 0)).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }
}
