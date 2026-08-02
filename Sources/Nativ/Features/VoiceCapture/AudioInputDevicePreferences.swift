import AVFoundation
import CoreAudio
import Foundation

struct NativAudioInputDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isSystemDefault: Bool
}

@MainActor
final class AudioInputDevicePreferences: ObservableObject {
    static let shared = AudioInputDevicePreferences()

    static let systemDefaultID = ""

    @Published private(set) var devices: [NativAudioInputDevice] = []
    @Published var selectedDeviceID: String {
        didSet {
            defaults.set(selectedDeviceID, forKey: Self.selectionKey)
        }
    }

    private static let selectionKey = "audio.input.selected-device-id"
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedDeviceID = defaults.string(forKey: Self.selectionKey) ?? Self.systemDefaultID
        refresh()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            },
        ]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var effectiveDeviceID: String? {
        guard !selectedDeviceID.isEmpty,
              devices.contains(where: { $0.id == selectedDeviceID })
        else {
            return nil
        }
        return selectedDeviceID
    }

    var selectionTitle: String {
        if selectedDeviceID.isEmpty {
            return defaultDevice.map { "System Default — \($0.name)" } ?? "System Default"
        }
        return devices.first(where: { $0.id == selectedDeviceID })?.name
            ?? "Unavailable — using System Default"
    }

    var selectionIsUnavailable: Bool {
        !selectedDeviceID.isEmpty && effectiveDeviceID == nil
    }

    func refresh() {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        devices = discoverySession.devices
            .map {
                NativAudioInputDevice(
                    id: $0.uniqueID,
                    name: $0.localizedName,
                    isSystemDefault: $0.uniqueID == defaultID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isSystemDefault != rhs.isSystemDefault {
                    return lhs.isSystemDefault
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private var defaultDevice: NativAudioInputDevice? {
        devices.first(where: \.isSystemDefault)
    }
}

enum AudioInputDeviceResolver {
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr,
        deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    static func coreAudioDeviceID(for uniqueID: String) -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        return deviceIDs.first { deviceID in
            deviceUID(for: deviceID) == uniqueID
        }
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        guard status == noErr else {
            return nil
        }
        return uid as String?
    }
}
