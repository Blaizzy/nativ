import SwiftUI

/// Shared native rendering entry point. Callers supply already-preprocessed Markdown.
struct MarkdownRenderer: View {
    enum ImagePolicy: Equatable {
        case mathOnly
        case document
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedImages: LoadedImages?

    let content: String
    var baseURL: URL?
    let fontSize: CGFloat
    var imagePolicy: ImagePolicy = .mathOnly

    private struct LoadedImages {
        let request: MarkdownImageRequest
        let images: MarkdownImages
    }

    private var imageRequest: MarkdownImageRequest? {
        imagePolicy == .document ? .init(markdown: content, baseURL: baseURL) : nil
    }

    var body: some View {
        let request = imageRequest
        let images = loadedImages.flatMap { $0.request == request ? $0.images : nil } ?? .empty
        MarkdownView(
            content: content,
            style: MarkdownStyle(
                fontSize: fontSize,
                dark: colorScheme == .dark,
                baseURL: baseURL,
                images: images
            )
        )
        .task(id: request) {
            guard let request else { return }
            let images = await MarkdownImages.load(request)
            guard !Task.isCancelled else { return }
            loadedImages = LoadedImages(request: request, images: images)
        }
    }
}
