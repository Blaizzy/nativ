import Foundation

enum ChatScreenCapture {
    static func captureInteractive(to fileURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", fileURL.path]
            process.terminationHandler = { _ in
                let captured = FileManager.default.fileExists(atPath: fileURL.path)
                continuation.resume(returning: captured)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
