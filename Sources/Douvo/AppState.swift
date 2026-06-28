import Foundation

enum LoginStatus {
    case checking
    case loggedIn
    case notLoggedIn
}

enum RecordingState {
    case idle
    case starting
    case recording
    case stopping
}

enum OverlayMode: Equatable {
    case dictation
    case selectionEditing
    case translation
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var loginStatus: LoginStatus = .checking
    @Published var recordingState: RecordingState = .idle
    @Published var transcript: String = ""
    @Published var errorMessage: String?
    @Published var lastTranscript: String = ""
    @Published var overlayMode: OverlayMode = .dictation
    @Published var audioLevels: [Float] = Array(repeating: 0, count: OverlayAppearanceStore.size.waveformBarCount)

    // Overlay button actions, wired up by TranscriptionManager.
    var onCancelTapped: (() -> Void)?
    var onSubmitTapped: (() -> Void)?

    var isRecordingLike: Bool {
        recordingState == .starting || recordingState == .recording || recordingState == .stopping
    }

    func pushAudioLevel(_ level: Float) {
        let voiceLevel = Self.normalizedVoiceLevel(from: level)
        let targetCount = OverlayAppearanceStore.size.waveformBarCount
        guard audioLevels.count == targetCount else {
            audioLevels = Array(repeating: 0, count: max(0, targetCount - 1)) + [voiceLevel]
            return
        }

        var nextLevels = Array(audioLevels.dropFirst())
        let currentLevel = audioLevels.last ?? 0
        let coefficient: Float = voiceLevel > currentLevel ? 0.82 : 0.42
        let smoothedLevel = currentLevel + (voiceLevel - currentLevel) * coefficient
        nextLevels.append(smoothedLevel)
        audioLevels = nextLevels
    }

    func resetAudioLevels() {
        audioLevels = Array(repeating: 0, count: OverlayAppearanceStore.size.waveformBarCount)
    }

    private init() {}

    private static func normalizedVoiceLevel(from level: Float) -> Float {
        let noiseFloor = Float(OverlayAppearanceStore.waveformNoiseFloor)
        return AudioLevelVisualizer.normalizedVoiceLevel(from: level, noiseFloor: noiseFloor)
    }

}
