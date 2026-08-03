import SwiftUI

struct FileTypeStyle {
    let glyph: String
    let tint: Color
    let label: String

    static func resolve(fileExtension: String) -> FileTypeStyle {
        switch fileExtension.lowercased() {
        case "pdf":
            return FileTypeStyle(glyph: "doc.richtext.fill", tint: .red, label: "PDF")
        case "md", "markdown", "mdown", "mkd":
            return FileTypeStyle(glyph: "text.alignleft", tint: Color(red: 0.36, green: 0.42, blue: 0.5), label: "MD")
        case "txt", "text", "log":
            return FileTypeStyle(glyph: "doc.plaintext.fill", tint: .gray, label: "TXT")
        case "rtf", "doc", "docx", "pages":
            return FileTypeStyle(glyph: "doc.text.fill", tint: .blue, label: fileExtension.uppercased())
        case "csv", "tsv", "xls", "xlsx", "numbers":
            return FileTypeStyle(glyph: "tablecells.fill", tint: .green, label: fileExtension.uppercased())
        case "ppt", "pptx", "key":
            return FileTypeStyle(glyph: "rectangle.on.rectangle.angled.fill", tint: .orange, label: fileExtension.uppercased())
        case "json", "js", "ts", "jsx", "tsx", "py", "swift", "java", "kt", "c", "cpp", "cc", "h", "hpp",
             "rb", "go", "rs", "sh", "bash", "zsh", "php", "html", "htm", "css", "scss", "xml", "yaml", "yml", "toml":
            return FileTypeStyle(glyph: "chevron.left.forwardslash.chevron.right", tint: .purple, label: fileExtension.uppercased())
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2":
            return FileTypeStyle(glyph: "archivebox.fill", tint: .brown, label: fileExtension.uppercased())
        default:
            return FileTypeStyle(
                glyph: "doc.fill",
                tint: Color(red: 0.42, green: 0.45, blue: 0.5),
                label: fileExtension.isEmpty ? "FILE" : fileExtension.uppercased()
            )
        }
    }
}

struct FileTypeIcon: View {
    let fileExtension: String
    var size: CGFloat = 40

    var body: some View {
        let style = FileTypeStyle.resolve(fileExtension: fileExtension)
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(style.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: style.glyph)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(style.label)
    }
}
