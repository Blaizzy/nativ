import SwiftUI

enum PhosphorFileIcon: String {
    case fileAudio = "Phosphor-file-audio"
    case fileCode = "Phosphor-file-code"
    case fileCsv = "Phosphor-file-csv"
    case fileDashed = "Phosphor-file-dashed"
    case fileDoc = "Phosphor-file-doc"
    case fileImage = "Phosphor-file-image"
    case filePdf = "Phosphor-file-pdf"
    case filePpt = "Phosphor-file-ppt"
    case fileText = "Phosphor-file-text"
    case fileVideo = "Phosphor-file-video"
    case fileZip = "Phosphor-file-zip"

    var image: Image {
        Image(rawValue)
            .interpolation(.medium)
            .resizable()
    }
}

struct FileTypeStyle {
    let icon: PhosphorFileIcon
    let tint: Color
    let label: String

    static func resolve(fileExtension: String) -> FileTypeStyle {
        let normalized = fileExtension.lowercased()
        switch normalized {
        case "pdf":
            return FileTypeStyle(icon: .filePdf, tint: .red, label: "PDF")
        case "doc", "docx", "rtf", "pages":
            return FileTypeStyle(icon: .fileDoc, tint: .blue, label: normalized.uppercased())
        case "ppt", "pptx", "key":
            return FileTypeStyle(icon: .filePpt, tint: .yellow, label: normalized.uppercased())
        case "csv", "tsv", "xls", "xlsx", "numbers":
            return FileTypeStyle(icon: .fileCsv, tint: .green, label: normalized.uppercased())
        case "md", "markdown", "mdown", "mkd":
            return FileTypeStyle(icon: .fileText, tint: .secondary, label: "MD")
        case "txt", "text", "log":
            return FileTypeStyle(icon: .fileText, tint: .secondary, label: "TXT")
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp":
            return FileTypeStyle(icon: .fileImage, tint: .pink, label: normalized.uppercased())
        case "mp4", "mov", "m4v", "avi", "mkv":
            return FileTypeStyle(icon: .fileVideo, tint: .indigo, label: normalized.uppercased())
        case "wav", "mp3", "m4a", "aac", "flac", "aiff":
            return FileTypeStyle(icon: .fileAudio, tint: .teal, label: normalized.uppercased())
        case "json", "js", "ts", "jsx", "tsx", "py", "swift", "java", "kt", "c", "cpp", "cc", "h", "hpp",
             "rb", "go", "rs", "sh", "bash", "zsh", "php", "html", "htm", "css", "scss", "xml", "yaml",
             "yml", "toml", "sql", "ini", "cfg", "conf", "env":
            return FileTypeStyle(icon: .fileCode, tint: .purple, label: normalized.uppercased())
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2":
            return FileTypeStyle(icon: .fileZip, tint: .brown, label: normalized.uppercased())
        default:
            return FileTypeStyle(
                icon: .fileDashed,
                tint: .secondary,
                label: normalized.isEmpty ? "FILE" : normalized.uppercased()
            )
        }
    }
}

struct FileTypeIcon: View {
    let fileExtension: String
    var size: CGFloat = 40

    var body: some View {
        let style = FileTypeStyle.resolve(fileExtension: fileExtension)
        style.icon.image
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(style.tint)
            .accessibilityLabel(style.label)
    }
}
