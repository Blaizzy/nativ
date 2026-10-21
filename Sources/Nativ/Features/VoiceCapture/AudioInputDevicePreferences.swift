import AVFoundation
import CoreAudio
import Foundation

struct NativAudioInputDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isSystemDefault: Bool
    var isVirtual: Bool = false
}

struct AudioInputDeviceExclusion: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var allUses: Bool

    static let storageKey = "audio.input.exclusions"
    static let didChange = Notification.Name("NativAudioInputExclusionsDidChange")

    static func load(from defaults: UserDefaults = .standard) -> [Self] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
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

    @Published private(set) var exclusions: [AudioInputDeviceExclusion] {
        didSet {
            if let data = try? JSONEncoder().encode(exclusions) {
                defaults.set(data, forKey: AudioInputDeviceExclusion.storageKey)
            }
            NotificationCenter.default.post(name: AudioInputDeviceExclusion.didChange, object: nil)
        }
    }

    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let selectionKey = "audio.input.selected-device-id"
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        exclusions = AudioInputDeviceExclusion.load(from: defaults)
        selectedDeviceID = defaults.string(forKey: Self.selectionKey) ?? Self.systemDefaultID
        refresh()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, nil, listener
        ) == noErr { defaultInputListener = listener }

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

    isolated deinit {
        if let defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, nil, defaultInputListener
            )
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var effectiveDeviceID: String? {
        resolvedDeviceID(passive: false)
    }

    var passiveDeviceID: String? { resolvedDeviceID(passive: true) }

    var recordingDevices: [NativAudioInputDevice] {
        devices.filter { device in !exclusions.contains { $0.id == device.id && $0.allUses } }
    }

    var selectionTitle: String {
        guard let id = resolvedDeviceID(passive: false), let device = devices.first(where: { $0.id == id })
        else { return "No allowed microphone" }
        if selectedDeviceID == id { return device.name }
        if selectedDeviceID.isEmpty, device.isSystemDefault { return "System Default — \(device.name)" }
        return "Using \(device.name)"
    }

    var selectionIsUnavailable: Bool {
        !selectedDeviceID.isEmpty && !recordingDevices.contains { $0.id == selectedDeviceID }
    }

    func exclude(_ device: NativAudioInputDevice) {
        guard !device.id.isEmpty, !exclusions.contains(where: { $0.id == device.id }) else { return }
        exclusions.append(.init(id: device.id, name: device.name, allUses: false))
    }

    func removeExclusion(id: String) { exclusions.removeAll { $0.id == id } }

    func setExcludedFromAllUses(_ excluded: Bool, id: String) {
        guard let index = exclusions.firstIndex(where: { $0.id == id }) else { return }
        exclusions[index].allUses = excluded
    }

    func refresh() { devices = AudioInputDeviceResolver.availableDevices() }

    private func resolvedDeviceID(passive: Bool) -> String? {
        AudioInputDeviceResolver.resolve(
            preferredID: selectedDeviceID, devices: devices, exclusions: exclusions, passive: passive
        )
    }
}

enum AudioInputDeviceResolver {
    static func availableDevices() -> [NativAudioInputDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map {
            NativAudioInputDevice(
                id: $0.uniqueID, name: $0.localizedName, isSystemDefault: $0.uniqueID == defaultID,
                isVirtual: UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeVirtual
            )
        }.sorted {
            if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func resolve(
        preferredID: String?, devices: [NativAudioInputDevice],
        exclusions: [AudioInputDeviceExclusion], passive: Bool
    ) -> String? {
        let excluded = Set(exclusions.filter { passive || $0.allUses }.map(\.id))
        let allowed = devices.filter { !excluded.contains($0.id) }
        let physical = allowed.filter { !$0.isVirtual }
        return allowed.first { $0.id == preferredID }?.id
            ?? physical.first(where: \.isSystemDefault)?.id ?? physical.first?.id
    }

    static func captureDeviceID(preferredID: String?, passive: Bool = false) throws -> String {
        guard let id = resolve(
            preferredID: preferredID, devices: availableDevices(),
            exclusions: AudioInputDeviceExclusion.load(), passive: passive
        ) else { throw VoiceAudioRecorderError.noAllowedMicrophone }
        return id
    }

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
