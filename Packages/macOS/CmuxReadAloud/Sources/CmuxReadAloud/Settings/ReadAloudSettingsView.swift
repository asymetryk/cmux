import SwiftUI

/// Presents native speech preferences, Keychain credential entry, and explicit cloud consent.
///
/// The view loads through its injected model when presented. It never reads a saved key
/// into the secure entry field and discards any unsaved key entry when dismissed.
@MainActor
public struct ReadAloudSettingsView: View {
    @Bindable private var model: ReadAloudSettingsModel
    @State private var voiceSelection: ReadAloudVoiceSelection = .custom
    @State private var customVoiceID = ""

    /// Creates a settings surface backed by the app-owned Read Aloud settings model.
    /// - Parameter model: The observable state sharing preferences with the speech coordinator.
    public init(model: ReadAloudSettingsModel) {
        self.model = model
    }

    /// The native settings controls and visible persistence results.
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "title", defaultValue: "Read Aloud", table: "ReadAloudSettings", bundle: .module))
                    .font(.title2.bold())

                speechSettings
                credentialSettings
                consentSettings

                if let message = model.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ReadAloudSettingsError")
                }
                if let message = model.statusMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ReadAloudSettingsStatus")
                }
                HStack {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(String(localized: "status.working", defaultValue: "Updating Read Aloud settings", table: "ReadAloudSettings", bundle: .module))
                    }
                    Spacer()
                    Button(String(localized: "action.reload", defaultValue: "Reload Settings", table: "ReadAloudSettings", bundle: .module)) {
                        Task { await loadSettings() }
                    }
                    .disabled(model.isBusy)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 620)
        .task { await loadSettings() }
        .onDisappear { model.apiKeyDraft = "" }
    }

    private var speechSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker(String(localized: "model.label", defaultValue: "Model", table: "ReadAloudSettings", bundle: .module), selection: $model.configuration.model) {
                    Text(String(localized: "model.turbo", defaultValue: "Turbo (speech-2.8-turbo)", table: "ReadAloudSettings", bundle: .module))
                        .tag("speech-2.8-turbo")
                    Text(String(localized: "model.hd", defaultValue: "HD (speech-2.8-hd)", table: "ReadAloudSettings", bundle: .module))
                        .tag("speech-2.8-hd")
                }
                .accessibilityIdentifier("ReadAloudModel")

                Picker(String(localized: "voice.pickerLabel", defaultValue: "Voice", table: "ReadAloudSettings", bundle: .module), selection: $voiceSelection) {
                    Section(String(localized: "voice.systemSection", defaultValue: "System voices", table: "ReadAloudSettings", bundle: .module)) {
                        ForEach(ReadAloudVoiceCatalog.options) { option in
                            Text(option.localizedName)
                                .tag(ReadAloudVoiceSelection.preset(option.id))
                        }
                    }
                    Section {
                        Text(String(localized: "voice.custom", defaultValue: "Custom voice ID", table: "ReadAloudSettings", bundle: .module))
                            .tag(ReadAloudVoiceSelection.custom)
                    }
                }
                .onChange(of: voiceSelection) { _, selection in
                    selectVoice(selection)
                }
                .accessibilityIdentifier("ReadAloudVoice")

                if voiceSelection == .custom {
                    TextField(String(localized: "voice.label", defaultValue: "Voice ID", table: "ReadAloudSettings", bundle: .module), text: customVoiceIDBinding)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ReadAloudVoiceID")
                    Text(String(localized: "voice.customHelp", defaultValue: "Enter a MiniMax system, cloned, or other custom voice ID.", table: "ReadAloudSettings", bundle: .module))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Slider(value: $model.configuration.speed, in: 0.5...2, step: 0.1) {
                        Text(String(localized: "speed.label", defaultValue: "Speed", table: "ReadAloudSettings", bundle: .module))
                    }
                    .accessibilityIdentifier("ReadAloudSpeed")
                    Text(String(localized: "speed.value", defaultValue: "\(model.configuration.speed.formatted(.number.precision(.fractionLength(1))))×", table: "ReadAloudSettings", bundle: .module))
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
                Text(String(localized: "speed.playbackHelp", defaultValue: "Sets the starting playback speed for new readings. Use the player to change speed while listening; saved audio stays at normal speed.", table: "ReadAloudSettings", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if model.hasUnsavedConfiguration {
                        Text(String(localized: "status.unsaved", defaultValue: "Unsaved speech settings", table: "ReadAloudSettings", bundle: .module))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "action.saveSettings", defaultValue: "Save Speech Settings", table: "ReadAloudSettings", bundle: .module)) {
                        Task { await model.perform(.saveConfiguration) }
                    }
                    .disabled(!model.hasUnsavedConfiguration)
                    .accessibilityIdentifier("ReadAloudSaveSettings")
                }
            }
            .padding(8)
            .disabled(model.isBusy || !model.isLoaded)
        } label: {
            Text(String(localized: "section.speech", defaultValue: "Speech", table: "ReadAloudSettings", bundle: .module))
        }
    }

    private var customVoiceIDBinding: Binding<String> {
        Binding(
            get: { customVoiceID },
            set: { value in
                customVoiceID = value
                if voiceSelection == .custom {
                    model.configuration.voiceID = value
                }
            }
        )
    }

    private func selectVoice(_ selection: ReadAloudVoiceSelection) {
        switch selection {
        case .preset(let id):
            model.configuration.voiceID = id
        case .custom:
            if customVoiceID.isEmpty {
                customVoiceID = model.configuration.voiceID
            }
            model.configuration.voiceID = customVoiceID
        }
    }

    private func synchronizeVoiceEditor() {
        let voiceID = model.configuration.voiceID
        if ReadAloudVoiceCatalog.options.contains(where: { $0.id == voiceID }) {
            voiceSelection = .preset(voiceID)
            customVoiceID = ""
        } else {
            voiceSelection = .custom
            customVoiceID = voiceID
        }
    }

    private func loadSettings() async {
        await model.perform(.load)
        synchronizeVoiceEditor()
    }

    private var credentialSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(credentialStatus)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ReadAloudKeyStatus")
                SecureField(String(localized: "key.entry", defaultValue: "New MiniMax API Key", table: "ReadAloudSettings", bundle: .module), text: $model.apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ReadAloudAPIKey")
                Text(String(localized: "key.help", defaultValue: "Stored only in this Mac’s Keychain. Saved keys are never displayed here. Enter a new key to replace the saved key.", table: "ReadAloudSettings", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "action.removeKey", defaultValue: "Remove API Key", table: "ReadAloudSettings", bundle: .module), role: .destructive) {
                        Task { await model.perform(.removeAPIKey) }
                    }
                    .disabled(model.hasSavedAPIKey == false)
                    .accessibilityIdentifier("ReadAloudRemoveKey")
                    Spacer()
                    Button(String(localized: "action.saveKey", defaultValue: "Save API Key", table: "ReadAloudSettings", bundle: .module)) {
                        Task { await model.perform(.saveAPIKey) }
                    }
                    .disabled(!model.canSaveAPIKey)
                    .accessibilityIdentifier("ReadAloudSaveKey")
                }
            }
            .padding(8)
            .disabled(model.isBusy || !model.isLoaded)
        } label: {
            Text(String(localized: "section.key", defaultValue: "MiniMax Credential", table: "ReadAloudSettings", bundle: .module))
        }
    }

    private var consentSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "consent.recordingDisclosure", defaultValue: "Read Aloud sends only the terminal text you select to MiniMax. MiniMax bills usage to your account. Audio is temporarily stored on this Mac for playback and seeking, and is removed when the player is closed or a new reading starts. Save Audio keeps a recording only when you choose to save it. Selected text and API keys are not written to the audio cache.", table: "ReadAloudSettings", bundle: .module))
                Toggle(String(localized: "consent.allow", defaultValue: "Allow sending selected text to MiniMax", table: "ReadAloudSettings", bundle: .module), isOn: Binding(
                    get: { model.consentGranted },
                    set: { granted in Task { await model.perform(.setConsent(granted)) } }
                ))
                .accessibilityIdentifier("ReadAloudConsent")
                Text(String(localized: "consent.help", defaultValue: "Optional. Read Aloud remains unavailable until you opt in and save an API key. Turn this off to prevent future requests.", table: "ReadAloudSettings", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .disabled(model.isBusy || !model.isLoaded)
        } label: {
            Text(String(localized: "section.privacy", defaultValue: "Cloud Processing Consent", table: "ReadAloudSettings", bundle: .module))
        }
    }

    private var credentialStatus: String {
        switch model.hasSavedAPIKey {
        case true?:
            String(localized: "key.saved", defaultValue: "An API key is saved in Keychain.", table: "ReadAloudSettings", bundle: .module)
        case false?:
            String(localized: "key.missing", defaultValue: "No API key is saved.", table: "ReadAloudSettings", bundle: .module)
        case nil:
            String(localized: "key.unknown", defaultValue: "Saved API key status is not yet available.", table: "ReadAloudSettings", bundle: .module)
        }
    }
}
