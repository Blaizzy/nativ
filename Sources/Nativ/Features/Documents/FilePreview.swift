import AppKit
import PDFKit
import Quartz
import SwiftUI

struct ChatAttachmentPreview: View {
    let attachment: ChatImageAttachment
    let onClose: () -> Void

    @State private var previewFile: ChatAttachmentPreviewFile?
    @State private var pdfDocument: PDFDocument?
    @State private var currentPage = 1
    @State private var pageCount = 1
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding([.horizontal, .bottom])
        }
        .background(Color.black.opacity(0.9).ignoresSafeArea())
        .task(id: attachment.id) {
            await loadPreview()
        }
        .onDisappear {
            previewFile?.remove()
        }
    }

    private var controls: some View {
        ZStack {
            Text("\(currentPage) / \(pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel("Page \(currentPage) of \(pageCount)")

            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .keyboardShortcut(.cancelAction)
                .help("Close preview")
                .accessibilityLabel("Close preview")
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if failed {
            unavailable
        } else if let previewFile {
            switch attachment.chatAttachmentKind {
            case .image:
                if let image = NSImage(contentsOf: previewFile.url) {
                    FilePreviewImage(image: image)
                        .background(Color.white)
                } else {
                    unavailable
                }
            case .document(.pdf):
                if let pdfDocument {
                    PDFFilePreview(
                        document: pdfDocument,
                        currentPage: $currentPage
                    )
                } else {
                    unavailable
                }
            case .document, .unsupported:
                QuickLookFilePreview(url: previewFile.url)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Preview unavailable",
            systemImage: "doc.questionmark"
        )
        .foregroundStyle(.white.opacity(0.7))
    }

    private func loadPreview() async {
        failed = false
        pdfDocument = nil

        let file: ChatAttachmentPreviewFile
        do {
            file = try await ChatAttachmentPreviewFile.create(for: attachment)
        } catch is CancellationError {
            return
        } catch {
            failed = true
            return
        }

        guard !Task.isCancelled else {
            file.remove()
            return
        }

        previewFile?.remove()
        previewFile = file
        currentPage = 1
        pageCount = 1

        if attachment.chatAttachmentKind == .document(.pdf) {
            pdfDocument = PDFDocument(url: file.url)
            guard let pdfDocument else {
                failed = true
                return
            }
            pageCount = max(pdfDocument.pageCount, 1)
        }
    }
}

struct FilePreviewImage: View {
    let image: NSImage

    @State private var scale = 1.0
    @GestureState private var pinch = 1.0

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

struct QuickLookFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if nsView.previewItem?.previewItemURL != url {
            nsView.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.previewItem = nil
    }
}

struct PDFFilePreview: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPage: $currentPage)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.currentPage = $currentPage
        if nsView.document !== document {
            nsView.document = document
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        nsView.document = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var currentPage: Binding<Int>

        init(currentPage: Binding<Int>) {
            self.currentPage = currentPage
        }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let page = view.currentPage,
                  let document = view.document else {
                return
            }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            currentPage.wrappedValue = index + 1
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
