import NativServerKit
import SwiftUI

struct ServerPrefillProgressLabel: View {
    let progress: NativPrefillProgressState

    var body: some View {
        if !progress.requests.isEmpty {
            HStack(spacing: 5) {
                ServerPrefillProgressRing(progress: progress)
                    .accessibilityHidden(true)
                Text(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Prefill progress")
            .accessibilityValue(progress.prefillStatusText)
            .help(progress.prefillStatusText)
        }
    }
}

struct ServerPrefillProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: NativPrefillProgressState

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress.fractionCompleted)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(progress.fractionCompleted > 0 ? 1 : 0)
        }
        .frame(width: 14, height: 14)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress.fractionCompleted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Prefill progress")
        .accessibilityValue(progress.prefillStatusText)
        .help(progress.prefillStatusText)
    }
}

extension NativPrefillProgressState {
    var prefillStatusText: String {
        let percentage = fractionCompleted.formatted(.percent.precision(.fractionLength(0)))
        let counts = requests.map {
            "\($0.processedTokens.formatted()) / \($0.totalTokens.formatted()) tokens"
        }.joined(separator: ", ")
        return "Server prefill \(percentage) · \(counts)"
    }
}
