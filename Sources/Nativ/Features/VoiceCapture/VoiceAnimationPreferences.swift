import Combine
import Foundation

enum VoiceCaptureAnimationStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case cursorWaveform
    case gradientIsland
    case notchShelf
    case verticalRecorder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursorWaveform:
            "Cursor Waveform"
        case .gradientIsland:
            "Gradient Island"
        case .notchShelf:
            "Wide Notch"
        case .verticalRecorder:
            "Vertical Recorder"
        }
    }

    var subtitle: String {
        switch self {
        case .cursorWaveform:
            "A live waveform that follows your pointer."
        case .gradientIsland:
            "A liquid-glass listening orb with start and finish cues."
        case .notchShelf:
            "Widens the MacBook notch sideways without making it taller."
        case .verticalRecorder:
            "A movable recording meter for the side of your screen."
        }
    }

    var locationLabel: String {
        switch self {
        case .cursorWaveform:
            "At pointer"
        case .gradientIsland:
            "Beside camera"
        case .notchShelf:
            "Around camera"
        case .verticalRecorder:
            "Right side"
        }
    }
}

@MainActor
final class VoiceAnimationPreferences: ObservableObject {
    static let shared = VoiceAnimationPreferences()

    static let recordingStyles: [VoiceCaptureAnimationStyle] = [
        .verticalRecorder,
        .gradientIsland,
        .notchShelf,
    ]

    static let dictationStyles: [VoiceCaptureAnimationStyle] = [
        .cursorWaveform,
        .gradientIsland,
        .notchShelf,
    ]

    @Published var selectedStyle: VoiceCaptureAnimationStyle {
        didSet {
            defaults.set(selectedStyle.rawValue, forKey: storageKey)
        }
    }

    @Published var recordingStyle: VoiceCaptureAnimationStyle {
        didSet {
            defaults.set(recordingStyle.rawValue, forKey: recordingStorageKey)
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let recordingStorageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "voiceCaptureAnimationStyle",
        recordingStorageKey: String = "audioRecordingAnimationStyle"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.recordingStorageKey = recordingStorageKey
        selectedStyle = defaults.string(forKey: storageKey)
            .flatMap(VoiceCaptureAnimationStyle.init(rawValue:))
            ?? .cursorWaveform
        recordingStyle = defaults.string(forKey: recordingStorageKey)
            .flatMap(VoiceCaptureAnimationStyle.init(rawValue:))
            .flatMap { Self.recordingStyles.contains($0) ? $0 : nil }
            ?? .gradientIsland
    }
}
