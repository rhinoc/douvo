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

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    static let waveformBarCount = 22

    @Published var loginStatus: LoginStatus = .checking
    @Published var recordingState: RecordingState = .idle
    @Published var transcript: String = ""
    @Published var errorMessage: String?
    @Published var lastTranscript: String = ""
    @Published var audioLevels: [Float] = Array(repeating: 0, count: AppState.waveformBarCount)

    // Overlay button actions, wired up by TranscriptionManager.
    var onCancelTapped: (() -> Void)?
    var onSubmitTapped: (() -> Void)?

    var isRecordingLike: Bool {
        recordingState == .starting || recordingState == .recording || recordingState == .stopping
    }

    func pushAudioLevel(_ level: Float) {
        var levels = audioLevels
        levels.removeFirst()
        levels.append(level)
        audioLevels = levels
    }

    func resetAudioLevels() {
        audioLevels = Array(repeating: 0, count: AppState.waveformBarCount)
    }

    private init() {}
}
