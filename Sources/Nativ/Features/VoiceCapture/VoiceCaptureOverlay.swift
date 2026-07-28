import AppKit
import Combine
import SwiftUI

private enum VoiceIslandLayoutMetrics {
    static let sideWidth: CGFloat = 48
    static let shelfSideWidth: CGFloat = 56
}

@MainActor
final class VoiceCaptureOverlayModel: ObservableObject {
    enum State: Equatable {
        case preparing
        case recording
        case finishing
        case failed
    }

    @Published var state: State = .preparing
    @Published var stateChangedAt = Date()
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var islandUsesCameraCutout = false
    @Published var islandStyle: VoiceCaptureAnimationStyle = .gradientIsland

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
    private let model: VoiceCaptureOverlayModel
    private let animationPreferences: VoiceAnimationPreferences
    private let waveformPanel: NSPanel
    private let islandPanel: NSPanel
    private let soundPlayer = VoiceCaptureSoundPlayer()
    private var activeStyle: VoiceCaptureAnimationStyle = .cursorWaveform
    private var displayedIslandLevel: Float = 0
    private var islandDismissalTask: Task<Void, Never>?

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

    private static func makePanel<Content: View>(
        size: NSSize,
        content: Content
    ) -> NSPanel {
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
        panel.contentView = NSHostingView(rootView: content)
        panel.setContentSize(size)
        return panel
    }

    func show(at cursorPosition: NSPoint) {
        islandDismissalTask?.cancel()
        islandDismissalTask = nil
        model.transition(to: .preparing)
        model.level = 0
        displayedIslandLevel = 0
        model.elapsed = 0
        activeStyle = animationPreferences.selectedStyle
        model.islandStyle = activeStyle
        waveformPanel.orderOut(nil)
        islandPanel.orderOut(nil)

        switch activeStyle {
        case .cursorWaveform:
            positionWaveformPanel(near: cursorPosition)
            waveformPanel.orderFrontRegardless()
        case .gradientIsland, .notchShelf:
            positionIslandPanel(on: screen(containing: cursorPosition))
            islandPanel.orderFrontRegardless()
            soundPlayer.playStart()
        }
    }

    func update(level: Float, elapsed: TimeInterval) {
        model.transition(to: .recording)
        let normalizedLevel = max(0, min(1, level))
        if activeStyle == .cursorWaveform {
            model.level = normalizedLevel
        } else {
            let response: Float = normalizedLevel > displayedIslandLevel
                ? 0.14
                : 0.07
            displayedIslandLevel += (
                normalizedLevel - displayedIslandLevel
            ) * response
            model.level = displayedIslandLevel
        }
        model.elapsed = elapsed
    }

    func showFailure() {
        model.transition(to: .failed)
        model.level = 0
        displayedIslandLevel = 0
    }

    func hide() {
        waveformPanel.orderOut(nil)
        model.level = 0
        displayedIslandLevel = 0

        guard activeStyle != .cursorWaveform, islandPanel.isVisible else {
            islandPanel.orderOut(nil)
            model.elapsed = 0
            return
        }

        model.transition(to: .finishing)
        soundPlayer.playEnd()
        islandDismissalTask?.cancel()
        islandDismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(420))
            } catch {
                return
            }
            guard let self else {
                return
            }
            self.islandPanel.orderOut(nil)
            self.model.elapsed = 0
            self.islandDismissalTask = nil
        }
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
            let wingWidth = min(
                activeStyle == .notchShelf
                    ? VoiceIslandLayoutMetrics.shelfSideWidth
                    : VoiceIslandLayoutMetrics.sideWidth,
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
            islandPanel.setFrame(frame, display: true)
            return
        }

        let size = Self.floatingIslandPanelSize
        model.islandUsesCameraCutout = false
        islandPanel.setFrame(
            NSRect(
                x: screen.frame.midX - (size.width / 2),
                y: screen.visibleFrame.maxY - size.height - 5,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    private func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first {
            NSMouseInRect(point, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

private final class VoiceCapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
    }

    private let startSound: NSSound?
    private let endSound: NSSound?

    init() {
        startSound = Self.makeSound(
            tones: [
                Tone(
                    startsAt: 0,
                    duration: 0.34,
                    startFrequency: 392,
                    endFrequency: 523.25,
                    amplitude: 0.28,
                    pan: -0.24
                ),
                Tone(
                    startsAt: 0.055,
                    duration: 0.38,
                    startFrequency: 587.33,
                    endFrequency: 783.99,
                    amplitude: 0.18,
                    pan: 0.22
                ),
                Tone(
                    startsAt: 0.1,
                    duration: 0.25,
                    startFrequency: 987.77,
                    endFrequency: 1_318.51,
                    amplitude: 0.07,
                    pan: 0.04
                ),
            ]
        )
        endSound = Self.makeSound(
            tones: [
                Tone(
                    startsAt: 0,
                    duration: 0.36,
                    startFrequency: 783.99,
                    endFrequency: 523.25,
                    amplitude: 0.24,
                    pan: 0.22
                ),
                Tone(
                    startsAt: 0.045,
                    duration: 0.41,
                    startFrequency: 587.33,
                    endFrequency: 392,
                    amplitude: 0.17,
                    pan: -0.22
                ),
                Tone(
                    startsAt: 0.02,
                    duration: 0.24,
                    startFrequency: 1_174.66,
                    endFrequency: 783.99,
                    amplitude: 0.06,
                    pan: 0
                ),
            ]
        )
        startSound?.volume = 0.3
        endSound?.volume = 0.26
    }

    func playStart() {
        endSound?.stop()
        startSound?.stop()
        startSound?.play()
    }

    func playEnd() {
        startSound?.stop()
        endSound?.stop()
        endSound?.play()
    }

    private static func makeSound(tones: [Tone]) -> NSSound? {
        let sampleRate = 48_000
        let channelCount = 2
        let bytesPerSample = MemoryLayout<Int16>.size
        let duration = tones.map { $0.startsAt + $0.duration }.max() ?? 0
        let frameCount = Int(ceil((duration + 0.04) * Double(sampleRate)))
        let dataSize = frameCount * channelCount * bytesPerSample
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
            var left = 0.0
            var right = 0.0

            for tone in tones {
                let localTime = time - tone.startsAt
                guard localTime >= 0, localTime < tone.duration else {
                    continue
                }

                let progress = localTime / tone.duration
                let attack = smoothStep(min(1, localTime / 0.028))
                let release = smoothStep(
                    min(1, (tone.duration - localTime) / 0.16)
                )
                let frequencyRange = tone.endFrequency - tone.startFrequency
                let phase = 2 * Double.pi * (
                    (tone.startFrequency * localTime)
                        + (0.5 * frequencyRange * localTime * progress)
                )
                let glassWave = sin(phase)
                    + (sin((phase * 2.01) + 0.35) * 0.14)
                    + (sin((phase * 3.97) + 0.8) * 0.035)
                let value = glassWave * tone.amplitude * attack * release
                let leftGain = sqrt((1 - tone.pan) * 0.5)
                let rightGain = sqrt((1 + tone.pan) * 0.5)
                left += value * leftGain
                right += value * rightGain
            }

            appendPCM(left, to: &data)
            appendPCM(right, to: &data)
        }

        return NSSound(data: data)
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

private struct VoiceCaptureOverlayView: View {
    @ObservedObject var model: VoiceCaptureOverlayModel

    var body: some View {
        HStack(spacing: 9) {
            recordingIndicator

            if model.state == .failed {
                Label("Mic unavailable", systemImage: "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            } else {
                VoiceLiveWaveform(
                    level: model.level,
                    isRecording: model.state == .recording
                )
                .frame(width: 90, height: 32)

                Text(formattedElapsed)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 184, height: 52)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.94))
        }
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var recordingIndicator: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let pulse = model.state == .recording
                ? (sin(timeline.date.timeIntervalSinceReferenceDate * 4.8) + 1) / 2
                : 0
            Circle()
                .fill(model.state == .failed ? Color.secondary : Color.red)
                .frame(width: 9, height: 9)
                .shadow(
                    color: model.state == .recording
                        ? Color.red.opacity(0.25 + (pulse * 0.3))
                        : .clear,
                    radius: 3 + (pulse * 3)
                )
        }
        .frame(width: 10, height: 16)
    }

    private var formattedElapsed: String {
        let seconds = max(0, Int(model.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var accessibilityLabel: String {
        switch model.state {
        case .preparing:
            "Preparing microphone"
        case .recording:
            "Recording audio, \(formattedElapsed)"
        case .finishing:
            "Finished recording audio"
        case .failed:
            "Microphone unavailable"
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
        HStack(spacing: 10) {
            if model.state == .failed {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 30, height: 30)
            } else {
                VoiceGradientOrb(
                    level: model.level,
                    state: model.state,
                    stateChangedAt: model.stateChangedAt
                )
                .frame(width: 26, height: 26)
            }

            Text(model.state == .failed ? "Mic" : formattedElapsed)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.76))
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 15)
        .frame(width: 128, height: 46)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.96))
        }
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
        }
        .padding(.vertical, 3)
    }

    private var formattedElapsed: String {
        let seconds = max(0, Int(model.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var accessibilityLabel: String {
        switch model.state {
        case .preparing:
            "Preparing microphone in Dynamic Island"
        case .recording:
            "Recording audio in Dynamic Island, \(formattedElapsed)"
        case .finishing:
            "Finished recording audio in Dynamic Island"
        case .failed:
            "Microphone unavailable"
        }
    }
}

struct VoiceCaptureNotchIslandView: View {
    @ObservedObject var model: VoiceCaptureOverlayModel

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.black.opacity(0.98))

            HStack(spacing: 0) {
                leftContent
                    .frame(width: VoiceIslandLayoutMetrics.sideWidth)

                Spacer(minLength: 0)

                rightContent
                    .frame(width: VoiceIslandLayoutMetrics.sideWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftContent: some View {
        Group {
            if model.state == .failed {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            } else {
                orb
            }
        }
    }

    private var rightContent: some View {
        Group {
            if model.state == .failed {
                Text("Mic")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            } else {
                Text(formattedElapsed)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }

    private var orb: some View {
        VoiceGradientOrb(
            level: model.level,
            state: model.state,
            stateChangedAt: model.stateChangedAt
        )
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
        ZStack {
            VoiceWideNotchShape(
                shoulderWidth: 3,
                shoulderDepth: 4,
                bottomCornerRadius: 11
            )
                .fill(Color.black.opacity(0.985))

            HStack(spacing: 0) {
                leftContent
                    .frame(width: VoiceIslandLayoutMetrics.shelfSideWidth)

                Spacer(minLength: 0)

                rightContent
                    .frame(width: VoiceIslandLayoutMetrics.shelfSideWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftContent: some View {
        Group {
            if model.state == .failed {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            } else {
                VoiceGradientOrb(
                    level: model.level,
                    state: model.state,
                    stateChangedAt: model.stateChangedAt
                )
                .frame(width: 22, height: 22)
            }
        }
    }

    private var rightContent: some View {
        Group {
            if model.state == .failed {
                Text("Mic")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            } else {
                Text(formattedElapsed)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }

    private var formattedElapsed: String {
        let seconds = max(0, Int(model.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct VoiceGradientOrb: View {
    private enum Phase {
        case activating
        case listening
        case finishing
    }

    let level: Float
    private let phase: Phase
    private let phaseStartedAt: Date

    init(level: Float, isRecording: Bool) {
        self.level = level
        phase = isRecording ? .listening : .activating
        phaseStartedAt = .distantPast
    }

    fileprivate init(
        level: Float,
        state: VoiceCaptureOverlayModel.State,
        stateChangedAt: Date
    ) {
        self.level = level
        phaseStartedAt = stateChangedAt
        switch state {
        case .preparing:
            phase = .activating
        case .recording:
            phase = .listening
        case .finishing, .failed:
            phase = .finishing
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { geometry in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let energy = phase == .listening
                    ? max(0, min(1, Double(level)))
                    : 0
                let phaseAge = max(0, timeline.date.timeIntervalSince(phaseStartedAt))
                let activationProgress = phase == .activating
                    ? eased(min(1, phaseAge / 0.28))
                    : 1
                let finishProgress = phase == .finishing
                    ? eased(min(1, phaseAge / 0.38))
                    : 0
                let shortestSide = min(geometry.size.width, geometry.size.height)
                let primaryPhase = time * 0.22
                let secondaryPhase = time * 0.16
                let driftX = sin(primaryPhase)
                    * geometry.size.width * 0.035
                let driftY = cos(primaryPhase * 0.73)
                    * geometry.size.height * 0.025
                let secondaryDriftX = cos(secondaryPhase)
                    * geometry.size.width * 0.028
                let secondaryDriftY = sin(secondaryPhase * 0.81)
                    * geometry.size.height * 0.022
                let voiceLift = energy * geometry.size.height * 0.025

                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white,
                                    Color(red: 0.82, green: 0.97, blue: 1.0),
                                    Color(red: 0.18, green: 0.76, blue: 0.96),
                                    Color(red: 0.04, green: 0.28, blue: 0.88),
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
                                endRadius: shortestSide * 0.72
                            )
                        )
                        .frame(
                            width: geometry.size.width * 1.28,
                            height: geometry.size.height * 0.92
                        )
                        .offset(
                            x: (-geometry.size.width * 0.16) + driftX,
                            y: -geometry.size.height * 0.24 + driftY - voiceLift
                        )
                        .opacity(0.84 + (energy * 0.08))
                        .blur(radius: shortestSide * 0.1)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.18, green: 0.92, blue: 1.0),
                                    Color(red: 0.02, green: 0.58, blue: 0.94)
                                        .opacity(0.86),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: shortestSide * 0.76
                            )
                        )
                        .frame(
                            width: geometry.size.width * 1.34,
                            height: geometry.size.height * 0.84
                        )
                        .offset(
                            x: (geometry.size.width * 0.18) + secondaryDriftX,
                            y: -geometry.size.height * 0.02
                                + secondaryDriftY
                                - (voiceLift * 0.45)
                        )
                        .opacity(0.48 + (energy * 0.1))
                        .blur(radius: shortestSide * 0.11)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.02, green: 0.22, blue: 0.9),
                                    Color(red: 0.0, green: 0.48, blue: 0.96)
                                        .opacity(0.72),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: shortestSide * 0.72
                            )
                        )
                        .frame(
                            width: geometry.size.width * 1.4,
                            height: geometry.size.height * 0.78
                        )
                        .offset(
                            x: (-geometry.size.width * 0.08) - secondaryDriftX,
                            y: geometry.size.height * 0.34
                                - secondaryDriftY
                                - (voiceLift * 0.3)
                        )
                        .opacity(0.62 + (energy * 0.06))
                        .blur(radius: shortestSide * 0.1)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color(red: 0.7, green: 0.96, blue: 1.0)
                                        .opacity(0.28 + (energy * 0.08)),
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
                }
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.62),
                                    .white.opacity(0.12),
                                    .white.opacity(0.38),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(0.7, shortestSide * 0.035)
                        )
                }
                .scaleEffect(
                    (0.78 + (activationProgress * 0.22))
                        + (energy * 0.014)
                        - (finishProgress * 0.06)
                )
                .opacity(activationProgress * (1 - finishProgress))
                .shadow(
                    color: Color(red: 0.38, green: 0.93, blue: 1.0)
                        .opacity(0.16 + (energy * 0.1)),
                    radius: 3 + (energy * 1.5)
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
