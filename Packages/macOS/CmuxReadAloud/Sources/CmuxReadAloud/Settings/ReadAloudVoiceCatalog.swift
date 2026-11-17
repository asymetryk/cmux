import Foundation

/// A documented MiniMax system voice with a localized display name.
struct ReadAloudVoiceOption: Identifiable, Sendable {
    let id: String
    let nameKey: StaticString
    let defaultName: String.LocalizationValue

    var localizedName: String {
        String(
            localized: nameKey,
            defaultValue: defaultName,
            table: "ReadAloudSettings",
            bundle: .module
        )
    }
}

/// Distinguishes a curated system voice from the explicit custom-entry path.
enum ReadAloudVoiceSelection: Hashable, Sendable {
    case preset(String)
    case custom
}

/// The local, documentation-backed system voice choices shown in Read Aloud settings.
/// Provider IDs: https://platform.minimax.io/docs/faq/system-voice-id
struct ReadAloudVoiceCatalog {
    static let options: [ReadAloudVoiceOption] = [
        ReadAloudVoiceOption(
            id: "English_expressive_narrator",
            nameKey: "voice.name.expressiveNarrator",
            defaultName: "Expressive Narrator"
        ),
        ReadAloudVoiceOption(
            id: "English_radiant_girl",
            nameKey: "voice.name.radiantGirl",
            defaultName: "Radiant Girl"
        ),
        ReadAloudVoiceOption(
            id: "English_magnetic_voiced_man",
            nameKey: "voice.name.magneticVoicedMale",
            defaultName: "Magnetic-voiced Male"
        ),
        ReadAloudVoiceOption(
            id: "English_compelling_lady1",
            nameKey: "voice.name.compellingLady",
            defaultName: "Compelling Lady"
        ),
        ReadAloudVoiceOption(
            id: "English_Aussie_Bloke",
            nameKey: "voice.name.aussieBloke",
            defaultName: "Aussie Bloke"
        ),
        ReadAloudVoiceOption(
            id: "English_captivating_female1",
            nameKey: "voice.name.captivatingFemale",
            defaultName: "Captivating Female"
        ),
        ReadAloudVoiceOption(
            id: "English_CalmWoman",
            nameKey: "voice.name.calmWoman",
            defaultName: "Calm Woman"
        ),
        ReadAloudVoiceOption(
            id: "English_Trustworth_Man",
            nameKey: "voice.name.trustworthyMan",
            defaultName: "Trustworthy Man"
        ),
        ReadAloudVoiceOption(
            id: "Japanese_IntellectualSenior",
            nameKey: "voice.name.intellectualSenior",
            defaultName: "Intellectual Senior"
        ),
        ReadAloudVoiceOption(
            id: "Japanese_DecisivePrincess",
            nameKey: "voice.name.decisivePrincess",
            defaultName: "Decisive Princess"
        )
    ]
}
