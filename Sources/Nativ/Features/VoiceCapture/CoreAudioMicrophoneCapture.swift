import AVFoundation
import CoreAudio
import Foundation
import Synchronization

actor CoreAudioMicrophoneCapture {
    typealias Receiver = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    private var capture: HALMicrophone?
    private var deliveryTask: Task<Void, Never>?
    private var receiver: Receiver?

    func start(
        deviceUniqueID: String?,
        receive: @escaping Receiver,
        onInterruption: @escaping @Sendable (Error) async -> Void
    ) async throws {
        try Task.checkCancellation()
        stop()
        let next = try HALMicrophone(deviceUniqueID: deviceUniqueID)
        capture = next
        receiver = receive
        do {
            try next.start()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while true {
                try Task.checkCancellation()
                guard capture === next else { throw CancellationError() }
                try next.checkHealth()
                if next.drain(receive) { break }
                guard ContinuousClock.now < deadline else { throw CoreAudioCaptureError.noAudio }
                try await Task.sleep(for: .milliseconds(10))
            }
            let captureID = next.id
            deliveryTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        guard try await self?.deliver(from: captureID, receive: receive) == true else {
                            return
                        }
                    } catch {
                        if !Task.isCancelled { await onInterruption(error) }
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
        } catch {
            if capture === next { stop() }
            throw error
        }
    }

    func stop() {
        deliveryTask?.cancel()
        deliveryTask = nil
        capture?.close(receive: receiver)
        capture = nil
        receiver = nil
    }

    private func deliver(from id: UUID, receive: @escaping Receiver) throws -> Bool {
        guard let expected = capture, expected.id == id else { return false }
        do {
            try expected.checkHealth()
            _ = expected.drain(receive)
            return true
        } catch {
            expected.close(receive: receive)
            capture = nil
            receiver = nil
            throw error
        }
    }

    isolated deinit {
        deliveryTask?.cancel()
        capture?.close(receive: receiver)
    }
}

enum CoreAudioCaptureError: LocalizedError {
    case noAudio
    case configurationChanged
    case bufferOverrun

    var errorDescription: String? {
        switch self {
        case .noAudio: "The microphone did not deliver audio. Check its connection and try again."
        case .configurationChanged: "The microphone configuration changed."
        case .bufferOverrun: "Audio capture could not keep up with the microphone."
        }
    }
}

final class MicrophoneBufferRing: @unchecked Sendable {
    private final class Slot {
        let buffer: AVAudioPCMBuffer
        var timestamp = AudioTimeStamp()
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private let slots: [Slot]
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let overflow = Atomic<Bool>(false)

    init(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, capacity: Int = 32) throws {
        guard capacity > 0 else { throw VoiceAudioRecorderError.couldNotStart }
        slots = try (0..<capacity).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                throw VoiceAudioRecorderError.couldNotStart
            }
            return Slot(buffer: buffer)
        }
    }

    var hasOverflowed: Bool { overflow.load(ordering: .relaxed) }

    func push(_ source: AVAudioPCMBuffer, timestamp: AudioTimeStamp) {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard write &- read < UInt64(slots.count) else {
            overflow.store(true, ordering: .relaxed)
            return
        }
        let slot = slots[Int(write % UInt64(slots.count))]
        guard source.frameLength <= slot.buffer.frameCapacity else {
            overflow.store(true, ordering: .relaxed)
            return
        }
        slot.buffer.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(slot.buffer.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            overflow.store(true, ordering: .relaxed)
            return
        }
        for index in sourceBuffers.indices {
            guard sourceBuffers[index].mDataByteSize <= destinationBuffers[index].mDataByteSize,
                let sourceData = sourceBuffers[index].mData,
                let destinationData = destinationBuffers[index].mData
            else {
                overflow.store(true, ordering: .relaxed)
                return
            }
            memcpy(destinationData, sourceData, Int(sourceBuffers[index].mDataByteSize))
        }
        slot.timestamp = timestamp
        writeIndex.store(write &+ 1, ordering: .releasing)
    }

    @discardableResult
    func drain(_ receive: CoreAudioMicrophoneCapture.Receiver) -> Bool {
        var read = readIndex.load(ordering: .relaxed)
        let end = writeIndex.load(ordering: .acquiring)
        let hadAudio = read != end
        while read != end {
            let slot = slots[Int(read % UInt64(slots.count))]
            receive(
                slot.buffer,
                AVAudioTime(audioTimeStamp: &slot.timestamp, sampleRate: slot.buffer.format.sampleRate))
            read &+= 1
            readIndex.store(read, ordering: .releasing)
        }
        return hadAudio
    }
}

private final class HALCaptureSignals: Sendable {
    let configurationChanged = Atomic<Bool>(false)
    let renderError = Atomic<Int32>(noErr)
}

private final class HALRenderContext: @unchecked Sendable {
    let unit: AudioUnit
    let scratch: AVAudioPCMBuffer
    let ring: MicrophoneBufferRing
    let signals: HALCaptureSignals

    init(unit: AudioUnit, format: AVAudioFormat, maximumFrames: UInt32, signals: HALCaptureSignals) throws {
        self.unit = unit
        self.signals = signals
        guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else {
            throw VoiceAudioRecorderError.couldNotStart
        }
        self.scratch = scratch
        ring = try MicrophoneBufferRing(format: format, frameCapacity: maximumFrames)
    }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard frames <= scratch.frameCapacity else {
            signals.renderError.store(kAudioUnitErr_TooManyFramesToProcess, ordering: .relaxed)
            return kAudioUnitErr_TooManyFramesToProcess
        }
        scratch.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, 1, frames, scratch.mutableAudioBufferList)
        if status == noErr, frames > 0 {
            ring.push(scratch, timestamp: time.pointee)
        } else if status != noErr {
            signals.renderError.store(status, ordering: .relaxed)
        }
        return status
    }
}

private final class HALMicrophone {
    let id = UUID()
    private var unit: AudioUnit?
    private var context: HALRenderContext?
    private var retainedContext: Unmanaged<HALRenderContext>?
    private let signals = HALCaptureSignals()
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] =
        []
    private let deviceID: AudioDeviceID
    private let followsDefault: Bool
    private let preferredDeviceUID: String?
    private var format: AVAudioFormat?
    private var lastDelivery = ContinuousClock.now

    init(deviceUniqueID: String?) throws {
        preferredDeviceUID = deviceUniqueID
        let selected = deviceUniqueID.flatMap(AudioInputDeviceResolver.coreAudioDeviceID(for:))
        followsDefault = selected == nil
        guard let deviceID = selected ?? AudioInputDeviceResolver.defaultInputDeviceID() else {
            throw VoiceAudioRecorderError.inputDeviceUnavailable
        }
        self.deviceID = deviceID
        do {
            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &description) else {
                throw VoiceAudioRecorderError.couldNotStart
            }
            try check(AudioComponentInstanceNew(component, &unit))
            guard let unit else { throw VoiceAudioRecorderError.couldNotStart }
            try set(
                kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, value: UInt32(1))
            try set(
                kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, value: UInt32(0)
            )
            try set(
                kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0,
                value: deviceID)

            let hardware = try hardwareFormat()
            guard hardware.mSampleRate.isFinite, hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                let format = AVAudioFormat(
                    standardFormatWithSampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame)
            else { throw VoiceAudioRecorderError.couldNotStart }
            self.format = format
            try set(
                kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, element: 1,
                value: format.streamDescription.pointee)
            var maximumFrames: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try check(
                AudioUnitGetProperty(
                    unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames,
                    &size))
            guard maximumFrames > 0, maximumFrames <= 65_536 else {
                throw VoiceAudioRecorderError.couldNotStart
            }
            let context = try HALRenderContext(
                unit: unit, format: format, maximumFrames: maximumFrames, signals: signals)
            self.context = context
            let retained = Unmanaged.passRetained(context)
            retainedContext = retained
            var callback = AURenderCallbackStruct(
                inputProc: { refcon, flags, time, _, frames, _ in
                    let context = Unmanaged<HALRenderContext>.fromOpaque(refcon).takeUnretainedValue()
                    return context.render(flags: flags, time: time, frames: frames)
                }, inputProcRefCon: retained.toOpaque())
            try check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

            try observe(deviceID, selector: kAudioDevicePropertyNominalSampleRate)
            try observe(deviceID, selector: kAudioDevicePropertyDeviceIsAlive)
            try observe(
                deviceID, selector: kAudioDevicePropertyStreamConfiguration,
                scope: kAudioDevicePropertyScopeInput)
            try observe(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices)
            if followsDefault {
                try observe(
                    AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyDefaultInputDevice)
            }
            try check(AudioUnitInitialize(unit))
        } catch {
            close()
            throw error
        }
    }

    func start() throws {
        guard let unit else { throw VoiceAudioRecorderError.couldNotStart }
        lastDelivery = .now
        try check(AudioOutputUnitStart(unit))
    }

    func checkHealth() throws {
        guard let context else { throw CancellationError() }
        let status = signals.renderError.load(ordering: .relaxed)
        try check(status)
        if context.ring.hasOverflowed { throw CoreAudioCaptureError.bufferOverrun }
        if signals.configurationChanged.exchange(false, ordering: .acquiringAndReleasing) {
            let resolvedDevice =
                preferredDeviceUID.flatMap(AudioInputDeviceResolver.coreAudioDeviceID(for:))
                ?? AudioInputDeviceResolver.defaultInputDeviceID()
            let hardware = try hardwareFormat()
            if hardware.mSampleRate != format?.sampleRate
                || hardware.mChannelsPerFrame != format?.channelCount || resolvedDevice != deviceID
            {
                throw CoreAudioCaptureError.configurationChanged
            }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var alive: UInt32 = 0
            var size: UInt32 = 4
            try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive))
            if alive == 0 { throw VoiceAudioRecorderError.inputDeviceUnavailable }
        }
        if lastDelivery.duration(to: .now) > .seconds(3) { throw CoreAudioCaptureError.noAudio }
    }

    func drain(_ receive: CoreAudioMicrophoneCapture.Receiver) -> Bool {
        let delivered = context?.ring.drain(receive) == true
        if delivered { lastDelivery = .now }
        return delivered
    }

    func close(receive: CoreAudioMicrophoneCapture.Receiver? = nil) {
        for (object, var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, nil, block)
        }
        listeners.removeAll()
        guard let unit else { return }
        let stopStatus = AudioOutputUnitStop(unit)
        let uninitializeStatus = AudioUnitUninitialize(unit)
        let status = AudioComponentInstanceDispose(unit)
        if let receive { _ = context?.ring.drain(receive) }
        if stopStatus != noErr || uninitializeStatus != noErr {
            NSLog(
                "Nativ microphone cleanup: stop=%d uninitialize=%d dispose=%d", stopStatus,
                uninitializeStatus, status)
        }
        if status == noErr {
            retainedContext?.release()
        } else {
            NSLog("Nativ could not dispose microphone audio unit: %d", status)
        }
        retainedContext = nil
        self.unit = nil
        context = nil
    }

    deinit { close() }

    private func observe(
        _ object: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [signals] _, _ in
            signals.configurationChanged.store(true, ordering: .releasing)
        }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, nil, block))
        listeners.append((object, address, block))
    }

    private func hardwareFormat() throws -> AudioStreamBasicDescription {
        guard let unit else { throw VoiceAudioRecorderError.couldNotStart }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format, &size))
        return format
    }

    private func set<T: BitwiseCopyable>(
        _ property: AudioUnitPropertyID, scope: AudioUnitScope, element: AudioUnitElement, value: T
    ) throws {
        guard let unit else { throw VoiceAudioRecorderError.couldNotStart }
        var value = value
        try withUnsafeBytes(of: &value) { bytes in
            guard let baseAddress = bytes.baseAddress else { throw VoiceAudioRecorderError.couldNotStart }
            try check(AudioUnitSetProperty(unit, property, scope, element, baseAddress, UInt32(bytes.count)))
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
