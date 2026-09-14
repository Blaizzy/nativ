import NativServerKit
import SwiftUI

struct ServerPrefillProgressLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: NativPrefillProgressState

    var body: some View {
        Group {
            if !progress.requests.isEmpty {
                HStack(spacing: 6) {
                    ServerPrefillProgressRing(progress: progress)
                        .accessibilityHidden(true)
                    Text("Reading prompt")
                    ZStack(alignment: .trailing) {
                        Text(1.0, format: .percent.precision(.fractionLength(0)))
                            .hidden()
                        Text(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    }
                    .fontWeight(.semibold)
                    .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.065), in: Capsule())
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.1), lineWidth: 0.5))
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Reading prompt")
                .accessibilityValue(progress.prefillStatusText)
                .help(progress.prefillStatusText)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress.requests.isEmpty)
    }
}

struct ServerPrefillProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: NativPrefillProgressState

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.15), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: progress.fractionCompleted)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(progress.fractionCompleted > 0 ? 1 : 0)
        }
        .frame(width: 12, height: 12)
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
