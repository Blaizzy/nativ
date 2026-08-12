import AppKit
import SwiftUI

private extension Color {
    static let nativMark = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor.black : NSColor(white: 0.86, alpha: 1)
    })
}

struct NativProgressMark: View {
    enum Phase: Equatable {
        case hidden
        case loading(Double?)
        case ready
    }

    let phase: Phase
    var width: CGFloat = 64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedProgress = 0.0

    var body: some View {
        NativMarkImage()
            .foregroundStyle(Color.nativMark)
            .mask(alignment: .bottom) {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .frame(
                                height: geometry.size.height * displayedProgress
                            )
                    }
                }
            }
            .frame(width: width, height: width / NativMarkImage.visibleAspectRatio)
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(phase == .hidden)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .onAppear {
                displayedProgress = targetProgress
            }
            .onChange(of: targetProgress) { _, newProgress in
                updateDisplayedProgress(to: newProgress)
            }
    }

    private var targetProgress: Double {
        switch phase {
        case .hidden:
            return 0
        case .loading(let progress):
            return Self.normalized(progress) ?? 0
        case .ready:
            return 1
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .hidden:
            return ""
        case .loading:
            return "Model loading progress"
        case .ready:
            return "Nativ"
        }
    }

    private var accessibilityValue: String {
        guard case .loading(let progress) = phase else {
            return ""
        }
        guard let normalizedProgress = Self.normalized(progress) else {
            return "Preparing"
        }
        return "\(Int((normalizedProgress * 100).rounded())) percent"
    }

    private static func normalized(_ progress: Double?) -> Double? {
        guard let progress, progress.isFinite else {
            return nil
        }
        return min(max(progress, 0), 1)
    }

    private func updateDisplayedProgress(to value: Double) {
        guard !reduceMotion, value >= displayedProgress else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedProgress = value
            }
            return
        }

        withAnimation(.easeOut(duration: 0.22)) {
            displayedProgress = value
        }
    }
}

private struct NativMarkImage: View {
    // The source asset is square; these bounds remove its transparent margins so
    // progress maps to the visible mark rather than the image canvas.
    private static let sourceSize: CGFloat = 512
    private static let visibleMinX: CGFloat = 11
    private static let visibleMinY: CGFloat = 116
    private static let visibleWidth: CGFloat = 491
    private static let visibleHeight: CGFloat = 280

    static var visibleAspectRatio: CGFloat {
        visibleWidth / visibleHeight
    }

    var body: some View {
        GeometryReader { geometry in
            let imageSide = geometry.size.width * Self.sourceSize / Self.visibleWidth

            Image("NativMark")
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: imageSide, height: imageSide)
                .offset(
                    x: -imageSide * Self.visibleMinX / Self.sourceSize,
                    y: -imageSide * Self.visibleMinY / Self.sourceSize
                )
        }
        .clipped()
    }
}

#Preview("Progress mark · Light") {
    VStack(spacing: 24) {
        NativProgressMark(phase: .hidden)
        NativProgressMark(phase: .loading(nil))
        NativProgressMark(phase: .loading(0.42))
        NativProgressMark(phase: .ready)
    }
    .padding(32)
    .preferredColorScheme(.light)
}

#Preview("Progress mark · Dark") {
    VStack(spacing: 24) {
        NativProgressMark(phase: .hidden)
        NativProgressMark(phase: .loading(nil))
        NativProgressMark(phase: .loading(0.42))
        NativProgressMark(phase: .ready)
    }
    .padding(32)
    .preferredColorScheme(.dark)
}
