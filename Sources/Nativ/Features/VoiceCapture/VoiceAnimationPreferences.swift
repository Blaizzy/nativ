import Combine
import Foundation

enum VoiceCaptureAnimationStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case cursorWaveform
    case gradientIsland

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursorWaveform:
            "Cursor Waveform"
        case .gradientIsland:
            "Gradient Island"
        }
    }

    var subtitle: String {
        switch self {
        case .cursorWaveform:
            "A live waveform that follows your pointer."
        case .gradientIsland:
            "One pill around the camera cutout, with a reactive orb and timer."
        }
    }

    var locationLabel: String {
        switch self {
        case .cursorWaveform:
            "At pointer"
        case .gradientIsland:
            "Beside camera"
        }
    }
}

@MainActor
final class VoiceAnimationPreferences: ObservableObject {
    static let shared = VoiceAnimationPreferences()

    @Published var selectedStyle: VoiceCaptureAnimationStyle {
        didSet {
            defaults.set(selectedStyle.rawValue, forKey: storageKey)
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "voiceCaptureAnimationStyle"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        selectedStyle = defaults.string(forKey: storageKey)
            .flatMap(VoiceCaptureAnimationStyle.init(rawValue:))
            ?? .cursorWaveform
    }
}
