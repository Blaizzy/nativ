import AppKit
import Combine
import SwiftUI

private enum VoiceIslandLayoutMetrics {
    static let sideWidth: CGFloat = 48
}

@MainActor
final class VoiceCaptureOverlayModel: ObservableObject {
    enum State {
        case preparing
        case recording
        case failed
    }

    @Published var state: State = .preparing
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    @Published var islandUsesCameraCutout = false
}

@MainActor
final class VoiceCaptureOverlayController {
    private static let waveformPanelSize = NSSize(width: 184, height: 58)
    private static let floatingIslandPanelSize = NSSize(width: 128, height: 52)
    private let model: VoiceCaptureOverlayModel
    private let animationPreferences: VoiceAnimationPreferences
    private let waveformPanel: NSPanel
    private let islandPanel: NSPanel
    private var activeStyle: VoiceCaptureAnimationStyle = .cursorWaveform

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
        model.state = .preparing
        model.level = 0
        model.elapsed = 0
        activeStyle = animationPreferences.selectedStyle
        waveformPanel.orderOut(nil)
        islandPanel.orderOut(nil)

        switch activeStyle {
        case .cursorWaveform:
            positionWaveformPanel(near: cursorPosition)
            waveformPanel.orderFrontRegardless()
        case .gradientIsland:
            positionIslandPanel(on: screen(containing: cursorPosition))
            islandPanel.orderFrontRegardless()
        }
    }

    func update(level: Float, elapsed: TimeInterval) {
        model.state = .recording
        model.level = level
        model.elapsed = elapsed
    }

    func showFailure() {
        model.state = .failed
        model.level = 0
    }

    func hide() {
        waveformPanel.orderOut(nil)
        islandPanel.orderOut(nil)
        model.level = 0
        model.elapsed = 0
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
                VoiceIslandLayoutMetrics.sideWidth,
                leftArea.width,
                rightArea.width
            )
            let height = min(leftArea.height, rightArea.height)
            let frame = NSRect(
                x: leftArea.maxX - wingWidth,
                y: max(leftArea.minY, rightArea.minY),
                width: wingWidth + (rightArea.minX - leftArea.maxX) + wingWidth,
                height: height
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
                VoiceCaptureNotchIslandView(model: model)
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
                    isRecording: model.state == .recording
                )
                .frame(width: 30, height: 30)
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
                orbWithRecordingDot
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

    private var orbWithRecordingDot: some View {
        ZStack(alignment: .bottomTrailing) {
            VoiceGradientOrb(
                level: model.level,
                isRecording: model.state == .recording
            )
            .frame(width: 22, height: 22)

            Circle()
                .fill(.red)
                .frame(width: 5, height: 5)
                .overlay {
                    Circle()
                        .stroke(Color.black, lineWidth: 1)
                }
                .shadow(color: .red.opacity(0.5), radius: 2)
        }
    }

    private var formattedElapsed: String {
        let seconds = max(0, Int(model.elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct VoiceGradientOrb: View {
    let level: Float
    let isRecording: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let energy = isRecording ? max(0, min(1, Double(level))) : 0
            let isSpeaking = energy > 0.12
            let speed = isSpeaking ? 0.8 + (energy * 2.8) : 0.08
            let rotation = time * speed * 150

            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                .cyan,
                                .blue,
                                .purple,
                                .pink,
                                .orange,
                                .cyan,
                            ],
                            center: .center,
                            startAngle: .degrees(rotation),
                            endAngle: .degrees(rotation + 360)
                        )
                    )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(0.82),
                                .white.opacity(0.08),
                                .clear,
                            ],
                            center: UnitPoint(x: 0.32, y: 0.25),
                            startRadius: 0,
                            endRadius: 16
                        )
                    )
                    .blendMode(.screen)
            }
            .hueRotation(.degrees(sin(time * speed * 1.7) * 42))
            .scaleEffect(0.94 + (energy * 0.12))
            .shadow(
                color: Color.cyan.opacity(0.24 + (energy * 0.35)),
                radius: 4 + (energy * 5)
            )
        }
        .padding(2)
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
