import AppKit
import Combine
import SwiftUI

private enum VoiceIslandLayoutMetrics {
    static let sideWidth: CGFloat = 48
    static let shelfSideWidth: CGFloat = 56
    static let audioCaptureSideWidth: CGFloat = 106
}

private let voiceCaptureDismissalDuration: TimeInterval = 0.38
private let voiceCaptureMinimumLoadingDuration: TimeInterval = 0.65

private func voiceCaptureFinishProgress(
    state: VoiceCaptureOverlayModel.State,
    stateChangedAt: Date,
    date: Date
) -> CGFloat {
    guard state == .finishing else {
        return 0
    }
    let linearProgress = min(
        1,
        max(0, date.timeIntervalSince(stateChangedAt) / voiceCaptureDismissalDuration)
    )
    return CGFloat(
        linearProgress * linearProgress * (3 - (2 * linearProgress))
    )
}

@MainActor
final class VoiceCaptureOverlayModel: ObservableObject {
    enum Presentation: Equatable {
        case dictation
        case audioCapture(AudioRecordKind)

        var audioCaptureKind: AudioRecordKind? {
            guard case let .audioCapture(kind) = self else {
                return nil
            }
            return kind
        }
    }

    enum State: Equatable {
        case preparing
        case recording
        case transcribing
        case finishing
        case failed
        case noSpeech
    }

    @Published var state: State = .preparing
    @Published var stateChangedAt = Date()
    @Published var activationStartedAt = Date()
    @Published var level: Float = 0
    @Published var closingLevel: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var islandUsesCameraCutout = false
    @Published var islandStyle: VoiceCaptureAnimationStyle = .gradientIsland
    @Published var showsNoSpeechFeedback = false
    @Published var presentation: Presentation = .dictation

    var completeAudioCapture: (() -> Void)?
    var restartAudioCapture: (() -> Void)?
    var deleteAudioCapture: (() -> Void)?

    func beginActivation(presentation: Presentation = .dictation) {
        let now = Date()
        self.presentation = presentation
        state = .preparing
        stateChangedAt = now
        activationStartedAt = now
    }

    func transition(to newState: State) {
        guard state != newState else {
            return
        }
        state = newState
        stateChangedAt = Date()
    }
}

@MainActor
final class VoiceCaptureOverlayController {
    private static let waveformPanelSize = NSSize(width: 184, height: 58)
    private static let floatingIslandPanelSize = NSSize(width: 128, height: 52)
    private static let floatingAudioCapturePanelSize = NSSize(width: 226, height: 52)
    private let model: VoiceCaptureOverlayModel
    private let animationPreferences: VoiceAnimationPreferences
    private let waveformPanel: VoiceCapturePanel
    private let islandPanel: VoiceCapturePanel
    private let soundPlayer = VoiceCaptureSoundPlayer()
    private var activeStyle: VoiceCaptureAnimationStyle = .cursorWaveform
    private var dismissalTask: Task<Void, Never>?
    private var startCueTask: Task<Void, Never>?
    private var activationID = UUID()
    private var didPlayStartCue = false

    init(animationPreferences: VoiceAnimationPreferences? = nil) {
        let model = VoiceCaptureOverlayModel()
        self.model = model
        self.animationPreferences = animationPreferences ?? .shared
        waveformPanel = Self.makePanel(
            size: Self.waveformPanelSize,
            content: VoiceCaptureOverlayView(model: model)
        )
        islandPanel = Self.makePanel(
            size: Self.floatingIslandPanelSize,
            content: VoiceCaptureIslandView(model: model)
        )
    }

    func setAudioCaptureActions(
        complete: @escaping () -> Void,
        restart: @escaping () -> Void,
        delete: @escaping () -> Void
    ) {
        model.completeAudioCapture = complete
        model.restartAudioCapture = restart
        model.deleteAudioCapture = delete
    }

    private static func makePanel<Content: View>(
        size: NSSize,
        content: Content
    ) -> VoiceCapturePanel {
        let panel = VoiceCapturePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(rootView: content)
        panel.setContentSize(size)
        panel.beginEnforcingPinnedFrame()
        return panel
    }

    func show(at cursorPosition: NSPoint) {
        show(at: cursorPosition, presentation: .dictation)
    }

    func showAudioCapture(
        _ kind: AudioRecordKind,
        at cursorPosition: NSPoint
    ) {
        show(at: cursorPosition, presentation: .audioCapture(kind))
    }

    private func show(
        at cursorPosition: NSPoint,
        presentation: VoiceCaptureOverlayModel.Presentation
    ) {
        dismissalTask?.cancel()
        dismissalTask = nil
        startCueTask?.cancel()
        startCueTask = nil
        activationID = UUID()
        didPlayStartCue = false
        model.beginActivation(presentation: presentation)
        model.level = 0
        model.closingLevel = 0
        model.elapsed = 0
        model.showsNoSpeechFeedback = false
        if presentation.audioCaptureKind != nil {
            activeStyle = animationPreferences.recordingStyle == .notchShelf
                ? .notchShelf
                : .gradientIsland
        } else {
            activeStyle = animationPreferences.selectedStyle
        }
        model.islandStyle = activeStyle
        islandPanel.ignoresMouseEvents = presentation.audioCaptureKind == nil
        waveformPanel.clearPinnedFrame()
        if presentation.audioCaptureKind == nil {
            islandPanel.clearPinnedFrame()
        }
        waveformPanel.orderOut(nil)
        islandPanel.orderOut(nil)

        switch activeStyle {
        case .cursorWaveform:
            positionWaveformPanel(near: cursorPosition)
            waveformPanel.orderFrontRegardless()
        case .gradientIsland, .notchShelf:
            positionIslandPanel(on: screen(containing: cursorPosition))
            islandPanel.orderFrontRegardless()
        }
    }

    func didStartRecording() {
        let expectedActivationID = activationID
        startCueTask?.cancel()
        startCueTask = Task { [weak self] in
            do {
                // Give the newly opened input device one audio buffer to settle
                // before starting background playback.
                try await Task.sleep(for: .milliseconds(35))
            } catch {
                return
            }
            guard let self,
                  self.activationID == expectedActivationID,
                  self.isOverlayVisible
            else {
                return
            }
            self.didPlayStartCue = self.soundPlayer.playStart()
            self.startCueTask = nil
        }
    }

    func update(level: Float, elapsed: TimeInterval) {
        model.transition(to: .recording)
        let clampedLevel = max(0, min(1, level))
        model.level = clampedLevel
        if clampedLevel > 0 {
            model.closingLevel = clampedLevel
        }
        model.elapsed = elapsed
    }

    func showFailure() {
        model.transition(to: .failed)
        model.level = 0
    }

    func waitForTranscription() {
        guard isOverlayVisible else {
            return
        }

        startCueTask?.cancel()
        startCueTask = nil
        activationID = UUID()
        dismissalTask?.cancel()
        dismissalTask = nil
        model.level = 0
        model.transition(to: .transcribing)
        if didPlayStartCue {
            soundPlayer.playEnd()
        }
        didPlayStartCue = false
    }

    func showNoSpeechFeedback() {
        guard isOverlayVisible, model.state == .transcribing else {
            return
        }

        dismissalTask?.cancel()
        dismissalTask = nil
        startCueTask?.cancel()
        startCueTask = nil
        activationID = UUID()
        didPlayStartCue = false
        model.level = 0
        let loadingAge = Date().timeIntervalSince(model.stateChangedAt)
        let remainingLoadingDuration = max(
            0,
            voiceCaptureMinimumLoadingDuration - loadingAge
        )
        let remainingLoadingMilliseconds = Int64(
            (remainingLoadingDuration * 1_000).rounded(.up)
        )

        dismissalTask = Task { [weak self] in
            if remainingLoadingMilliseconds > 0 {
                do {
                    try await Task.sleep(
                        for: .milliseconds(remainingLoadingMilliseconds)
                    )
                } catch {
                    return
                }
            }
            guard let self, self.model.state == .transcribing else {
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                self.model.showsNoSpeechFeedback = true
                self.model.transition(to: .noSpeech)
            }

            do {
                try await Task.sleep(for: .milliseconds(1_050))
            } catch {
                return
            }
            guard self.model.state == .noSpeech else {
                return
            }
            self.model.transition(to: .finishing)
            do {
                try await Task.sleep(for: .milliseconds(420))
            } catch {
                return
            }
            self.waveformPanel.orderOut(nil)
            self.islandPanel.orderOut(nil)
            self.model.elapsed = 0
            self.model.showsNoSpeechFeedback = false
            self.dismissalTask = nil
        }
    }

    func hide() {
        let overlayWasVisible = isOverlayVisible
        startCueTask?.cancel()
        startCueTask = nil
        activationID = UUID()
        model.level = 0

        guard overlayWasVisible else {
            waveformPanel.orderOut(nil)
            islandPanel.orderOut(nil)
            model.elapsed = 0
            model.showsNoSpeechFeedback = false
            didPlayStartCue = false
            return
        }

        model.transition(to: .finishing)
        if didPlayStartCue {
            soundPlayer.playEnd()
        }
        didPlayStartCue = false
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(420))
            } catch {
                return
            }
            guard let self else {
                return
            }
            self.waveformPanel.orderOut(nil)
            self.islandPanel.orderOut(nil)
            self.model.elapsed = 0
            self.model.showsNoSpeechFeedback = false
            self.dismissalTask = nil
        }
    }

    private var isOverlayVisible: Bool {
        activeStyle == .cursorWaveform
            ? waveformPanel.isVisible
            : islandPanel.isVisible
    }

    private func positionWaveformPanel(near cursorPosition: NSPoint) {
        let panelSize = Self.waveformPanelSize
        let preferredOrigin = NSPoint(
            x: cursorPosition.x - (panelSize.width / 2),
            y: cursorPosition.y - panelSize.height - 18
        )
        let visibleFrame = screen(containing: cursorPosition).visibleFrame

        let horizontalInset: CGFloat = 8
        let verticalInset: CGFloat = 8
        let origin = NSPoint(
            x: min(
                max(preferredOrigin.x, visibleFrame.minX + horizontalInset),
                visibleFrame.maxX - panelSize.width - horizontalInset
            ),
            y: min(
                max(preferredOrigin.y, visibleFrame.minY + verticalInset),
                visibleFrame.maxY - panelSize.height - verticalInset
            )
        )
        waveformPanel.setFrameOrigin(origin)
    }

    private func positionIslandPanel(on screen: NSScreen) {
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX - leftArea.maxX > 20 {
            let requestedWingWidth = model.presentation.audioCaptureKind == nil
                ? (activeStyle == .notchShelf
                    ? VoiceIslandLayoutMetrics.shelfSideWidth
                    : VoiceIslandLayoutMetrics.sideWidth)
                : VoiceIslandLayoutMetrics.audioCaptureSideWidth
            let wingWidth = min(
                requestedWingWidth,
                leftArea.width,
                rightArea.width
            )
            let cameraHeight = min(leftArea.height, rightArea.height)
            let frame = NSRect(
                x: leftArea.maxX - wingWidth,
                y: max(leftArea.minY, rightArea.minY),
                width: wingWidth + (rightArea.minX - leftArea.maxX) + wingWidth,
                height: cameraHeight
            )
            model.islandUsesCameraCutout = true
            setIslandPanelFrame(frame)
            return
        }

        let size = model.presentation.audioCaptureKind == nil
            ? Self.floatingIslandPanelSize
            : Self.floatingAudioCapturePanelSize
        model.islandUsesCameraCutout = false
        setIslandPanelFrame(
            NSRect(
                x: screen.frame.midX - (size.width / 2),
                y: screen.visibleFrame.maxY - size.height - 5,
                width: size.width,
                height: size.height
            )
        )
    }

    private func setIslandPanelFrame(_ frame: NSRect) {
        if model.presentation.audioCaptureKind != nil {
            islandPanel.setPinnedFrame(frame)
        } else {
            islandPanel.clearPinnedFrame()
            islandPanel.setFrame(frame, display: true)
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first {
            NSMouseInRect(point, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

private final class VoiceCapturePanel: NSPanel {
    private var pinnedFrame: NSRect?
    private var isApplyingPinnedFrame = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func beginEnforcingPinnedFrame() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restoreAfterWindowMove(_:)),
            name: NSWindow.didMoveNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restoreAfterApplicationSwitch(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(restoreAfterApplicationSwitch(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    func setPinnedFrame(_ frame: NSRect) {
        pinnedFrame = frame
        restorePinnedFrame(display: true)
    }

    func clearPinnedFrame() {
        pinnedFrame = nil
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard !isApplyingPinnedFrame, pinnedFrame != nil else {
            super.setFrame(frameRect, display: flag)
            return
        }
        restorePinnedFrame(display: flag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        guard !isApplyingPinnedFrame, pinnedFrame != nil else {
            super.setFrameOrigin(point)
            return
        }
        restorePinnedFrame(display: true)
    }

    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        // AppKit normally pushes panels out of the menu-bar area when the
        // owning app resigns active. The island intentionally occupies that
        // area, so preserve the frame chosen by VoiceCaptureOverlayController.
        frameRect
    }

    private func restorePinnedFrame(display: Bool) {
        guard let pinnedFrame else {
            return
        }
        isApplyingPinnedFrame = true
        super.setFrame(pinnedFrame, display: display)
        isApplyingPinnedFrame = false
    }

    @objc
    private func restoreAfterWindowMove(_ notification: Notification) {
        guard let pinnedFrame,
              !isApplyingPinnedFrame,
              !frame.equalTo(pinnedFrame)
        else {
            return
        }
        restorePinnedFrame(display: true)
    }

    @objc
    private func restoreAfterApplicationSwitch(_ notification: Notification) {
        guard pinnedFrame != nil else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pinnedFrame != nil else {
                return
            }
            self.restorePinnedFrame(display: true)
            self.orderFrontRegardless()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

@MainActor
private final class VoiceCaptureSoundPlayer {
    private struct Tone {
        let startsAt: TimeInterval
        let duration: TimeInterval
        let startFrequency: Double
        let endFrequency: Double
        let amplitude: Double
        let pan: Double
        let attack: TimeInterval
        let release: TimeInterval
        let decay: Double
        let brightness: Double

        init(
            startsAt: TimeInterval,
            duration: TimeInterval,
            startFrequency: Double,
            endFrequency: Double,
            amplitude: Double,
            pan: Double,
            attack: TimeInterval = 0.012,
            release: TimeInterval = 0.18,
            decay: Double = 1.35,
            brightness: Double = 0.32
        ) {
            self.startsAt = startsAt
            self.duration = duration
            self.startFrequency = startFrequency
            self.endFrequency = endFrequency
            self.amplitude = amplitude
            self.pan = pan
            self.attack = attack
            self.release = release
            self.decay = decay
            self.brightness = brightness
        }
    }

    private let startSoundData: Data
    private let endSoundData: Data
    private var activeSound: NSSound?

    init() {
        startSoundData = Self.makeSoundData(
            tones: [
                Tone(
                    startsAt: 0,
                    duration: 0.52,
                    startFrequency: 523.25,
                    endFrequency: 529.25,
                    amplitude: 0.2,
                    pan: -0.26,
                    attack: 0.009,
                    release: 0.26,
                    decay: 1.15,
                    brightness: 0.3
                ),
                Tone(
                    startsAt: 0.07,
                    duration: 0.48,
                    startFrequency: 783.99,
                    endFrequency: 792.99,
                    amplitude: 0.15,
                    pan: 0.28,
                    attack: 0.008,
                    release: 0.25,
                    decay: 1.42,
                    brightness: 0.36
                ),
                Tone(
                    startsAt: 0.14,
                    duration: 0.44,
                    startFrequency: 1_046.5,
                    endFrequency: 1_058.5,
                    amplitude: 0.1,
                    pan: 0.04,
                    attack: 0.006,
                    release: 0.24,
                    decay: 1.68,
                    brightness: 0.42
                ),
                Tone(
                    startsAt: 0.2,
                    duration: 0.34,
                    startFrequency: 1_567.98,
                    endFrequency: 1_576.98,
                    amplitude: 0.034,
                    pan: 0.34,
                    attack: 0.005,
                    release: 0.21,
                    decay: 2,
                    brightness: 0.38
                ),
            ],
            ambience: 0.34
        )
        endSoundData = Self.makeSoundData(
            tones: [
                Tone(
                    startsAt: 0,
                    duration: 0.4,
                    startFrequency: 1_046.5,
                    endFrequency: 1_038.5,
                    amplitude: 0.085,
                    pan: 0.3,
                    attack: 0.006,
                    release: 0.23,
                    decay: 1.72,
                    brightness: 0.4
                ),
                Tone(
                    startsAt: 0.055,
                    duration: 0.45,
                    startFrequency: 783.99,
                    endFrequency: 777.99,
                    amplitude: 0.135,
                    pan: -0.26,
                    attack: 0.008,
                    release: 0.25,
                    decay: 1.45,
                    brightness: 0.34
                ),
                Tone(
                    startsAt: 0.11,
                    duration: 0.5,
                    startFrequency: 523.25,
                    endFrequency: 518.25,
                    amplitude: 0.19,
                    pan: 0.08,
                    attack: 0.009,
                    release: 0.27,
                    decay: 1.18,
                    brightness: 0.28
                ),
            ],
            ambience: 0.3
        )
    }

    @discardableResult
    func playStart() -> Bool {
        play(
            data: startSoundData,
            volume: 0.42,
            cueName: "start"
        )
    }

    func playEnd() {
        play(
            data: endSoundData,
            volume: 0.36,
            cueName: "finish"
        )
    }

    @discardableResult
    private func play(
        data: Data,
        volume: Float,
        cueName: String
    ) -> Bool {
        activeSound?.stop()
        guard let sound = NSSound(data: data) else {
            NSLog("Nativ could not prepare the voice %@ cue.", cueName)
            return false
        }
        sound.volume = volume
        activeSound = sound
        let didPlay = sound.play()
        if !didPlay {
            NSLog("Nativ could not play the voice %@ cue.", cueName)
        }
        return didPlay
    }

    private static func makeSoundData(
        tones: [Tone],
        ambience: Double
    ) -> Data {
        let sampleRate = 48_000
        let channelCount = 2
        let bytesPerSample = MemoryLayout<Int16>.size
        let duration = tones.map { $0.startsAt + $0.duration }.max() ?? 0
        let frameCount = Int(ceil((duration + 0.14) * Double(sampleRate)))
        let dataSize = frameCount * channelCount * bytesPerSample
        var leftSamples = [Double](repeating: 0, count: frameCount)
        var rightSamples = [Double](repeating: 0, count: frameCount)
        var data = Data(capacity: 44 + dataSize)

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(channelCount), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(
            UInt32(sampleRate * channelCount * bytesPerSample),
            to: &data
        )
        append(UInt16(channelCount * bytesPerSample), to: &data)
        append(UInt16(bytesPerSample * 8), to: &data)
        data.append(contentsOf: "data".utf8)
        append(UInt32(dataSize), to: &data)

        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)

            for tone in tones {
                let localTime = time - tone.startsAt
                guard localTime >= 0, localTime < tone.duration else {
                    continue
                }

                let progress = localTime / tone.duration
                let attack = smoothStep(min(1, localTime / tone.attack))
                let release = smoothStep(
                    min(1, (tone.duration - localTime) / tone.release)
                )
                let decay = exp(-progress * tone.decay)
                let frequencyRange = tone.endFrequency - tone.startFrequency
                let phase = 2 * Double.pi * (
                    (tone.startFrequency * localTime)
                        + (0.5 * frequencyRange * localTime * progress)
                )
                let glassWave = sin(phase)
                    + (
                        sin((phase * 2.003) + 0.38)
                            * tone.brightness
                            * 0.3
                    )
                    + (
                        sin((phase * 3.011) + 1.04)
                            * tone.brightness
                            * 0.11
                    )
                    + (
                        sin((phase * 5.017) + 0.72)
                            * tone.brightness
                            * 0.035
                    )
                let value = glassWave
                    * tone.amplitude
                    * attack
                    * release
                    * decay
                let leftGain = sqrt((1 - tone.pan) * 0.5)
                let rightGain = sqrt((1 + tone.pan) * 0.5)
                leftSamples[frame] += value * leftGain
                rightSamples[frame] += value * rightGain
            }
        }

        addAmbience(
            left: &leftSamples,
            right: &rightSamples,
            sampleRate: sampleRate,
            amount: ambience
        )
        let peak = zip(leftSamples, rightSamples).reduce(0.0) {
            max($0, max(abs($1.0), abs($1.1)))
        }
        let gain = peak > 0.88 ? 0.88 / peak : 1

        for frame in 0..<frameCount {
            appendPCM(leftSamples[frame] * gain, to: &data)
            appendPCM(rightSamples[frame] * gain, to: &data)
        }

        return data
    }

    private static func addAmbience(
        left: inout [Double],
        right: inout [Double],
        sampleRate: Int,
        amount: Double
    ) {
        let dryLeft = left
        let dryRight = right
        let taps: [(delay: Double, gain: Double, crossfeed: Double)] = [
            (0.027, 0.38, 0.28),
            (0.049, 0.25, 0.52),
            (0.083, 0.16, 0.68),
            (0.113, 0.1, 0.44),
        ]

        for tap in taps {
            let delay = Int(tap.delay * Double(sampleRate))
            guard delay < left.count else {
                continue
            }
            let gain = tap.gain * amount
            for frame in delay..<left.count {
                let source = frame - delay
                left[frame] += (
                    (dryLeft[source] * (1 - tap.crossfeed))
                        + (dryRight[source] * tap.crossfeed)
                ) * gain
                right[frame] += (
                    (dryRight[source] * (1 - tap.crossfeed))
                        + (dryLeft[source] * tap.crossfeed)
                ) * gain
            }
        }
    }

    private static func smoothStep(_ value: Double) -> Double {
        value * value * (3 - (2 * value))
    }

    private static func appendPCM(_ value: Double, to data: inout Data) {
        let sample = Int16(
            (max(-1, min(1, value)) * Double(Int16.max)).rounded()
        )
        append(UInt16(bitPattern: sample), to: &data)
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }
}

struct NativAudioCaptureMark: View {
    let kind: AudioRecordKind
    let state: VoiceCaptureOverlayModel.State
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { geometry in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let shortestSide = min(geometry.size.width, geometry.size.height)
                let meterLevel = state == .recording
                    ? Double(min(max(level, 0), 1))
                    : 0
                let voiceEnergy = pow(meterLevel, 0.7)
                let breathing = (sin(time * 2.1) + 1) / 2
                let isProcessing = state == .transcribing
                let ringSpeed = isProcessing ? 150.0 : 42.0
                let pulseScale = 1
                    + (breathing * 0.025)
                    + (voiceEnergy * 0.11)

                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16 + (voiceEnergy * 0.16)))
                        .scaleEffect(pulseScale)
                        .blur(radius: shortestSide * 0.05)

                    Circle()
                        .fill(Color.black.opacity(0.98))
                        .overlay {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            tint.opacity(0.32 + (voiceEnergy * 0.2)),
                                            .clear,
                                        ],
                                        center: .topLeading,
                                        startRadius: 0,
                                        endRadius: shortestSide * 0.82
                                    )
                                )
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.65)
                        }

                    Image("NativMark")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .frame(
                            width: shortestSide * 0.54,
                            height: shortestSide * 0.54
                        )
                        .scaleEffect(1 + (voiceEnergy * 0.05))

                    Circle()
                        .trim(from: 0.03, to: isProcessing ? 0.38 : 0.72)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    .clear,
                                    tint.opacity(0.85),
                                    Color.cyan.opacity(0.9),
                                    .clear,
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(
                                lineWidth: max(1.1, shortestSide * 0.075),
                                lineCap: .round
                            )
                        )
                        .rotationEffect(.degrees(time * ringSpeed))
                }
                .scaleEffect(state == .finishing ? 0.92 : 1)
                .opacity(state == .failed ? 0.48 : 1)
                .animation(.easeOut(duration: 0.12), value: level)
            }
        }
    }

    private var tint: Color {
        kind == .voiceNote ? .purple : .blue
    }
}

private struct VoiceCapturePrimaryVisual: View {
    @ObservedObject var model: VoiceCaptureOverlayModel

    @ViewBuilder
    var body: some View {
        if let kind = model.presentation.audioCaptureKind {
            NativAudioCaptureMark(
                kind: kind,
                state: model.state,
                level: model.level
            )
        } else {
            VoiceGradientOrb(
                level: model.level,
                state: model.state,
                stateChangedAt: model.stateChangedAt,
                activationStartedAt: model.activationStartedAt,
                showsNoSpeechFeedback: model.showsNoSpeechFeedback
            )
        }
    }
}

private struct VoiceCaptureOverlayView: View {
    @ObservedObject var model: VoiceCaptureOverlayModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let finishProgress = voiceCaptureFinishProgress(
                state: model.state,
                stateChangedAt: model.stateChangedAt,
                date: timeline.date
            )

            HStack(spacing: isAudioCapture ? 7 : 9) {
                if model.showsNoSpeechFeedback {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.orange)
                        .shadow(color: Color.orange.opacity(0.3), radius: 4)
                        .frame(maxWidth: .infinity)
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.84))
                        )
                } else {
                    primaryIndicator

                    if model.state == .failed {
                        Label("Mic unavailable", systemImage: "mic.slash.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    } else {
                        ZStack {
                            VoiceLiveWaveform(
                                level: model.state == .finishing
                                    ? model.closingLevel
                                    : model.level,
                                isRecording: model.state == .recording
                                    || model.state == .finishing
                            )
                            .opacity(model.state == .transcribing ? 0.26 : 1)

                            if model.state == .transcribing {
                                VoiceTranscriptionWaveLoader()
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: isAudioCapture ? 74 : 90, height: 32)

                        Text(formattedElapsed)
                            .font(
                                .system(
                                    size: 11,
                                    weight: .semibold,
                                    design: .monospaced
                                )
                            )
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, isAudioCapture ? 10 : 14)
            .frame(width: 184, height: 52)
            .background {
                Capsule()
                    .fill(Color.black.opacity(0.94))
            }
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
            }
            .opacity(1 - finishProgress)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var primaryIndicator: some View {
        if let kind = model.presentation.audioCaptureKind {
            NativAudioCaptureMark(
                kind: kind,
                state: model.state,
                level: model.level
            )
            .frame(width: 22, height: 22)
        } else {
            recordingIndicator
        }
    }

    private var recordingIndicator: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = indicatorPulse(at: time)

            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
                .shadow(
                    color: indicatorShadowColor(pulse: pulse),
                    radius: 3 + (pulse * 3)
                )
        }
        .frame(width: 10, height: 16)
    }

    private var isAudioCapture: Bool {
        model.presentation.audioCaptureKind != nil
    }

    private var indicatorColor: Color {
        if model.state == .failed {
            return .secondary
        }
        if model.showsNoSpeechFeedback {
            return .gray
        }
        if model.state == .transcribing {
            return Color(red: 0.48, green: 0.9, blue: 1)
        }
        return .red
    }

    private func indicatorPulse(at time: TimeInterval) -> Double {
        switch model.state {
        case .recording:
            return (sin(time * 4.8) + 1) / 2
        case .transcribing:
            return (sin(time * 3.2) + 1) / 2
        default:
            return 0
        }
    }

    private func indicatorShadowColor(pulse: Double) -> Color {
        switch model.state {
        case .recording:
            return Color.red.opacity(0.25 + (pulse * 0.3))
        case .transcribing:
            return Color.cyan.opacity(0.18 + (pulse * 0.28))
        default:
            return .clear
        }
    }

    private var formattedElapsed: String {
        let seconds = max(0, Int(model.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var accessibilityLabel: String {
        if let kind = model.presentation.audioCaptureKind {
            return switch model.state {
            case .preparing:
                "Preparing \(kind.title.lowercased()) recording"
            case .recording:
                "Recording \(kind.title.lowercased()), \(formattedElapsed)"
            case .transcribing:
                "Saving and transcribing \(kind.title.lowercased())"
            case .finishing:
                "Finished recording \(kind.title.lowercased())"
            case .failed:
                "Could not record \(kind.title.lowercased())"
            case .noSpeech:
                "No speech detected"
            }
        }
        if model.showsNoSpeechFeedback {
            return "No speech detected"
        }
        return switch model.state {
        case .preparing:
            "Preparing microphone"
        case .recording:
            "Recording audio, \(formattedElapsed)"
        case .transcribing:
            "Transcribing audio"
        case .finishing:
            "Finished recording audio"
        case .failed:
            "Microphone unavailable"
        case .noSpeech:
            "No speech detected"
        }
    }
}

private struct VoiceTranscriptionWaveLoader: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    let wave = (
                        sin((time * 4.6) - (Double(index) * 0.72)) + 1
                    ) / 2

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.92),
                                    Color(red: 0.38, green: 0.86, blue: 1)
                                        .opacity(0.72),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: 4,
                            height: 5 + (CGFloat(wave) * 12)
                        )
                        .shadow(
                            color: Color.cyan.opacity(0.16 + (wave * 0.18)),
                            radius: 2
                        )
                }
            }
        }
        .frame(width: 90, height: 32)
    }
}

private struct VoiceOrbLoadingLayer: View {
    let shortestSide: CGFloat
    let time: TimeInterval

    var body: some View {
        let orbit = time * 2.55
        let pulse = (sin(time * 3.15) + 1) / 2
        let highlightCenter = UnitPoint(
            x: 0.5 + (CGFloat(cos(orbit)) * 0.24),
            y: 0.5 + (CGFloat(sin(orbit)) * 0.24)
        )

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.34),
                            Color(red: 0.34, green: 0.88, blue: 1)
                                .opacity(0.2),
                            .clear,
                        ],
                        center: highlightCenter,
                        startRadius: 0,
                        endRadius: shortestSide * 0.48
                    )
                )
                .blendMode(.screen)

            Circle()
                .trim(from: 0.04, to: 0.48)
                .stroke(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color(red: 0.48, green: 0.92, blue: 1)
                                .opacity(0.72),
                            .white.opacity(0.92),
                            .clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(
                        lineWidth: max(0.75, shortestSide * 0.045),
                        lineCap: .round
                    )
                )
                .rotationEffect(.radians(orbit))
                .opacity(0.58 + (pulse * 0.24))
                .blendMode(.screen)
        }
    }
}

private struct VoiceCaptureIslandView: View {
    @ObservedObject var model: VoiceCaptureOverlayModel

    var body: some View {
        Group {
            if model.islandUsesCameraCutout {
                if model.islandStyle == .notchShelf {
                    VoiceCaptureWideNotchView(model: model)
                } else {
                    VoiceCaptureNotchIslandView(model: model)
                }
            } else {
                floatingIsland
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var floatingIsland: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let finishProgress = voiceCaptureFinishProgress(
                state: model.state,
                stateChangedAt: model.stateChangedAt,
                date: timeline.date
            )

            HStack(spacing: 9) {
                if model.state == .failed {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 30, height: 30)
                } else {
                    VoiceCapturePrimaryVisual(model: model)
                    .frame(width: 26, height: 26)
                }

                Text(feedbackText)
                    .font(
                        .system(
                            size: 11,
                            weight: .semibold,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.white.opacity(0.76))
                    .frame(width: 38, alignment: .trailing)

                if model.presentation.audioCaptureKind != nil {
                    VoiceCaptureRecordingControls(model: model)
                }
            }
            .padding(.horizontal, model.presentation.audioCaptureKind == nil ? 15 : 12)
            .frame(
                width: model.presentation.audioCaptureKind == nil ? 128 : 226,
                height: 46
            )
            .background {
                Capsule()
                    .fill(Color.black.opacity(0.96))
            }
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
            }
            .scaleEffect(
                x: 1 - (finishProgress * 0.52),
                y: 1 - (finishProgress * 0.08)
            )
            .opacity(1 - finishProgress)
        }
        .padding(.vertical, 3)
    }

    private var formattedElapsed: String {
        let seconds = max(0, Int(model.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var feedbackText: String {
        return switch model.state {
        case .failed:
            "Mic"
        case .preparing, .recording, .transcribing, .finishing, .noSpeech:
            formattedElapsed
        }
    }

    private var accessibilityLabel: String {
        if let kind = model.presentation.audioCaptureKind {
            return switch model.state {
            case .preparing:
                "Preparing \(kind.title.lowercased()) recording"
            case .recording:
                "Recording \(kind.title.lowercased()), \(formattedElapsed)"
            case .transcribing:
                "Saving and transcribing \(kind.title.lowercased())"
            case .finishing:
                "Finished recording \(kind.title.lowercased())"
            case .failed:
                "Could not record \(kind.title.lowercased())"
            case .noSpeech:
                "No speech detected"
            }
        }
        if model.showsNoSpeechFeedback {
            return "No speech detected"
        }
        return switch model.state {
        case .preparing:
            "Preparing microphone in Dynamic Island"
        case .recording:
            "Recording audio in Dynamic Island, \(formattedElapsed)"
        case .transcribing:
            "Transcribing audio in Dynamic Island"
        case .finishing:
            "Finished recording audio in Dynamic Island"
        case .failed:
            "Microphone unavailable"
        case .noSpeech:
            "No speech detected"
        }
    }
}

struct VoiceCaptureNotchIslandView: View {
    @ObservedObject var model: VoiceCaptureOverlayModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            GeometryReader { geometry in
                let finishProgress = voiceCaptureFinishProgress(
                    state: model.state,
                    stateChangedAt: model.stateChangedAt,
                    date: timeline.date
                )
                let sideWidth = model.presentation.audioCaptureKind == nil
                    ? VoiceIslandLayoutMetrics.sideWidth
                    : VoiceIslandLayoutMetrics.audioCaptureSideWidth
                let cameraWidth = max(
                    1,
                    geometry.size.width - (sideWidth * 2)
                )
                let collapsedScale = cameraWidth / max(1, geometry.size.width)
                let backgroundProgress = finishProgress * finishProgress
                let backgroundScale = 1
                    - (backgroundProgress * (1 - collapsedScale))

                ZStack {
                    Capsule()
                        .fill(Color.black.opacity(0.98))
                        .scaleEffect(x: backgroundScale, anchor: .center)

                    HStack(spacing: 0) {
                        leftContent
                            .frame(width: sideWidth)

                        Spacer(minLength: 0)

                        rightContent
                            .frame(width: sideWidth)
                    }
                    .scaleEffect(1 - (finishProgress * 0.08))
                    .opacity(1 - finishProgress)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftContent: some View {
        HStack(spacing: 6) {
            if model.state == .failed {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            } else {
                orb

                if model.presentation.audioCaptureKind != nil {
                    VoiceCaptureActionButton(
                        title: "Restart recording",
                        systemImage: "arrow.counterclockwise",
                        tint: .white,
                        action: model.restartAudioCapture
                    )
                    VoiceCaptureActionButton(
                        title: "Delete recording",
                        systemImage: "trash.fill",
                        tint: .red,
                        action: model.deleteAudioCapture
                    )
                }
            }
        }
    }

    private var rightContent: some View {
        HStack(spacing: 7) {
            if model.state == .failed {
                Text("Mic")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            } else {
                Text(formattedElapsed)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))

                if model.presentation.audioCaptureKind != nil {
                    VoiceCaptureActionButton(
                        title: "Complete recording",
                        systemImage: "checkmark",
                        tint: .green,
                        action: model.completeAudioCapture
                    )
                }
            }
        }
    }

    private var orb: some View {
        VoiceCapturePrimaryVisual(model: model)
        .frame(width: 22, height: 22)
    }

    private var formattedElapsed: String {
        let seconds = max(0, Int(model.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct VoiceWideNotchShape: Shape {
    let shoulderWidth: CGFloat
    let shoulderDepth: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let shoulderWidth = min(
            max(0, shoulderWidth),
            rect.width / 4
        )
        let bottomRadius = min(
            max(0, bottomCornerRadius),
            rect.height,
            (rect.width - (shoulderWidth * 2)) / 2
        )
        let shoulderDepth = min(
            max(0, shoulderDepth),
            rect.height - bottomRadius
        )
        let circleControlRatio: CGFloat = 0.552_284_75
        let leftSide = rect.minX + shoulderWidth
        let rightSide = rect.maxX - shoulderWidth

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rightSide, y: rect.minY + shoulderDepth),
            control1: CGPoint(
                x: rect.maxX - (shoulderWidth * circleControlRatio),
                y: rect.minY
            ),
            control2: CGPoint(
                x: rightSide,
                y: rect.minY + (shoulderDepth * (1 - circleControlRatio))
            )
        )
        path.addLine(
            to: CGPoint(x: rightSide, y: rect.maxY - bottomRadius)
        )
        path.addCurve(
            to: CGPoint(x: rightSide - bottomRadius, y: rect.maxY),
            control1: CGPoint(
                x: rightSide,
                y: rect.maxY - (bottomRadius * (1 - circleControlRatio))
            ),
            control2: CGPoint(
                x: rightSide - (bottomRadius * (1 - circleControlRatio)),
                y: rect.maxY
            )
        )
        path.addLine(
            to: CGPoint(x: leftSide + bottomRadius, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: leftSide, y: rect.maxY - bottomRadius),
            control1: CGPoint(
                x: leftSide + (bottomRadius * (1 - circleControlRatio)),
                y: rect.maxY
            ),
            control2: CGPoint(
                x: leftSide,
                y: rect.maxY - (bottomRadius * (1 - circleControlRatio))
            )
        )
        path.addLine(
            to: CGPoint(x: leftSide, y: rect.minY + shoulderDepth)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control1: CGPoint(
                x: leftSide,
                y: rect.minY + (shoulderDepth * (1 - circleControlRatio))
            ),
            control2: CGPoint(
                x: rect.minX + (shoulderWidth * circleControlRatio),
                y: rect.minY
            )
        )
        path.closeSubpath()
        return path
    }
}

private struct VoiceCaptureWideNotchView: View {
    @ObservedObject var model: VoiceCaptureOverlayModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            GeometryReader { geometry in
                let finishProgress = voiceCaptureFinishProgress(
                    state: model.state,
                    stateChangedAt: model.stateChangedAt,
                    date: timeline.date
                )
                let sideWidth = model.presentation.audioCaptureKind == nil
                    ? VoiceIslandLayoutMetrics.shelfSideWidth
                    : VoiceIslandLayoutMetrics.audioCaptureSideWidth
                let cameraWidth = max(
                    1,
                    geometry.size.width - (sideWidth * 2)
                )
                let collapsedScale = cameraWidth / max(1, geometry.size.width)
                let backgroundProgress = finishProgress * finishProgress
                let backgroundScale = 1
                    - (backgroundProgress * (1 - collapsedScale))

                ZStack {
                    VoiceWideNotchShape(
                        shoulderWidth: 3,
                        shoulderDepth: 4,
                        bottomCornerRadius: 11
                    )
                    .fill(Color.black.opacity(0.985))
                    .scaleEffect(x: backgroundScale, anchor: .center)

                    HStack(spacing: 0) {
                        leftContent
                            .frame(width: sideWidth)

                        Spacer(minLength: 0)

                        rightContent
                            .frame(width: sideWidth)
                    }
                    .scaleEffect(1 - (finishProgress * 0.08))
                    .opacity(1 - finishProgress)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftContent: some View {
        HStack(spacing: 6) {
            if model.state == .failed {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            } else {
                VoiceCapturePrimaryVisual(model: model)
                    .frame(width: 22, height: 22)

                if model.presentation.audioCaptureKind != nil {
                    VoiceCaptureActionButton(
                        title: "Restart recording",
                        systemImage: "arrow.counterclockwise",
                        tint: .white,
                        action: model.restartAudioCapture
                    )
                    VoiceCaptureActionButton(
                        title: "Delete recording",
                        systemImage: "trash.fill",
                        tint: .red,
                        action: model.deleteAudioCapture
                    )
                }
            }
        }
    }

    private var rightContent: some View {
        HStack(spacing: 7) {
            if model.state == .failed {
                Text("Mic")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            } else {
                Text(formattedElapsed)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))

                if model.presentation.audioCaptureKind != nil {
                    VoiceCaptureActionButton(
                        title: "Complete recording",
                        systemImage: "checkmark",
                        tint: .green,
                        action: model.completeAudioCapture
                    )
                }
            }
        }
    }

    private var formattedElapsed: String {
        let seconds = max(0, Int(model.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct VoiceCaptureRecordingControls: View {
    @ObservedObject var model: VoiceCaptureOverlayModel

    var body: some View {
        HStack(spacing: 5) {
            VoiceCaptureActionButton(
                title: "Restart recording",
                systemImage: "arrow.counterclockwise",
                tint: .white,
                action: model.restartAudioCapture
            )
            VoiceCaptureActionButton(
                title: "Delete recording",
                systemImage: "trash.fill",
                tint: .red,
                action: model.deleteAudioCapture
            )
            VoiceCaptureActionButton(
                title: "Complete recording",
                systemImage: "checkmark",
                tint: .green,
                action: model.completeAudioCapture
            )
        }
        .disabled(model.state != .recording)
        .opacity(model.state == .recording ? 1 : 0.45)
    }
}

private struct VoiceCaptureActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct VoiceGradientOrb: View {
    private enum Phase {
        case activating
        case listening
        case transcribing
        case finishing
    }

    let level: Float
    private let phase: Phase
    private let phaseStartedAt: Date
    private let activationStartedAt: Date
    private let showsNoSpeechFeedback: Bool

    init(level: Float, isRecording: Bool) {
        self.level = level
        phase = isRecording ? .listening : .activating
        phaseStartedAt = .distantPast
        activationStartedAt = .distantPast
        showsNoSpeechFeedback = false
    }

    fileprivate init(
        level: Float,
        state: VoiceCaptureOverlayModel.State,
        stateChangedAt: Date,
        activationStartedAt: Date,
        showsNoSpeechFeedback: Bool
    ) {
        self.level = level
        phaseStartedAt = stateChangedAt
        self.activationStartedAt = activationStartedAt
        self.showsNoSpeechFeedback = showsNoSpeechFeedback
        switch state {
        case .preparing:
            phase = .activating
        case .recording:
            phase = .listening
        case .transcribing, .noSpeech:
            phase = .transcribing
        case .finishing, .failed:
            phase = .finishing
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { geometry in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let meterLevel = phase == .listening
                    ? max(0, min(1, Double(level)))
                    : 0
                let audibleLevel = max(0, (meterLevel - 0.055) / 0.56)
                let energy = pow(min(1, audibleLevel), 0.72)
                let motionEnergy = eased(
                    max(0, min(1, (energy - 0.14) / 0.86))
                )
                let phaseAge = max(0, timeline.date.timeIntervalSince(phaseStartedAt))
                let activationAge = max(
                    0,
                    timeline.date.timeIntervalSince(activationStartedAt)
                )
                let activationProgress = eased(min(1, activationAge / 0.28))
                let finishProgress = phase == .finishing
                    ? eased(min(1, phaseAge / 0.38))
                    : 0
                let shortestSide = min(geometry.size.width, geometry.size.height)
                let isLoading = phase == .transcribing
                    && !showsNoSpeechFeedback
                let loadingPulse = isLoading
                    ? (sin(time * 3.15) + 1) / 2
                    : 0
                let loadingGlow = isLoading
                    ? 0.1 + (loadingPulse * 0.08)
                    : 0
                let orbScale = (0.78 + (activationProgress * 0.22))
                    + (motionEnergy * 0.055)
                    + (loadingPulse * 0.018)
                    - (finishProgress * 0.06)
                let orbShadowOpacity = showsNoSpeechFeedback
                    ? 0
                    : 0.16 + (energy * 0.18) + loadingGlow
                let orbShadowRadius = 3
                    + (energy * 2.5)
                    + (isLoading ? loadingPulse * 1.5 : 0)
                let primaryPhase = time * 0.48
                let secondaryPhase = time * 0.34
                let driftX = sin(primaryPhase)
                    * geometry.size.width * 0.07
                let driftY = cos(primaryPhase * 0.73)
                    * geometry.size.height * 0.055
                let secondaryDriftX = cos(secondaryPhase)
                    * geometry.size.width * 0.06
                let secondaryDriftY = sin(secondaryPhase * 0.81)
                    * geometry.size.height * 0.048
                let restMix = 1 - motionEnergy
                let flowPhase = time * 3.9
                let leadFlowX = (
                    (sin(flowPhase * 0.72) * 0.78)
                        + (sin((flowPhase * 1.41) + 0.4) * 0.22)
                ) * motionEnergy
                let leadFlowY = (
                    (sin((flowPhase * 0.43) + 1.2) * 0.76)
                        + (cos((flowPhase * 1.17) + 0.1) * 0.24)
                ) * motionEnergy
                let middleFlowX = (
                    (sin((-flowPhase * 0.61) + 1.0) * 0.74)
                        + (cos((flowPhase * 1.26) + 0.7) * 0.26)
                ) * motionEnergy
                let middleFlowY = (
                    (cos((flowPhase * 0.84) + 2.1) * 0.8)
                        + (sin((-flowPhase * 1.09) + 0.3) * 0.2)
                ) * motionEnergy
                let tailFlowX = (
                    (cos((flowPhase * 0.48) + 2.6) * 0.76)
                        + (sin((flowPhase * 1.33) + 1.4) * 0.24)
                ) * motionEnergy
                let tailFlowY = (
                    (sin((-flowPhase * 0.77) + 2.0) * 0.72)
                        + (cos((flowPhase * 1.21) + 2.8) * 0.28)
                ) * motionEnergy
                let shadowFlowX = (
                    (sin((-flowPhase * 0.69) + 3.1) * 0.82)
                        + (cos((flowPhase * 1.12) + 0.8) * 0.18)
                ) * motionEnergy
                let shadowFlowY = (
                    (cos((flowPhase * 0.52) + 0.4) * 0.75)
                        + (sin((flowPhase * 1.28) + 2.4) * 0.25)
                ) * motionEnergy

                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.98, green: 0.99, blue: 1.0),
                                    Color(red: 0.42, green: 0.94, blue: 1.0),
                                    Color(red: 0.0, green: 0.48, blue: 1.0),
                                    Color(red: 0.08, green: 0.04, blue: 0.56),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white,
                                    Color(red: 0.87, green: 0.98, blue: 1.0)
                                        .opacity(0.92),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: shortestSide * 0.31
                            )
                        )
                        .frame(
                            width: geometry.size.width * 0.9,
                            height: geometry.size.height * 0.72
                        )
                        .offset(
                            x: (
                                (-geometry.size.width * 0.16) + driftX
                            ) * restMix
                                + (leadFlowX * geometry.size.width * 0.34),
                            y: (
                                (-geometry.size.height * 0.24) + driftY
                            ) * restMix
                                + (leadFlowY * geometry.size.height * 0.31)
                        )
                        .scaleEffect(
                            x: 1 + (leadFlowX * 0.045),
                            y: 1 - (leadFlowX * 0.032)
                        )
                        .opacity(0.78 + (energy * 0.16))
                        .blur(radius: shortestSide * 0.095)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.0, green: 1.0, blue: 0.94),
                                    Color(red: 0.0, green: 0.42, blue: 1.0),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: shortestSide * 0.265
                            )
                        )
                        .frame(
                            width: geometry.size.width * 0.86,
                            height: geometry.size.height * 0.62
                        )
                        .offset(
                            x: (
                                (geometry.size.width * 0.18) + secondaryDriftX
                            ) * restMix
                                + (middleFlowX * geometry.size.width * 0.37),
                            y: (
                                (-geometry.size.height * 0.02) + secondaryDriftY
                            ) * restMix
                                + (middleFlowY * geometry.size.height * 0.3)
                        )
                        .scaleEffect(
                            x: 1 + (middleFlowX * 0.055),
                            y: 1 - (middleFlowX * 0.042)
                        )
                        .opacity(0.52 + (energy * 0.2))
                        .blur(radius: shortestSide * 0.09)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.86, green: 0.48, blue: 1.0),
                                    Color(red: 0.5, green: 0.26, blue: 0.98)
                                        .opacity(0.8),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: shortestSide * 0.26
                            )
                        )
                        .frame(
                            width: geometry.size.width * 0.98,
                            height: geometry.size.height * 0.68
                        )
                        .offset(
                            x: (
                                (-geometry.size.width * 0.08) - secondaryDriftX
                            ) * restMix
                                + (tailFlowX * geometry.size.width * 0.36),
                            y: (
                                (geometry.size.height * 0.34) - secondaryDriftY
                            ) * restMix
                                + (tailFlowY * geometry.size.height * 0.32)
                        )
                        .scaleEffect(
                            x: 1 + (tailFlowX * 0.052),
                            y: 1 - (tailFlowX * 0.058)
                        )
                        .opacity(0.5 + (energy * 0.14))
                        .blur(radius: shortestSide * 0.095)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.62, green: 0.72, blue: 1.0)
                                        .opacity(0.72),
                                    Color(red: 0.22, green: 0.58, blue: 1.0)
                                        .opacity(0.48),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: shortestSide * 0.21
                            )
                        )
                        .frame(
                            width: geometry.size.width * 0.72,
                            height: geometry.size.height * 0.5
                        )
                        .offset(
                            x: (
                                (geometry.size.width * 0.2) - driftX
                            ) * restMix
                                + (shadowFlowX * geometry.size.width * 0.33),
                            y: (
                                (geometry.size.height * 0.26) + secondaryDriftY
                            ) * restMix
                                + (shadowFlowY * geometry.size.height * 0.28)
                        )
                        .scaleEffect(
                            x: 1 + (shadowFlowX * 0.045),
                            y: 1 - (shadowFlowX * 0.034)
                        )
                        .opacity(0.2 + (energy * 0.14))
                        .blendMode(.screen)
                        .blur(radius: shortestSide * 0.085)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color(red: 0.7, green: 0.96, blue: 1.0)
                                        .opacity(0.3 + (energy * 0.14)),
                                    .white.opacity(0.84),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.86, green: 0.78, blue: 1.0)
                                        .opacity(0.12),
                                    Color(red: 0.36, green: 0.2, blue: 0.84)
                                        .opacity(0.48),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .opacity(finishProgress)
                        .blendMode(.screen)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.42),
                                    .clear,
                                    .white.opacity(0.16),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)

                    if isLoading {
                        VoiceOrbLoadingLayer(
                            shortestSide: shortestSide,
                            time: time
                        )
                    }

                    if showsNoSpeechFeedback {
                        Circle()
                            .fill(Color(white: 0.5).opacity(0.52))
                            .blendMode(.saturation)

                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.78, green: 0.84, blue: 0.92)
                                            .opacity(0.18),
                                        Color(red: 0.12, green: 0.14, blue: 0.2)
                                            .opacity(0.42),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        .white.opacity(0.16),
                                        .clear,
                                    ],
                                    center: .topLeading,
                                    startRadius: 0,
                                    endRadius: shortestSide * 0.62
                                )
                            )
                            .blendMode(.screen)

                        Capsule()
                            .fill(Color.black.opacity(0.32))
                            .frame(
                                width: shortestSide * 0.7,
                                height: max(2, shortestSide * 0.1)
                            )
                            .rotationEffect(.degrees(-38))
                            .blur(radius: max(0.5, shortestSide * 0.015))

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.0, green: 0.48, blue: 0.48),
                                        Color(red: 0.87, green: 0.15, blue: 0.2),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(
                                width: shortestSide * 0.66,
                                height: max(1.4, shortestSide * 0.065)
                            )
                            .rotationEffect(.degrees(-38))
                            .shadow(color: .red.opacity(0.22), radius: 1.5)
                            .transition(.opacity.combined(with: .scale(scale: 0.72)))
                    }
                }
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.62 + (energy * 0.24)),
                                    .white.opacity(0.12 + (energy * 0.1)),
                                    .white.opacity(0.38 + (energy * 0.18)),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(0.7, shortestSide * 0.035)
                        )
                }
                .scaleEffect(orbScale)
                .opacity(activationProgress * (1 - finishProgress))
                .shadow(
                    color: Color(red: 0.38, green: 0.93, blue: 1.0)
                        .opacity(orbShadowOpacity),
                    radius: orbShadowRadius
                )
                .animation(
                    .easeOut(duration: 0.18),
                    value: showsNoSpeechFeedback
                )
            }
        }
    }

    private func eased(_ value: Double) -> Double {
        value * value * (3 - (2 * value))
    }
}

struct VoiceLiveWaveform: View {
    let level: Float
    let isRecording: Bool

    private let barCount = 17

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            HStack(spacing: 2.35) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.64),
                                    .white,
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 3, height: barHeight(
                            at: index,
                            time: timeline.date.timeIntervalSinceReferenceDate
                        ))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func barHeight(at index: Int, time: TimeInterval) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distanceFromCenter = abs(Double(index) - center) / center
        let envelope = 1 - (distanceFromCenter * 0.42)
        let phase = (time * 7.5) + (Double(index) * 0.78)
        let motion = 0.55 + (abs(sin(phase)) * 0.45)
        let liveLevel = isRecording ? max(0.1, Double(level)) : 0.14
        let height = 4 + (liveLevel * envelope * motion * 28)
        return CGFloat(min(32, max(4, height)))
    }
}
