import Foundation

/// User-facing disk and export failures never expose file paths or system errors.
enum ReadAloudRecordingError: LocalizedError, Equatable, Sendable {
    case cacheUnavailable
    case cacheLimitExceeded
    case invalidRange
    case recordingFinished
    case saveInProgress
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .cacheUnavailable:
            String(
                localized: "readAloud.playback.cacheUnavailable",
                defaultValue: "The audio recording could not be stored. Check available disk space and try again.",
                table: "ReadAloudPlayback",
                bundle: .module
            )
        case .cacheLimitExceeded:
            String(
                localized: "readAloud.playback.cacheLimitExceeded",
                defaultValue: "The audio recording has reached its storage limit. The audio already recorded is still available.",
                table: "ReadAloudPlayback",
                bundle: .module
            )
        case .invalidRange:
            String(
                localized: "readAloud.playback.invalidRange",
                defaultValue: "The requested audio position is unavailable.",
                table: "ReadAloudPlayback",
                bundle: .module
            )
        case .recordingFinished:
            String(
                localized: "readAloud.playback.recordingFinished",
                defaultValue: "This audio recording has already finished.",
                table: "ReadAloudPlayback",
                bundle: .module
            )
        case .saveInProgress:
            String(
                localized: "readAloud.playback.saveInProgress",
                defaultValue: "This audio recording is already being saved.",
                table: "ReadAloudPlayback",
                bundle: .module
            )
        case .exportFailed:
            String(
                localized: "readAloud.playback.exportFailed",
                defaultValue: "The audio recording could not be saved. Check the destination and available disk space, then try again.",
                table: "ReadAloudPlayback",
                bundle: .module
            )
        }
    }
}
