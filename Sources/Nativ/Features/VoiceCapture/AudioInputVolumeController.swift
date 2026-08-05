import CoreAudio
import Foundation

@MainActor
final class AudioInputVolumeController: ObservableObject {
    @Published private(set) var volume: Float = 1
    @Published private(set) var isSupported = false

    private var deviceID: AudioDeviceID?
    private var volumeElements: [AudioObjectPropertyElement] = []

    func refresh(deviceUniqueID: String?) {
        let resolvedDeviceID = deviceUniqueID.flatMap {
            AudioInputDeviceResolver.coreAudioDeviceID(for: $0)
        } ?? AudioInputDeviceResolver.defaultInputDeviceID()

        guard let resolvedDeviceID else {
            deviceID = nil
            volumeElements = []
            volume = 1
            isSupported = false
            return
        }

        let readableElements = Self.readableVolumeElements(for: resolvedDeviceID)
        let values = readableElements.compactMap {
            Self.readVolume(deviceID: resolvedDeviceID, element: $0)
        }
        let settableElements = readableElements.filter {
            Self.isVolumeSettable(deviceID: resolvedDeviceID, element: $0)
        }

        deviceID = resolvedDeviceID
        volumeElements = settableElements
        volume = values.isEmpty
            ? 1
            : values.reduce(0, +) / Float(values.count)
        isSupported = !settableElements.isEmpty
    }

    func setVolume(_ newValue: Float) {
        guard let deviceID, !volumeElements.isEmpty else {
            return
        }
        let clampedValue = max(0, min(1, newValue))
        var wroteValue = false
        for element in volumeElements {
            var value = Float32(clampedValue)
            var address = Self.volumeAddress(element: element)
            if AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            ) == noErr {
                wroteValue = true
            }
        }
        if wroteValue {
            volume = clampedValue
        }
    }

    private static func readableVolumeElements(
        for deviceID: AudioDeviceID
    ) -> [AudioObjectPropertyElement] {
        let candidates = [kAudioObjectPropertyElementMain]
            + (1...16).map(AudioObjectPropertyElement.init)
        return candidates.filter { element in
            var address = volumeAddress(element: element)
            return AudioObjectHasProperty(deviceID, &address)
        }
    }

    private static func readVolume(
        deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = volumeAddress(element: element)
        var value = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func isVolumeSettable(
        deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = volumeAddress(element: element)
        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(
            deviceID,
            &address,
            &isSettable
        ) == noErr else {
            return false
        }
        return isSettable.boolValue
    }

    private static func volumeAddress(
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
    }
}
