import AVKit
import AppKit
import SwiftUI

struct ArtifactPreview: View {
    let artifacts: [Artifact]
    @Binding var selectedID: Artifact.ID?
    let fileURL: (Artifact) -> URL
    let onClose: () -> Void
    let onOpenChat: (Artifact) -> Void

    private var index: Int? {
        artifacts.firstIndex { $0.id == selectedID }
    }

    private var current: Artifact? {
        index.map { artifacts[$0] }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            if let current {
                VStack(spacing: 0) {
                    header(current)
                    content(current)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 24)
                    footer(current)
                }

                HStack {
                    navButton(systemImage: "chevron.left", action: previous)
                        .opacity(canGoBack ? 1 : 0)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer()
                    navButton(systemImage: "chevron.right", action: next)
                        .opacity(canGoForward ? 1 : 0)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .padding(.horizontal, 20)
            }
        }
        .transition(.opacity)
    }

    private func header(_ artifact: Artifact) -> some View {
        HStack(spacing: 12) {
            Image(systemName: artifact.kind.systemImage)
                .foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.filename)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(artifact.typeLabel) · \(artifact.source.label)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)

            Button(action: { onOpenChat(artifact) }) {
                Label("Open in chat", systemImage: "bubble.left.and.bubble.right")
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func content(_ artifact: Artifact) -> some View {
        let url = fileURL(artifact)
        switch artifact.kind {
        case .image:
            if let image = NSImage(contentsOf: url) {
                ZoomableImage(image: image)
            } else {
                unavailable
            }
        case .video:
            VideoPlayer(player: AVPlayer(url: url))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        case .document:
            documentCard(artifact, url: url)
        }
    }

    private func documentCard(_ artifact: Artifact, url: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: artifact.kind.systemImage)
                .font(.system(size: 60))
                .foregroundStyle(.white.opacity(0.85))
            VStack(spacing: 4) {
                Text(artifact.filename)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(artifact.typeLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: 420)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func footer(_ artifact: Artifact) -> some View {
        HStack {
            if let prompt = artifact.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if let index {
                Text("\(index + 1) of \(artifacts.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
            Text("Preview unavailable")
                .font(.system(size: 13))
        }
        .foregroundStyle(.white.opacity(0.6))
    }

    private func navButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var canGoBack: Bool {
        (index ?? 0) > 0
    }

    private var canGoForward: Bool {
        guard let index else {
            return false
        }
        return index < artifacts.count - 1
    }

    private func previous() {
        guard let index, index > 0 else {
            return
        }
        selectedID = artifacts[index - 1].id
    }

    private func next() {
        guard let index, index < artifacts.count - 1 else {
            return
        }
        selectedID = artifacts[index + 1].id
    }
}

private struct ZoomableImage: View {
    let image: NSImage

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale * pinch)
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in
                        state = value.magnification
                    }
                    .onEnded { value in
                        scale = min(max(scale * value.magnification, 1), 6)
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    scale = scale > 1 ? 1 : 2
                }
            }
    }
}
