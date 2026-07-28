import AppKit
import Combine
import SwiftUI

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
}

@MainActor
final class VoiceCaptureOverlayController {
    private static let panelSize = NSSize(width: 184, height: 58)
    private let model = VoiceCaptureOverlayModel()
    private let panel: NSPanel

    init() {
        panel = VoiceCapturePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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
        panel.contentView = NSHostingView(rootView: VoiceCaptureOverlayView(model: model))
        panel.setContentSize(Self.panelSize)
    }

    func show(at cursorPosition: NSPoint) {
        model.state = .preparing
        model.level = 0
        model.elapsed = 0
        positionPanel(near: cursorPosition)
        panel.orderFrontRegardless()
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
        panel.orderOut(nil)
        model.level = 0
        model.elapsed = 0
    }

    private func positionPanel(near cursorPosition: NSPoint) {
        let panelSize = Self.panelSize
        let preferredOrigin = NSPoint(
            x: cursorPosition.x - (panelSize.width / 2),
            y: cursorPosition.y - panelSize.height - 18
        )
        let screen = NSScreen.screens.first {
            NSMouseInRect(cursorPosition, $0.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.setFrameOrigin(preferredOrigin)
            return
        }

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
        panel.setFrameOrigin(origin)
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
                LiveWaveform(
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

private struct LiveWaveform: View {
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
